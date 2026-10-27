//! OCI request signing: draft-cavage HTTP Signatures with RSA-SHA256.
//!
//! See <https://docs.oracle.com/iaas/Content/API/Concepts/signingrequests.htm>. GET and DELETE
//! sign `date (request-target) host`; requests with a body also sign its length, type and
//! SHA-256.

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD as BASE64;
use ring::rand::SystemRandom;
use ring::signature::{RSA_PKCS1_SHA256, RsaKeyPair};

use crate::config::Profile;
use crate::error::{Error, Result};

/// Signs requests on behalf of one API key.
pub struct Signer {
    key_id: String,
    key: RsaKeyPair,
    rng: SystemRandom,
}

/// What a request carries, as far as the signature is concerned.
pub struct Request<'a> {
    /// Lower-case HTTP method.
    pub method: &'a str,
    /// Host header, e.g. `iaas.eu-amsterdam-1.oraclecloud.com`.
    pub host: &'a str,
    /// Path plus query string, exactly as sent.
    pub path_and_query: &'a str,
    /// RFC 7231 date, exactly as sent in the `date` header.
    pub date: &'a str,
    /// JSON body, for POST and PUT.
    pub body: Option<&'a [u8]>,
}

impl Signer {
    /// Load the key named by `profile`.
    pub fn from_profile(profile: &Profile) -> Result<Self> {
        let key_err = |reason: String| Error::Key {
            path: profile.key_file.clone(),
            reason,
        };
        let pem = std::fs::read_to_string(&profile.key_file).map_err(|e| key_err(e.to_string()))?;
        let key_id = format!(
            "{}/{}/{}",
            profile.tenancy, profile.user, profile.fingerprint
        );
        Self::from_pem(key_id, &pem).map_err(key_err)
    }

    /// A signer for `key_id` (`tenancy/user/fingerprint`) from an unencrypted PEM key, PKCS#8
    /// (`BEGIN PRIVATE KEY`) or PKCS#1 (`BEGIN RSA PRIVATE KEY`).
    pub fn from_pem(key_id: String, pem: &str) -> std::result::Result<Self, String> {
        if pem.contains("ENCRYPTED") {
            return Err(
                "encrypted keys are not supported yet; write an unencrypted copy with \
                 `openssl rsa -in key.pem -out key_nopass.pem` and point key_file at it"
                    .to_owned(),
            );
        }
        let (label, der) = decode_pem(pem)?;
        let key = match label.as_str() {
            "PRIVATE KEY" => RsaKeyPair::from_pkcs8(&der).map_err(|e| e.to_string())?,
            "RSA PRIVATE KEY" => RsaKeyPair::from_der(&der).map_err(|e| e.to_string())?,
            other => return Err(format!("expected an RSA private key, found `{other}`")),
        };
        Ok(Self {
            key_id,
            key,
            rng: SystemRandom::new(),
        })
    }

    /// The headers to add to `request`: `authorization`, plus the body headers for requests
    /// that have one. `date` and `host` are the caller's to send.
    pub fn sign(&self, request: &Request<'_>) -> Vec<(&'static str, String)> {
        let mut headers = Vec::new();
        let body = request.body.map(|body| {
            let sha = BASE64.encode(ring::digest::digest(&ring::digest::SHA256, body));
            (body.len().to_string(), sha)
        });
        if let Some((len, sha)) = &body {
            headers.push(("content-length", len.clone()));
            headers.push(("content-type", "application/json".to_owned()));
            headers.push(("x-content-sha256", sha.clone()));
        }

        let (names, string) = signing_string(request, &headers);
        let mut signature = vec![0; self.key.public().modulus_len()];
        self.key
            .sign(
                &RSA_PKCS1_SHA256,
                &self.rng,
                string.as_bytes(),
                &mut signature,
            )
            .expect("RSA signing with a valid key cannot fail");

        headers.push((
            "authorization",
            format!(
                "Signature version=\"1\",keyId=\"{}\",algorithm=\"rsa-sha256\",headers=\"{names}\",signature=\"{}\"",
                self.key_id,
                BASE64.encode(signature)
            ),
        ));
        headers
    }

    #[cfg(test)]
    fn public_key(&self) -> Vec<u8> {
        use ring::signature::KeyPair as _;
        self.key.public_key().as_ref().to_vec()
    }
}

/// The space-separated header list and the newline-joined string that gets signed.
fn signing_string(request: &Request<'_>, body_headers: &[(&str, String)]) -> (String, String) {
    let mut lines = vec![
        ("date", request.date.to_owned()),
        (
            "(request-target)",
            format!("{} {}", request.method, request.path_and_query),
        ),
        ("host", request.host.to_owned()),
    ];
    lines.extend(body_headers.iter().map(|(k, v)| (*k, v.clone())));
    let names = lines.iter().map(|(k, _)| *k).collect::<Vec<_>>().join(" ");
    let string = lines
        .iter()
        .map(|(k, v)| format!("{k}: {v}"))
        .collect::<Vec<_>>()
        .join("\n");
    (names, string)
}

