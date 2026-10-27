//! Turning flags, environment and the `.env` file into a launch plan.

use std::collections::{BTreeMap, HashMap};
use std::path::{Path, PathBuf};
use std::time::Duration;

use anyhow::{Context as _, Result, bail};
use oci_arm_catcher_core::api::{A1_FLEX, ShapeConfig, SourceDetails, VnicDetails};
use oci_arm_catcher_core::config::expand_home;
use oci_arm_catcher_core::{LaunchDetails, Plan};

use crate::args::{CommonArgs, LaunchArgs};
use crate::exit::UsageError;

/// Default wait between attempts: polite, and plenty fast for capacity that frees up in
/// windows of minutes.
const DEFAULT_INTERVAL: u64 = 300;

/// `KEY=value` pairs from a `.env` file.
pub type EnvFile = HashMap<String, String>;

/// Read the settings file: the one named, else `./.env` if there is one, else nothing.
pub fn load_env_file(common: &CommonArgs) -> Result<(Option<PathBuf>, EnvFile)> {
    let path = match &common.env_file {
        Some(path) => {
            if !path.is_file() {
                bail!(UsageError::new(format!(
                    "settings file not found: {}",
                    path.display()
                )));
            }
            path.clone()
        }
        None => {
            let default = PathBuf::from(".env");
            if !default.is_file() {
                return Ok((None, EnvFile::new()));
            }
            default
        }
    };
    let text = std::fs::read_to_string(&path)
        .with_context(|| format!("cannot read {}", path.display()))?;
    Ok((Some(path), parse_env(&text)))
}

/// Parse `KEY=value` lines the way the shell scripts read them: `#` comments, optional
/// `export`, optional quotes, and `$HOME` / `${HOME}` / `%USERPROFILE%` expanded.
pub fn parse_env(text: &str) -> EnvFile {
    let home = dirs_home();
    let mut vars = EnvFile::new();
    for line in text.lines() {
        let line = line.trim();
        let line = line.strip_prefix("export ").unwrap_or(line);
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let Some((key, value)) = line.split_once('=') else {
            continue;
        };
        let key = key.trim();
        if key.is_empty() || !key.chars().all(|c| c.is_ascii_alphanumeric() || c == '_') {
            continue;
        }
        let mut value = value.trim();
        if value.len() >= 2
            && ((value.starts_with('"') && value.ends_with('"'))
                || (value.starts_with('\'') && value.ends_with('\'')))
        {
            value = &value[1..value.len() - 1];
        }
        let value = value
            .replace("${HOME}", &home)
            .replace("$HOME", &home)
            .replace("%USERPROFILE%", &home);
        vars.insert(key.to_owned(), value);
    }
    vars
}

fn dirs_home() -> String {
    expand_home("~").to_string_lossy().into_owned()
}

/// A flag/env value, else the `.env` value, parsed.
fn pick<T: std::str::FromStr>(flag: Option<T>, file: &EnvFile, key: &str) -> Result<Option<T>>
where
    T::Err: std::fmt::Display,
{
    if flag.is_some() {
        return Ok(flag);
    }
    match file.get(key).map(|v| v.trim()).filter(|v| !v.is_empty()) {
        None => Ok(None),
        Some(raw) => raw
            .parse()
            .map(Some)
            .map_err(|e| UsageError::new(format!("{key}={raw:?}: {e}")).into()),
    }
}

/// Build the launch plan, reporting every missing setting at once.
pub fn plan(args: &LaunchArgs, file: &EnvFile) -> Result<Plan> {
    let compartment_id = pick(args.compartment_id.clone(), file, "COMPARTMENT_ID")?;
    // The scripts accept a single AVAILABILITY_DOMAIN or a rotating AVAILABILITY_DOMAINS list;
    // the list wins when both are set.
    let ads = pick(
        args.availability_domains.clone(),
        file,
        "AVAILABILITY_DOMAINS",
    )?
    .or(pick(None::<String>, file, "AVAILABILITY_DOMAIN")?)
    .or_else(|| std::env::var("AVAILABILITY_DOMAIN").ok());
    let subnet_id = pick(args.subnet_id.clone(), file, "SUBNET_ID")?;
    let image_id = pick(args.image_id.clone(), file, "IMAGE_ID")?;
    let ssh_key_file = pick(args.ssh_key_file.clone(), file, "SSH_KEY_FILE")?;
    let ocpus = pick(args.ocpus, file, "OCPUS")?;
    let memory_gb = pick(args.memory_gb, file, "MEMORY_GB")?;
    let display_name =
        pick(args.display_name.clone(), file, "DISPLAY_NAME")?.unwrap_or("arm-free-1".into());
    let boot_volume_gb = pick(args.boot_volume_gb, file, "BOOT_VOLUME_GB")?;
    let interval = pick(args.retry_interval, file, "RETRY_INTERVAL")?.unwrap_or(DEFAULT_INTERVAL);
    let max_attempts = pick(args.max_attempts, file, "MAX_ATTEMPTS")?;

    let availability_domains: Vec<String> = ads
        .iter()
        .flat_map(|list| list.split(','))
        .map(str::trim)
        .filter(|ad| !ad.is_empty())
        .map(str::to_owned)
        .collect();

    let mut missing = Vec::new();
    for (name, set) in [
        ("COMPARTMENT_ID", compartment_id.is_some()),
        ("AVAILABILITY_DOMAIN(S)", !availability_domains.is_empty()),
        ("SUBNET_ID", subnet_id.is_some()),
        ("IMAGE_ID", image_id.is_some()),
        ("SSH_KEY_FILE", ssh_key_file.is_some()),
        ("OCPUS", ocpus.is_some()),
        ("MEMORY_GB", memory_gb.is_some()),
    ] {
        if !set {
            missing.push(name);
        }
    }
    if !missing.is_empty() {
        bail!(UsageError::new(format!(
            "missing settings: {}\n\
             Put them in .env (see .env.example) or pass them as flags; \
             `oci-arm-catcher discover` prints most of them.",
            missing.join(", ")
        )));
    }

    let ssh_key_file = expand_home(&ssh_key_file.unwrap_or_default());
    let ssh_key = read_public_key(&ssh_key_file)?;

    Ok(Plan {
        details: LaunchDetails {
            availability_domain: String::new(),
            compartment_id: compartment_id.unwrap_or_default(),
            display_name,
            shape: A1_FLEX.to_owned(),
            shape_config: ShapeConfig {
                ocpus: ocpus.unwrap_or_default(),
                memory_in_gbs: memory_gb.unwrap_or_default(),
            },
            source_details: SourceDetails {
                source_type: "image".to_owned(),
                image_id: image_id.unwrap_or_default(),
                boot_volume_size_in_gbs: boot_volume_gb,
            },
            create_vnic_details: VnicDetails {
                subnet_id: subnet_id.unwrap_or_default(),
                assign_public_ip: true,
            },
            metadata: BTreeMap::from([("ssh_authorized_keys".to_owned(), ssh_key)]),
        },
        availability_domains,
        interval: Duration::from_secs(interval),
        max_attempts,
    })
}

