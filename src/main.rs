pub mod bootloader_env;
pub mod system;
pub mod systemd;
pub mod twin;
pub mod update_validation;
pub mod web_service;

use azure_iot_sdk::client::*;
use env_logger::{Builder, Env, Target};
use log::{error, info};
use std::io::Write;
use std::process;
use twin::Twin;

#[tokio::main]
async fn main() {
    log_panics::init();

    let mut builder = if cfg!(debug_assertions) {
        Builder::from_env(Env::default().default_filter_or(
            "trace, \
            actix_server=error, \
            azure_iot_sdk=info, \
            eis_utils=info, \
            hyper=error, \
            hyper_util=error, \
            mio=error, \
            notify=error, \
            reqwest=error, \
            tracing=error",
        ))
    } else {
        Builder::from_env(Env::default().default_filter_or("info"))
    };

    builder.format(|buf, record| match record.level() {
        log::Level::Info => writeln!(buf, "<6>{}: {}", record.target(), record.args()),
        log::Level::Warn => writeln!(buf, "<4>{}: {}", record.target(), record.args()),
        log::Level::Error => {
            eprintln!("<3>{}: {}", record.target(), record.args());
            Ok(())
        }
        _ => writeln!(buf, "<7>{}: {}", record.target(), record.args()),
    });

    builder.target(Target::Stdout).init();

    info!(
        "module version: {} ({})",
        env!("CARGO_PKG_VERSION"),
        env!("GIT_SHORT_REV")
    );
    info!("azure sdk version: {}", IotHubClient::sdk_version_string());

    #[cfg(not(feature = "mock"))]
    if let Err(e) = system::infos() {
        error!("application error: {e:#}");
    }

    if let Err(e) = Twin::run().await {
        error!("application error: {e:#}");

        process::exit(1);
    }

    info!("application shutdown")
}
