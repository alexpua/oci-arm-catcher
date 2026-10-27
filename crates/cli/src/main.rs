//! `oci-arm-catcher` — grab Oracle Cloud's free ARM capacity the moment it appears.

mod args;
mod exit;
mod run;
mod settings;
mod ui;

use std::process::ExitCode;

use clap::Parser as _;

use crate::args::Args;

fn main() -> ExitCode {
    // clap exits with code 2 by itself on a parse error, matching our usage code.
    let args = Args::parse();

    match run::run(&args) {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            ui::report_error(&error);
            ExitCode::from(exit::code_for(&error))
        }
    }
}
