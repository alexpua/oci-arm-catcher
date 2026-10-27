//! The OCI config file (`~/.oci/config`), as written by `oci setup config` or the console's
//! "Add API key" dialog.

use std::collections::HashMap;
use std::path::{Path, PathBuf};

use crate::error::{Error, Result};

/// The profile used when none is named.
pub const DEFAULT_PROFILE: &str = "DEFAULT";

/// One profile from the OCI config: who we are and where our key lives.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Profile {
    /// User OCID.
    pub user: String,
    /// Fingerprint of the uploaded public key.
    pub fingerprint: String,
    /// Tenancy OCID — also the root compartment.
    pub tenancy: String,
    /// Home region, e.g. `eu-amsterdam-1`.
    pub region: String,
    /// Path to the PEM private key.
    pub key_file: PathBuf,
    /// Passphrase for an encrypted key, if one is set.
    pub pass_phrase: Option<String>,
}

impl Profile {
    /// `~/.oci/config`, where the OCI CLI and SDKs look by default.
    pub fn default_path() -> Option<PathBuf> {
        dirs::home_dir().map(|home| home.join(".oci").join("config"))
    }

    /// Load profile `name` from the config file at `path`.
    pub fn load(path: &Path, name: &str) -> Result<Self> {
        let text = std::fs::read_to_string(path).map_err(|e| Error::Config {
            path: path.to_owned(),
            reason: if e.kind() == std::io::ErrorKind::NotFound {
                "not found — create it with `oci setup config` or the console's \"Add API key\""
                    .to_owned()
            } else {
                e.to_string()
            },
        })?;
        Self::parse(&text, name).map_err(|reason| Error::Config {
            path: path.to_owned(),
            reason,
        })
    }

    /// Parse profile `name` out of config file contents. Like the OCI SDKs, every profile
    /// inherits the keys of `[DEFAULT]`.
    pub fn parse(text: &str, name: &str) -> std::result::Result<Self, String> {
        let sections = parse_ini(text);
        if !sections.contains_key(name) {
            return Err(format!("profile [{name}] not found"));
        }
        let get = |key: &str| {
            sections
                .get(name)
                .and_then(|s| s.get(key))
                .or_else(|| sections.get(DEFAULT_PROFILE).and_then(|s| s.get(key)))
                .filter(|v| !v.is_empty())
                .cloned()
        };
        let require = |key: &str| get(key).ok_or_else(|| format!("[{name}] has no `{key}`"));

        Ok(Self {
            user: require("user")?,
            fingerprint: require("fingerprint")?,
            tenancy: require("tenancy")?,
            region: require("region")?,
            key_file: expand_home(&require("key_file")?),
            pass_phrase: get("pass_phrase"),
        })
    }
}

/// `section -> key -> value`, the subset of INI the OCI config uses.
fn parse_ini(text: &str) -> HashMap<String, HashMap<String, String>> {
    let mut sections: HashMap<String, HashMap<String, String>> = HashMap::new();
    let mut current: Option<String> = None;
    for line in text.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') || line.starts_with(';') {
            continue;
        }
        if let Some(name) = line.strip_prefix('[').and_then(|l| l.strip_suffix(']')) {
            let name = name.trim().to_owned();
            sections.entry(name.clone()).or_default();
            current = Some(name);
        } else if let (Some(section), Some((key, value))) = (&current, line.split_once('=')) {
            sections
                .entry(section.clone())
                .or_default()
                .insert(key.trim().to_owned(), value.trim().to_owned());
        }
    }
    sections
}

/// Expand a leading `~` the way the OCI CLI does.
pub fn expand_home(path: &str) -> PathBuf {
    match (path.strip_prefix("~"), dirs::home_dir()) {
        (Some(rest), Some(home)) => home.join(rest.trim_start_matches(['/', '\\'])),
        _ => PathBuf::from(path),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const CONFIG: &str = "\
[DEFAULT]
user=ocid1.user.oc1..aaa
fingerprint=12:34:56
tenancy=ocid1.tenancy.oc1..bbb
region=eu-amsterdam-1
key_file=/keys/oci.pem

# a second profile overriding only the region
[PHX]
region = us-phoenix-1
";

    #[test]
    fn reads_the_default_profile() {
        let p = Profile::parse(CONFIG, DEFAULT_PROFILE).unwrap();
        assert_eq!(p.user, "ocid1.user.oc1..aaa");
        assert_eq!(p.fingerprint, "12:34:56");
        assert_eq!(p.tenancy, "ocid1.tenancy.oc1..bbb");
        assert_eq!(p.region, "eu-amsterdam-1");
        assert_eq!(p.key_file, PathBuf::from("/keys/oci.pem"));
        assert_eq!(p.pass_phrase, None);
    }

    #[test]
    fn named_profiles_inherit_default() {
        let p = Profile::parse(CONFIG, "PHX").unwrap();
        assert_eq!(p.region, "us-phoenix-1");
        assert_eq!(p.user, "ocid1.user.oc1..aaa");
    }

    #[test]
    fn missing_profile_and_keys_are_reported() {
        assert!(
            Profile::parse(CONFIG, "NOPE")
                .unwrap_err()
                .contains("[NOPE]")
        );
        let err = Profile::parse("[DEFAULT]\nuser=u\n", DEFAULT_PROFILE).unwrap_err();
        assert!(err.contains("fingerprint"), "{err}");
    }

    #[test]
    fn expands_tilde() {
        let home = dirs::home_dir().unwrap();
        assert_eq!(expand_home("~/.oci/key.pem"), home.join(".oci/key.pem"));
        assert_eq!(expand_home("/abs/key.pem"), PathBuf::from("/abs/key.pem"));
    }
}