/// The public key to put on the instance, refusing a private key by mistake.
fn read_public_key(path: &Path) -> Result<String> {
    let key = std::fs::read_to_string(path)
        .map_err(|e| UsageError::new(format!("SSH public key {}: {e}", path.display())))?;
    if key.contains("PRIVATE KEY") {
        bail!(UsageError::new(format!(
            "{} is a private key; SSH_KEY_FILE must be the .pub file",
            path.display()
        )));
    }
    Ok(key.trim().to_owned())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn env_with_key(dir: &Path) -> EnvFile {
        let key = dir.join("id.pub");
        std::fs::write(&key, "ssh-ed25519 AAAA test\n").unwrap();
        parse_env(&format!(
            r#"
# comment
COMPARTMENT_ID="ocid1.tenancy.oc1..t"
AVAILABILITY_DOMAIN="Abcd:EU-AMSTERDAM-1-AD-1"
SUBNET_ID='ocid1.subnet.oc1..s'
IMAGE_ID=ocid1.image.oc1..i
export SSH_KEY_FILE="{}"
OCPUS=2
MEMORY_GB=12
"#,
            key.display()
        ))
    }

    #[test]
    fn parses_script_style_env_files() {
        let vars = parse_env("A=\"1\"\nB='two'\nexport C=3\n# D=4\nE=$HOME/x\nbad line\n");
        assert_eq!(vars["A"], "1");
        assert_eq!(vars["B"], "two");
        assert_eq!(vars["C"], "3");
        assert!(!vars.contains_key("D"));
        assert_eq!(vars["E"], format!("{}/x", dirs_home()));
    }

    #[test]
    fn builds_a_plan_from_env_file() {
        let dir = tempfile::tempdir().unwrap();
        let plan = plan(&LaunchArgs::default(), &env_with_key(dir.path())).unwrap();
        assert_eq!(plan.availability_domains, ["Abcd:EU-AMSTERDAM-1-AD-1"]);
        assert_eq!(plan.details.shape_config.ocpus, 2.0);
        assert_eq!(plan.details.display_name, "arm-free-1");
        assert_eq!(
            plan.details.metadata["ssh_authorized_keys"],
            "ssh-ed25519 AAAA test"
        );
        assert_eq!(plan.interval, Duration::from_secs(300));
        assert_eq!(plan.details.source_details.boot_volume_size_in_gbs, None);
    }

    #[test]
    fn flags_override_file_and_ad_list_wins() {
        let dir = tempfile::tempdir().unwrap();
        let mut file = env_with_key(dir.path());
        file.insert("AVAILABILITY_DOMAINS".into(), "AD-1, AD-2,".into());
        file.insert("BOOT_VOLUME_GB".into(), "100".into());
        let args = LaunchArgs {
            ocpus: Some(4.0),
            ..LaunchArgs::default()
        };
        let plan = plan(&args, &file).unwrap();
        assert_eq!(plan.details.shape_config.ocpus, 4.0);
        assert_eq!(plan.availability_domains, ["AD-1", "AD-2"]);
        assert_eq!(
            plan.details.source_details.boot_volume_size_in_gbs,
            Some(100)
        );
    }

    #[test]
    fn reports_all_missing_settings() {
        let err = plan(&LaunchArgs::default(), &EnvFile::new()).unwrap_err();
        let msg = err.to_string();
        for key in ["COMPARTMENT_ID", "SUBNET_ID", "IMAGE_ID", "OCPUS"] {
            assert!(msg.contains(key), "{msg}");
        }
    }

    #[test]
    fn rejects_bad_numbers_and_private_keys() {
        let dir = tempfile::tempdir().unwrap();
        let mut file = env_with_key(dir.path());
        file.insert("OCPUS".into(), "two".into());
        assert!(
            plan(&LaunchArgs::default(), &file)
                .unwrap_err()
                .to_string()
                .contains("OCPUS")
        );

        let mut file = env_with_key(dir.path());
        let private = dir.path().join("id");
        std::fs::write(&private, "-----BEGIN OPENSSH PRIVATE KEY-----").unwrap();
        file.insert("SSH_KEY_FILE".into(), private.display().to_string());
        assert!(
            plan(&LaunchArgs::default(), &file)
                .unwrap_err()
                .to_string()
                .contains(".pub")
        );
    }
}
