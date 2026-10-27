//! Terminal output and desktop notifications.

use std::io::{IsTerminal as _, Write as _};
use std::time::{Duration, Instant};

use oci_arm_catcher_core::{Environment, Event, RetryReason, catcher};

/// Prints progress, counts down between attempts, and notifies on the way out.
pub struct Console {
    started: Instant,
    interactive: bool,
}

impl Console {
    pub fn new() -> Self {
        Self {
            started: Instant::now(),
            interactive: std::io::stdout().is_terminal(),
        }
    }

    /// `[+hh:mm:ss]` since start: on a multi-day hunt, more useful than wall-clock time.
    fn stamp(&self) -> String {
        let s = self.started.elapsed().as_secs();
        format!("[+{:02}:{:02}:{:02}]", s / 3600, s / 60 % 60, s % 60)
    }
}

impl Environment for Console {
    fn event(&mut self, event: Event<'_>) {
        match event {
            Event::Attempt {
                number,
                availability_domain,
            } => println!(
                "{} Attempt #{number}  ({availability_domain})",
                self.stamp()
            ),
            Event::Retrying { error, reason, .. } => {
                let label = match reason {
                    RetryReason::OutOfCapacity => "no capacity yet",
                    RetryReason::Throttled => "throttled",
                    RetryReason::ServerError => "OCI server error",
                    RetryReason::Network => "network error, resending the same request",
                };
                println!("  -> {error}  [{label}]");
            }
        }
    }

    fn sleep(&mut self, duration: Duration) {
        if !self.interactive {
            std::thread::sleep(duration);
            return;
        }
        let end = Instant::now() + duration;
        let mut out = std::io::stdout();
        while let Some(left) = end.checked_duration_since(Instant::now()) {
            let s = left.as_secs();
            let _ = write!(out, "\r  next attempt in {:02}:{:02} ", s / 60, s % 60);
            let _ = out.flush();
            std::thread::sleep(left.min(Duration::from_secs(1)));
        }
        let _ = write!(out, "\r\x1b[K");
        let _ = out.flush();
    }

    fn new_token(&mut self) -> String {
        catcher::random_token()
    }
}

/// Best-effort desktop notification; the terminal output is the record.
pub fn notify(message: &str) {
    let _ = notify_rust::Notification::new()
        .summary("oci-arm-catcher")
        .body(message)
        .show();
}

/// Print an error and its causes to stderr.
pub fn report_error(error: &anyhow::Error) {
    eprintln!("error: {error}");
    for cause in error.chain().skip(1) {
        eprintln!("  caused by: {cause}");
    }
}
