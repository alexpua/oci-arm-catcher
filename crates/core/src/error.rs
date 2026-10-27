//! Engine errors.

use std::fmt;
use std::path::PathBuf;

use thiserror::Error as ThisError;

/// Result alias used throughout the engine.
pub type Result<T> = std::result::Result<T, Error>;

/// Anything the engine can fail with.
#[derive(Debug, ThisError)]
#[non_exhaustive]
pub enum Error {
    /// The OCI config file is missing, unreadable or incomplete.
    #[error("OCI config `{}`: {reason}", path.display())]
    Config {
        /// The config file we tried to use.
        path: PathBuf,
        /// What is wrong with it.
        reason: String,
    },

    /// The API signing key could not be loaded.
    #[error("API signing key `{}`: {reason}", path.display())]
    Key {
        /// The key file named in the OCI config.
        path: PathBuf,
        /// Why it cannot be used.
        reason: String,
    },

    /// OCI answered with an error status.
    #[error(transparent)]
    Api(#[from] ApiError),

    /// The request never got an answer: DNS, TLS, connection reset, timeout.
    #[error("network error: {0}")]
    Transport(String),
}

/// An error response from the OCI API.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ApiError {
    /// HTTP status code.
    pub status: u16,
    /// OCI error code, e.g. `InternalError` or `NotAuthenticated`.
    pub code: String,
    /// Human-readable message from OCI.
    pub message: String,
    /// `opc-request-id`, which Oracle support asks for.
    pub request_id: Option<String>,
}

impl fmt::Display for ApiError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}: {} (HTTP {})", self.code, self.message, self.status)
    }
}

impl std::error::Error for ApiError {}