/// The label and DER bytes of the first PEM block in `pem`.
fn decode_pem(pem: &str) -> std::result::Result<(String, Vec<u8>), String> {
    let mut lines = pem.lines().map(str::trim);
    let label = lines
        .by_ref()
        .find_map(|l| l.strip_prefix("-----BEGIN ")?.strip_suffix("-----"))
        .ok_or("not a PEM file")?
        .to_owned();
    let end = format!("-----END {label}-----");
    let body: String = lines.take_while(|l| *l != end).collect();
    let der = BASE64
        .decode(body)
        .map_err(|e| format!("bad PEM body: {e}"))?;
    Ok((label, der))
}

#[cfg(test)]
mod tests {
    use super::*;
    use ring::signature::{RSA_PKCS1_2048_8192_SHA256, UnparsedPublicKey};

    const PKCS8: &str = include_str!("../testdata/test-key-pkcs8.pem");
    const PKCS1: &str = include_str!("../testdata/test-key-pkcs1.pem");

    fn signer(pem: &str) -> Signer {
        Signer::from_pem("ocid1.tenancy/ocid1.user/aa:bb".to_owned(), pem).unwrap()
    }

    fn get() -> Request<'static> {
        Request {
            method: "get",
            host: "iaas.eu-amsterdam-1.oraclecloud.com",
            path_and_query: "/20160918/subnets?compartmentId=ocid1.tenancy.oc1..x",
            date: "Thu, 05 Jan 2014 21:31:40 GMT",
            body: None,
        }
    }

    /// Pull a quoted parameter out of the authorization header.
    fn param<'a>(auth: &'a str, name: &str) -> &'a str {
        let start = auth.find(&format!("{name}=\"")).unwrap() + name.len() + 2;
        let len = auth[start..].find('"').unwrap();
        &auth[start..start + len]
    }

    #[test]
    fn get_signs_date_target_and_host() {
        let (names, string) = signing_string(&get(), &[]);
        assert_eq!(names, "date (request-target) host");
        assert_eq!(
            string,
            "date: Thu, 05 Jan 2014 21:31:40 GMT\n\
             (request-target): get /20160918/subnets?compartmentId=ocid1.tenancy.oc1..x\n\
             host: iaas.eu-amsterdam-1.oraclecloud.com"
        );
    }

    #[test]
    fn signature_verifies_against_the_public_key() {
        for pem in [PKCS8, PKCS1] {
            let signer = signer(pem);
            let headers = signer.sign(&get());
            assert_eq!(headers.len(), 1);
            let auth = &headers[0].1;
            assert_eq!(param(auth, "keyId"), "ocid1.tenancy/ocid1.user/aa:bb");
            assert_eq!(param(auth, "algorithm"), "rsa-sha256");

            let (_, string) = signing_string(&get(), &[]);
            let signature = BASE64.decode(param(auth, "signature")).unwrap();
            UnparsedPublicKey::new(&RSA_PKCS1_2048_8192_SHA256, signer.public_key())
                .verify(string.as_bytes(), &signature)
                .expect("signature must verify");
        }
    }

    #[test]
    fn body_headers_are_signed() {
        let body = br#"{"a":1}"#;
        let request = Request {
            method: "post",
            body: Some(body),
            ..get()
        };
        let headers = signer(PKCS8).sign(&request);
        let get_header = |name| headers.iter().find(|(k, _)| *k == name).unwrap().1.clone();
        assert_eq!(get_header("content-length"), "7");
        assert_eq!(get_header("content-type"), "application/json");
        let expected_sha = BASE64.encode(ring::digest::digest(&ring::digest::SHA256, body));
        assert_eq!(get_header("x-content-sha256"), expected_sha);
        assert_eq!(
            param(&get_header("authorization"), "headers"),
            "date (request-target) host content-length content-type x-content-sha256"
        );
    }

    #[test]
    fn rejects_encrypted_and_non_keys() {
        let encrypted =
            "-----BEGIN ENCRYPTED PRIVATE KEY-----\nAAAA\n-----END ENCRYPTED PRIVATE KEY-----";
        assert!(
            Signer::from_pem(String::new(), encrypted)
                .err()
                .unwrap()
                .contains("encrypted")
        );
        assert!(Signer::from_pem(String::new(), "hello").is_err());
        let public = "-----BEGIN PUBLIC KEY-----\nAAAA\n-----END PUBLIC KEY-----";
        assert!(
            Signer::from_pem(String::new(), public)
                .err()
                .unwrap()
                .contains("PUBLIC KEY")
        );
    }
}
