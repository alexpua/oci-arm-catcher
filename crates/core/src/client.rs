//! A minimal signed HTTP client for the OCI REST API.

use std::time::{Duration, SystemTime};

use serde::Serialize;
use serde::de::DeserializeOwned;

use crate::config::Profile;
use crate::error::{ApiError, Error, Result};
use crate::signer::{Request, Signer};

/// A signed connection to one region.
pub struct Client {
    signer: Signer,
    region: String,
    tenancy: String,
    agent: ureq::Agent,
}

impl Client {
    /// A client for the profile's tenancy and home region.
    pub fn new(profile: &Profile) -> Result<Self> {
        let agent = ureq::Agent::config_builder()
            // We read OCI's error body ourselves.
            .http_status_as_error(false)
            .timeout_connect(Some(Duration::from_secs(30)))
            .timeout_global(Some(Duration::from_secs(120)))
            .user_agent(concat!("oci-arm-catcher/", env!("CARGO_PKG_VERSION")))
            .build()
            .into();
        Ok(Self {
            signer: Signer::from_profile(profile)?,
            region: profile.region.clone(),
            tenancy: profile.tenancy.clone(),
            agent,
        })
    }

    /// The region requests go to.
    pub fn region(&self) -> &str {
        &self.region
    }

    /// The tenancy OCID, which is also the root compartment.
    pub fn tenancy(&self) -> &str {
        &self.tenancy
    }

    /// `GET` a JSON resource from `service` (`iaas`, `identity`, ...).
    pub(crate) fn get<T: DeserializeOwned>(
        &self,
        service: &str,
        path_and_query: &str,
    ) -> Result<T> {
        self.send(service, "get", path_and_query, None, &[])
    }

    /// `POST` a JSON body to `service`.
    pub(crate) fn post<B: Serialize, T: DeserializeOwned>(
        &self,
        service: &str,
        path: &str,
        body: &B,
        extra_headers: &[(&str, &str)],
    ) -> Result<T> {
        let body = serde_json::to_vec(body).expect("request types always serialize");
        self.send(service, "post", path, Some(&body), extra_headers)
    }

    fn send<T: DeserializeOwned>(
        &self,
        service: &str,
        method: &str,
        path_and_query: &str,
        body: Option<&[u8]>,
        extra_headers: &[(&str, &str)],
    ) -> Result<T> {
        let host = format!("{service}.{}.oraclecloud.com", self.region);
        let url = format!("https://{host}{path_and_query}");
        let date = httpdate::fmt_http_date(SystemTime::now());
        let signed = self.signer.sign(&Request {
            method,
            host: &host,
            path_and_query,
            date: &date,
            body,
        });

        // ureq sets content-length from the body itself; ours is the same number.
        let headers = std::iter::once(("date", date.as_str()))
            .chain(
                signed
                    .iter()
                    .filter(|(name, _)| *name != "content-length")
                    .map(|(name, value)| (*name, value.as_str())),
            )
            .chain(extra_headers.iter().copied());

        let transport = |e: ureq::Error| Error::Transport(e.to_string());
        let mut response = match body {
            Some(body) => {
                let mut request = self.agent.post(&url);
                for (name, value) in headers {
                    request = request.header(name, value);
                }
                request.send(body).map_err(transport)?
            }
            None => {
                let mut request = self.agent.get(&url);
                for (name, value) in headers {
                    request = request.header(name, value);
                }
                request.call().map_err(transport)?
            }
        };

        let status = response.status().as_u16();
        let request_id = response
            .headers()
            .get("opc-request-id")
            .and_then(|v| v.to_str().ok())
            .map(str::to_owned);
        let text = response
            .body_mut()
            .read_to_string()
            .map_err(|e| Error::Transport(e.to_string()))?;

        if (200..300).contains(&status) {
            serde_json::from_str(&text)
                .map_err(|e| Error::Transport(format!("unexpected response from {service}: {e}")))
        } else {
            Err(api_error(status, &text, request_id).into())
        }
    }
}

/// Turn an error response into an [`ApiError`], whatever shape its body has.
pub(crate) fn api_error(status: u16, body: &str, request_id: Option<String>) -> ApiError {
    #[derive(serde::Deserialize)]
    struct Body {
        code: Option<String>,
        message: Option<String>,
    }
    let parsed: Option<Body> = serde_json::from_str(body).ok();
    let code = parsed.as_ref().and_then(|b| b.code.clone());
    let message = parsed.and_then(|b| b.message);
    ApiError {
        status,
        code: code.unwrap_or_else(|| format!("Http{status}")),
        message: message.unwrap_or_else(|| {
            let trimmed = body.trim();
            if trimmed.is_empty() {
                "no message".to_owned()
            } else {
                trimmed.chars().take(200).collect()
            }
        }),
        request_id,
    }
}

/// Percent-encode a query value (RFC 3986 unreserved characters pass through).
pub(crate) fn encode(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    for byte in value.bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(byte as char)
            }
            _ => out.push_str(&format!("%{byte:02X}")),
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_oci_error_bodies() {
        let e = api_error(
            500,
            r#"{"code":"InternalError","message":"Out of host capacity."}"#,
            Some("req-1".into()),
        );
        assert_eq!(e.code, "InternalError");
        assert_eq!(e.message, "Out of host capacity.");
        assert_eq!(e.request_id.as_deref(), Some("req-1"));
    }

    #[test]
    fn survives_non_json_bodies() {
        let e = api_error(502, "<html>Bad Gateway</html>", None);
        assert_eq!(e.code, "Http502");
        assert_eq!(e.message, "<html>Bad Gateway</html>");
        assert_eq!(api_error(503, "", None).message, "no message");
    }

    #[test]
    fn encodes_query_values() {
        assert_eq!(
            encode("Abcd:EU-AMSTERDAM-1-AD-1"),
            "Abcd%3AEU-AMSTERDAM-1-AD-1"
        );
        assert_eq!(encode("Canonical Ubuntu"), "Canonical%20Ubuntu");
        assert_eq!(encode("ocid1.tenancy.oc1..aa"), "ocid1.tenancy.oc1..aa");
    }
}
