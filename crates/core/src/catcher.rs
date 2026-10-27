//! The retry loop: launch, and on a "come back later" answer wait and try again.

use std::time::Duration;

use crate::api::{Instance, LaunchDetails};
use crate::client::Client;
use crate::error::{Error, Result};

/// Why an attempt is worth repeating.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RetryReason {
    /// "Out of host capacity" — the reason this tool exists.
    OutOfCapacity,
    /// HTTP 429.
    Throttled,
    /// Any other 5xx.
    ServerError,
    /// No answer at all. The request may or may not have reached OCI.
    Network,
}

/// Decide whether `error` is worth retrying. `None` means stop.
///
/// The status code does the work: 4xx means the request itself is wrong (bad OCID, auth,
/// `LimitExceeded`) and will be just as wrong next time, while 5xx, 429 and network errors are
/// OCI's side and pass. The one exception is a capacity message on a 4xx, which OCI has used.
pub fn classify(error: &Error) -> Option<RetryReason> {
    match error {
        Error::Transport(_) => Some(RetryReason::Network),
        Error::Api(api) => {
            let message = api.message.to_ascii_lowercase();
            if message.contains("out of host capacity") || message.contains("out of capacity") {
                Some(RetryReason::OutOfCapacity)
            } else if api.status == 429 {
                Some(RetryReason::Throttled)
            } else if api.status >= 500 {
                Some(RetryReason::ServerError)
            } else {
                None
            }
        }
        _ => None,
    }
}

/// Something that can launch an instance — the OCI client, or a fake in tests.
pub trait Launcher {
    /// One `LaunchInstance` call.
    fn launch(&self, details: &LaunchDetails, retry_token: &str) -> Result<Instance>;
}

impl Launcher for Client {
    fn launch(&self, details: &LaunchDetails, retry_token: &str) -> Result<Instance> {
        self.launch_instance(details, retry_token)
    }
}

/// What to launch and how patiently.
#[derive(Debug, Clone)]
pub struct Plan {
    /// Launch request; its availability domain is overwritten from `availability_domains`.
    pub details: LaunchDetails,
    /// Availability domains to rotate through, one per attempt.
    pub availability_domains: Vec<String>,
    /// Wait between attempts.
    pub interval: Duration,
    /// Give up after this many attempts; `None` keeps going.
    pub max_attempts: Option<u64>,
}

/// Progress, for the caller to display.
#[derive(Debug)]
pub enum Event<'a> {
    /// About to call `LaunchInstance`.
    Attempt {
        /// 1-based attempt number.
        number: u64,
        /// Availability domain of this attempt.
        availability_domain: &'a str,
    },
    /// The attempt failed but will be retried after `wait`.
    Retrying {
        /// The error OCI (or the network) gave.
        error: &'a Error,
        /// Why it is retryable.
        reason: RetryReason,
        /// How long until the next attempt.
        wait: Duration,
    },
}

