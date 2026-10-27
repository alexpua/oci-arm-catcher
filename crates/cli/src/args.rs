//! Command-line arguments.
//!
//! Every launch setting can come from a flag, an environment variable, or the `.env` file the
//! shell scripts use — in that order of precedence — so an existing `.env` keeps working.

use std::path::PathBuf;

use clap::{Args as ClapArgs, Parser, Subcommand};

/// Grab Oracle Cloud's free ARM (A1.Flex) capacity the moment it appears.
///
/// Retries LaunchInstance until OCI stops answering "Out of host capacity", then launches your
/// instance and notifies you. Talks to the OCI API directly: no OCI CLI, no Python.
#[derive(Debug, Parser)]
#[command(
    name = "oci-arm-catcher",
    version,
    args_conflicts_with_subcommands = true
)]
pub struct Args {
    #[command(subcommand)]
    pub command: Option<Command>,

    #[command(flatten)]
    pub launch: LaunchArgs,

    #[command(flatten)]
    pub common: CommonArgs,
}

#[derive(Debug, Subcommand)]
pub enum Command {
    /// Retry launching until capacity appears (the default).
    Run(LaunchArgs),
    /// Check that your OCI config and API key work (read-only).
    Check,
    /// Print the OCIDs you need, as lines ready to paste into .env (read-only).
    Discover(DiscoverArgs),
}

/// Where credentials and settings come from.
#[derive(Debug, Clone, ClapArgs)]
pub struct CommonArgs {
    /// Settings file in KEY=value form [default: ./.env if present].
    #[arg(long, global = true, env = "OCI_ARM_CATCHER_ENV", value_name = "FILE")]
    pub env_file: Option<PathBuf>,

    /// OCI config file [default: ~/.oci/config].
    #[arg(long, global = true, env = "OCI_CONFIG_FILE", value_name = "FILE")]
    pub oci_config: Option<PathBuf>,

    /// Profile in the OCI config file.
    #[arg(
        long,
        global = true,
        env = "OCI_CLI_PROFILE",
        default_value = "DEFAULT"
    )]
    pub profile: String,
}

/// What to launch. Each flag falls back to the variable of the same name in .env.
#[derive(Debug, Clone, Default, ClapArgs)]
pub struct LaunchArgs {
    /// Compartment OCID (the tenancy OCID works).
    #[arg(long, env = "COMPARTMENT_ID", value_name = "OCID")]
    pub compartment_id: Option<String>,

    /// Availability domain(s); comma-separated to rotate one per attempt.
    #[arg(long, env = "AVAILABILITY_DOMAINS", value_name = "AD[,AD...]")]
    pub availability_domains: Option<String>,

    /// Subnet OCID (public, if you want a public IP).
    #[arg(long, env = "SUBNET_ID", value_name = "OCID")]
    pub subnet_id: Option<String>,

    /// ARM (aarch64) image OCID.
    #[arg(long, env = "IMAGE_ID", value_name = "OCID")]
    pub image_id: Option<String>,

    /// SSH public key file (.pub).
    #[arg(long, env = "SSH_KEY_FILE", value_name = "FILE")]
    pub ssh_key_file: Option<String>,

    /// OCPUs (Always Free: 2 in total).
    #[arg(long, env = "OCPUS")]
    pub ocpus: Option<f32>,

    /// Memory in GB (Always Free: 12 in total).
    #[arg(long, env = "MEMORY_GB")]
    pub memory_gb: Option<f32>,

    /// Instance name in the console [default: arm-free-1].
    #[arg(long, env = "DISPLAY_NAME")]
    pub display_name: Option<String>,

    /// Boot volume size in GB [default: the image's, ~47].
    #[arg(long, env = "BOOT_VOLUME_GB", value_name = "GB")]
    pub boot_volume_gb: Option<u64>,

    /// Seconds between attempts [default: 300].
    #[arg(long, env = "RETRY_INTERVAL", value_name = "SECONDS")]
    pub retry_interval: Option<u64>,

    /// Give up after this many attempts [default: never].
    #[arg(long, env = "MAX_ATTEMPTS", value_name = "N")]
    pub max_attempts: Option<u64>,
}

#[derive(Debug, Clone, ClapArgs)]
pub struct DiscoverArgs {
    /// Operating system to find the latest A1 image for.
    #[arg(long, default_value = "Canonical Ubuntu")]
    pub os: String,

    /// Compartment to look in [default: COMPARTMENT_ID, else the tenancy].
    #[arg(long, value_name = "OCID")]
    pub compartment_id: Option<String>,
}
