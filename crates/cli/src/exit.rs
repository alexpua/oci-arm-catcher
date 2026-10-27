//! Process exit codes.
//!
//! | code | meaning |
//! |------|---------|
//! | 0 | instance launched / check passed |
//! | 1 | OCI refused for good (auth, bad OCID, LimitExceeded, ...) or gave up |
//! | 2 | bad arguments or settings |

use std::fmt;

/// OCI said no, or we ran out of attempts.
pub const FAILURE: u8 = 1;

/// Bad arguments or settings. clap exits with this code on its own for parse errors.
pub const USAGE: u8 = 2;

/// The settings cannot work — reported as exit code 2, like a parse error.
#[derive(Debug)]
pub struct UsageError(pub String);

impl UsageError {
    /// A usage error with the given message.
    pub fn new(message: impl Into<String>) -> Self {
        Self(message.into())
    }
}

impl fmt::Display for UsageError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for UsageError {}

/// The exit code a failed run should end with.
pub fn code_for(error: &anyhow::Error) -> u8 {
    if error.downcast_ref::<UsageError>().is_some() {
        USAGE
    } else {
        FAILURE
    }
}
