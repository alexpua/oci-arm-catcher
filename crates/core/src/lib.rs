//! `oci-arm-catcher-core` — talks to the Oracle Cloud API directly (no OCI CLI, no Python)
//! and retries `LaunchInstance` until free Ampere A1 capacity turns up.
//!
//! - [`config`]: reads `~/.oci/config`
//! - [`signer`]: OCI request signatures (RSA-SHA256)
//! - [`client`] / [`api`]: the few endpoints we call
//! - [`catcher`]: error classification and the retry loop

pub mod api;
pub mod catcher;
pub mod client;
pub mod config;
mod error;
pub mod signer;

pub use api::{A1_FLEX, Instance, LaunchDetails};
pub use catcher::{Environment, Event, Plan, RetryReason};
pub use client::Client;
pub use config::Profile;
pub use error::{ApiError, Error, Result};