/// What the loop needs from the outside world, so tests can run it instantly.
pub trait Environment {
    /// Report progress.
    fn event(&mut self, event: Event<'_>);
    /// Wait between attempts.
    fn sleep(&mut self, duration: Duration);
    /// A fresh `opc-retry-token`.
    fn new_token(&mut self) -> String;
}

/// Launch until it works, a fatal error comes back, or `max_attempts` runs out.
pub fn run(launcher: &impl Launcher, plan: &Plan, env: &mut impl Environment) -> Result<Instance> {
    assert!(
        !plan.availability_domains.is_empty(),
        "a plan needs at least one availability domain"
    );
    let mut details = plan.details.clone();
    let mut ad_index = 0;
    let mut token = env.new_token();
    let mut attempt = 0;

    loop {
        attempt += 1;
        details
            .availability_domain
            .clone_from(&plan.availability_domains[ad_index]);
        env.event(Event::Attempt {
            number: attempt,
            availability_domain: &details.availability_domain,
        });

        let error = match launcher.launch(&details, &token) {
            Ok(instance) => return Ok(instance),
            Err(error) => error,
        };
        let Some(reason) = classify(&error) else {
            return Err(error);
        };
        if plan.max_attempts.is_some_and(|max| attempt >= max) {
            return Err(error);
        }

        // After a network error the launch may have gone through without us hearing back.
        // Resending the identical request with the same token lets OCI hand back that
        // instance instead of creating a second one. Anything else got a definite "no", so
        // move on to the next AD with a new token.
        if reason != RetryReason::Network {
            ad_index = (ad_index + 1) % plan.availability_domains.len();
            token = env.new_token();
        }

        env.event(Event::Retrying {
            error: &error,
            reason,
            wait: plan.interval,
        });
        env.sleep(plan.interval);
    }
}

/// A random `opc-retry-token`.
pub fn random_token() -> String {
    use ring::rand::{SecureRandom as _, SystemRandom};
    let mut bytes = [0u8; 16];
    SystemRandom::new()
        .fill(&mut bytes)
        .expect("the OS random source is available");
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

#[cfg(test)]
mod tests {
    use std::cell::RefCell;
    use std::collections::{BTreeMap, VecDeque};

    use super::*;
    use crate::api::{A1_FLEX, ShapeConfig, SourceDetails, VnicDetails};
    use crate::error::ApiError;

    fn api(status: u16, code: &str, message: &str) -> Error {
        Error::Api(ApiError {
            status,
            code: code.into(),
            message: message.into(),
            request_id: None,
        })
    }

    fn capacity() -> Error {
        api(500, "InternalError", "Out of host capacity.")
    }

    fn instance() -> Instance {
        Instance {
            id: "ocid1.instance.oc1..caught".into(),
            display_name: None,
            lifecycle_state: Some("PROVISIONING".into()),
            region: None,
        }
    }

    /// Replays scripted results and records what it was asked.
    struct FakeLauncher {
        results: RefCell<VecDeque<Result<Instance>>>,
        calls: RefCell<Vec<(String, String)>>,
    }

    impl FakeLauncher {
        fn new(results: Vec<Result<Instance>>) -> Self {
            Self {
                results: RefCell::new(results.into()),
                calls: RefCell::default(),
            }
        }
    }

    impl Launcher for FakeLauncher {
        fn launch(&self, details: &LaunchDetails, token: &str) -> Result<Instance> {
            self.calls
                .borrow_mut()
                .push((details.availability_domain.clone(), token.to_owned()));
            self.results
                .borrow_mut()
                .pop_front()
                .expect("unscripted call")
        }
    }

    #[derive(Default)]
    struct FakeEnv {
        sleeps: Vec<Duration>,
        tokens: u32,
    }

    impl Environment for FakeEnv {
        fn event(&mut self, _: Event<'_>) {}
        fn sleep(&mut self, d: Duration) {
            self.sleeps.push(d);
        }
        fn new_token(&mut self) -> String {
            self.tokens += 1;
            format!("t{}", self.tokens)
        }
    }

    fn plan(ads: &[&str]) -> Plan {
        Plan {
            details: LaunchDetails {
                availability_domain: String::new(),
                compartment_id: "c".into(),
                display_name: "d".into(),
                shape: A1_FLEX.into(),
                shape_config: ShapeConfig {
                    ocpus: 2.0,
                    memory_in_gbs: 12.0,
                },
                source_details: SourceDetails {
                    source_type: "image".into(),
                    image_id: "i".into(),
                    boot_volume_size_in_gbs: None,
                },
                create_vnic_details: VnicDetails {
                    subnet_id: "s".into(),
                    assign_public_ip: true,
                },
                metadata: BTreeMap::new(),
            },
            availability_domains: ads.iter().map(|s| s.to_string()).collect(),
            interval: Duration::from_secs(300),
            max_attempts: None,
        }
    }

    #[test]
    fn classifies_by_status() {
        assert_eq!(classify(&capacity()), Some(RetryReason::OutOfCapacity));
        assert_eq!(
            classify(&api(400, "InvalidParameter", "Out of capacity for shape")),
            Some(RetryReason::OutOfCapacity)
        );
        assert_eq!(
            classify(&api(429, "TooManyRequests", "slow down")),
            Some(RetryReason::Throttled)
        );
        assert_eq!(
            classify(&api(502, "Http502", "<html>")),
            Some(RetryReason::ServerError)
        );
        assert_eq!(
            classify(&Error::Transport("reset".into())),
            Some(RetryReason::Network)
        );
        for fatal in [
            api(400, "LimitExceeded", "standard-a1-core-count"),
            api(401, "NotAuthenticated", "bad signature"),
            api(404, "NotAuthorizedOrNotFound", "nope"),
            api(400, "InvalidParameter", "bad image"),
        ] {
            assert_eq!(classify(&fatal), None, "{fatal}");
        }
    }

    #[test]
    fn retries_capacity_errors_rotating_ads_until_success() {
        let launcher = FakeLauncher::new(vec![Err(capacity()), Err(capacity()), Ok(instance())]);
        let mut env = FakeEnv::default();
        let got = run(&launcher, &plan(&["AD-1", "AD-2"]), &mut env).unwrap();

        assert_eq!(got.id, "ocid1.instance.oc1..caught");
        let calls = launcher.calls.borrow();
        let ads: Vec<_> = calls.iter().map(|(ad, _)| ad.as_str()).collect();
        assert_eq!(ads, ["AD-1", "AD-2", "AD-1"]);
        let tokens: Vec<_> = calls.iter().map(|(_, t)| t.as_str()).collect();
        assert_eq!(tokens, ["t1", "t2", "t3"]);
        assert_eq!(env.sleeps, [Duration::from_secs(300); 2]);
    }

    #[test]
    fn network_errors_resend_the_same_request() {
        let launcher = FakeLauncher::new(vec![
            Err(Error::Transport("timed out".into())),
            Ok(instance()),
        ]);
        run(&launcher, &plan(&["AD-1", "AD-2"]), &mut FakeEnv::default()).unwrap();
        let calls = launcher.calls.borrow();
        assert_eq!(calls[0], calls[1], "same AD and same retry token");
    }

    #[test]
    fn stops_on_fatal_errors() {
        let launcher = FakeLauncher::new(vec![
            Err(capacity()),
            Err(api(400, "LimitExceeded", "too many cores")),
        ]);
        let mut env = FakeEnv::default();
        let err = run(&launcher, &plan(&["AD-1"]), &mut env).unwrap_err();
        assert!(err.to_string().contains("LimitExceeded"));
        assert_eq!(env.sleeps.len(), 1);
    }

    #[test]
    fn honours_max_attempts() {
        let launcher = FakeLauncher::new(vec![Err(capacity()), Err(capacity())]);
        let mut p = plan(&["AD-1"]);
        p.max_attempts = Some(2);
        let mut env = FakeEnv::default();
        let err = run(&launcher, &p, &mut env).unwrap_err();
        assert!(matches!(err, Error::Api(_)));
        assert_eq!(launcher.calls.borrow().len(), 2);
        assert_eq!(env.sleeps.len(), 1);
    }

    #[test]
    fn random_tokens_differ() {
        let a = random_token();
        assert_eq!(a.len(), 32);
        assert_ne!(a, random_token());
    }
}
