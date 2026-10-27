//! The subcommands.

use anyhow::{Context as _, Result};
use oci_arm_catcher_core::config::{DEFAULT_PROFILE, Profile};
use oci_arm_catcher_core::{A1_FLEX, Client, Error, catcher};

use crate::args::{Args, Command, CommonArgs, DiscoverArgs, LaunchArgs};
use crate::exit::UsageError;
use crate::settings::{self, EnvFile};
use crate::ui::{self, Console};

pub fn run(args: &Args) -> Result<()> {
    let (env_path, env_file) = settings::load_env_file(&args.common)?;
    match &args.command {
        None => catch(&args.launch, &args.common, &env_file, env_path.as_deref()),
        Some(Command::Run(launch)) => catch(launch, &args.common, &env_file, env_path.as_deref()),
        Some(Command::Check) => check(&args.common),
        Some(Command::Discover(discover)) => self::discover(discover, &args.common, &env_file),
    }
}

fn client(common: &CommonArgs) -> Result<Client> {
    let path = match &common.oci_config {
        Some(path) => path.clone(),
        None => Profile::default_path()
            .ok_or_else(|| UsageError::new("cannot find your home directory; pass --oci-config"))?,
    };
    let profile = Profile::load(&path, &common.profile).map_err(usage_if_local)?;
    Client::new(&profile).map_err(usage_if_local)
}

/// A broken config file or key is the user's to fix, like a bad flag.
fn usage_if_local(error: Error) -> anyhow::Error {
    match error {
        Error::Config { .. } | Error::Key { .. } => UsageError::new(error.to_string()).into(),
        other => other.into(),
    }
}

fn catch(
    launch: &LaunchArgs,
    common: &CommonArgs,
    env_file: &EnvFile,
    env_path: Option<&std::path::Path>,
) -> Result<()> {
    let plan = settings::plan(launch, env_file)?;
    let client = client(common)?;

    println!("=== oci-arm-catcher {} ===", env!("CARGO_PKG_VERSION"));
    if let Some(path) = env_path {
        println!("Settings: {}", path.display());
    }
    if common.profile != DEFAULT_PROFILE {
        println!("Profile: {}", common.profile);
    }
    let d = &plan.details;
    println!(
        "Region: {}  |  {A1_FLEX}  |  OCPU: {}  |  RAM: {} GB",
        client.region(),
        d.shape_config.ocpus,
        d.shape_config.memory_in_gbs
    );
    if let Some(gb) = d.source_details.boot_volume_size_in_gbs {
        println!("Boot volume: {gb} GB");
    }
    println!(
        "Availability domain{}: {}",
        if plan.availability_domains.len() > 1 {
            "s (rotating)"
        } else {
            ""
        },
        plan.availability_domains.join(", ")
    );
    println!("Retry interval: {}s\n", plan.interval.as_secs());

    match catcher::run(&client, &plan, &mut Console::new()) {
        Ok(instance) => {
            let message = format!("SUCCESS! Instance created: {}", instance.id);
            println!("\n{message}");
            if let Some(state) = &instance.lifecycle_state {
                println!("State: {state}");
            }
            println!(
                "Console: https://cloud.oracle.com/compute/instances/{}?region={}",
                instance.id,
                client.region()
            );
            ui::notify(&message);
            Ok(())
        }
        Err(error) => {
            ui::notify(&format!("Stopped: {error}"));
            Err(match hint_for(&error) {
                Some(hint) => anyhow::anyhow!("{error}\n\nhint: {hint}"),
                None => error.into(),
            })
        }
    }
}

/// A next step for the errors people actually hit.
fn hint_for(error: &Error) -> Option<&'static str> {
    let Error::Api(api) = error else {
        return None;
    };
    Some(match (api.status, api.code.as_str()) {
        (_, "LimitExceeded") => {
            "You are over your A1 allowance (Always Free: 2 OCPU / 12 GB in total). \
             Lower OCPUS / MEMORY_GB or remove existing A1 instances."
        }
        (401, _) => {
            "Authentication failed. Run `oci-arm-catcher check`, and make sure the key's \
             fingerprint in ~/.oci/config matches the API key uploaded in the console."
        }
        (404, _) => {
            "An OCID was not found or you lack access. Check that COMPARTMENT_ID, SUBNET_ID and \
             IMAGE_ID are from the same region as your profile."
        }
        _ => return None,
    })
}

fn check(common: &CommonArgs) -> Result<()> {
    let client = client(common)?;
    let ads = client
        .availability_domains()
        .context("signed request to OCI failed")?;
    println!(
        "OK: authenticated to {} as tenancy {}",
        client.region(),
        client.tenancy()
    );
    for ad in ads {
        println!("  availability domain: {}", ad.name);
    }
    Ok(())
}

fn discover(args: &DiscoverArgs, common: &CommonArgs, env_file: &EnvFile) -> Result<()> {
    let client = client(common)?;
    let compartment = args
        .compartment_id
        .clone()
        .or_else(|| env_file.get("COMPARTMENT_ID").cloned())
        .unwrap_or_else(|| client.tenancy().to_owned());

    println!(
        "# Region: {} — paste what you need into .env\n",
        client.region()
    );
    println!("COMPARTMENT_ID=\"{compartment}\"");

    let ads = client.availability_domains()?;
    let names: Vec<_> = ads.iter().map(|ad| ad.name.as_str()).collect();
    if names.len() > 1 {
        println!("AVAILABILITY_DOMAINS=\"{}\"", names.join(","));
    } else if let Some(ad) = names.first() {
        println!("AVAILABILITY_DOMAIN=\"{ad}\"");
    }

    let subnets = client.subnets(&compartment)?;
    let public: Vec<_> = subnets
        .iter()
        .filter(|s| s.prohibit_public_ip_on_vnic != Some(true))
        .collect();
    match public.as_slice() {
        [] => println!(
            "# No public subnet in this compartment. Create a VCN with the console's \
             \"VCN Wizard\" (Internet connectivity), then run discover again."
        ),
        [only] => println!("SUBNET_ID=\"{}\"", only.id),
        many => {
            println!("# Public subnets (pick one):");
            for (i, s) in many.iter().enumerate() {
                let line = format!("SUBNET_ID=\"{}\"", s.id);
                let name = s.display_name.as_deref().unwrap_or("");
                let cidr = s.cidr_block.as_deref().unwrap_or("");
                if i == 0 {
                    println!("{line}  # {name} {cidr}");
                } else {
                    println!("# {line}  # {name} {cidr}");
                }
            }
        }
    }

    let images = client.a1_images(&compartment, &args.os)?;
    match images.first() {
        Some(image) => println!(
            "IMAGE_ID=\"{}\"  # {}",
            image.id,
            image.display_name.as_deref().unwrap_or(&args.os)
        ),
        None => println!(
            "# No A1 image found for \"{}\"; try --os \"Oracle Linux\"",
            args.os
        ),
    }

    for key in ["id_ed25519.pub", "id_rsa.pub"] {
        let path = oci_arm_catcher_core::config::expand_home(&format!("~/.ssh/{key}"));
        if path.is_file() {
            println!("SSH_KEY_FILE=\"{}\"", path.display());
            break;
        }
    }
    println!("OCPUS=2\nMEMORY_GB=12");
    Ok(())
}
