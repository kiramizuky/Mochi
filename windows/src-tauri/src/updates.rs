// Windows auto-update over Tauri's signed update manifest, which lives next to
// the GitHub Release. The installer is verified against Coucou's minisign public
// key before it is ever run; installing is always an explicit click in Settings.
//
// The manifest endpoint is fixed in tauri.conf.json. Only a development build
// may override it with COUCOU_UPDATER_ENDPOINT (for a local feed), so a stray
// environment variable can never redirect a shipped app.

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::Duration;

use serde::Serialize;
use tauri::{AppHandle, Emitter};
use tauri_plugin_updater::UpdaterExt;

use crate::log;

const SETTINGS_WINDOW: &str = "settings";
const CHECK_TIMEOUT: Duration = Duration::from_secs(20);
const INSTALL_TIMEOUT: Duration = Duration::from_secs(600);
/// Release notes are rendered as text. Cap them so a broken or hostile feed
/// cannot make the Settings window build an enormous DOM node.
const MAX_NOTES_CHARS: usize = 4000;

#[derive(Serialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct UpdateInfo {
    pub current_version: String,
    pub version: String,
    pub date: Option<String>,
    pub body: Option<String>,
}

#[derive(Serialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct UpdateProgress {
    pub downloaded: u64,
    pub total: Option<u64>,
}

/// `None` means the installed version is current.
pub async fn check(app: &AppHandle) -> Result<Option<UpdateInfo>, String> {
    let updater = build(app, CHECK_TIMEOUT)?;
    let update = updater.check().await.map_err(error)?;
    Ok(update.map(|update| UpdateInfo {
        current_version: update.current_version,
        version: update.version,
        date: update.date.map(|date| date.to_string()),
        body: update
            .body
            .map(|body| body.chars().take(MAX_NOTES_CHARS).collect()),
    }))
}

/// Downloads, verifies and installs. On Windows the updater plugin launches the
/// NSIS installer and exits this process, which then restarts the app.
pub async fn install(app: AppHandle) -> Result<(), String> {
    let updater = build(&app, INSTALL_TIMEOUT)?;
    let Some(update) = updater.check().await.map_err(error)? else {
        return Err("Mochi is already up to date.".into());
    };
    let version = update.version.clone();
    log::line(format!("updating to {version}"));

    let handle = app.clone();
    let downloaded = Arc::new(AtomicU64::new(0));
    let counter = Arc::clone(&downloaded);
    update
        .download_and_install(
            move |chunk, total| {
                let done = counter.fetch_add(chunk as u64, Ordering::Relaxed) + chunk as u64;
                let _ = handle.emit_to(
                    SETTINGS_WINDOW,
                    "update-progress",
                    UpdateProgress {
                        downloaded: done,
                        total,
                    },
                );
            },
            || {},
        )
        .await
        .map_err(|err| {
            let text = error(err);
            log::line(format!("update failed: {text}"));
            text
        })?;

    // Unreachable on Windows after a successful install, because the plugin
    // exits the process so the installer can replace the running files.
    log::line(format!("update {version} installed"));
    Ok(())
}

fn build(app: &AppHandle, timeout: Duration) -> Result<tauri_plugin_updater::Updater, String> {
    let mut builder = app.updater_builder();
    if let Some(endpoint) = test_endpoint() {
        let url = url::Url::parse(&endpoint).map_err(|err| format!("updater endpoint: {err}"))?;
        builder = builder
            .endpoints(vec![url])
            .map_err(|err| format!("updater endpoint: {err}"))?;
    }
    builder
        .timeout(timeout)
        .build()
        .map_err(|err| format!("updater setup: {err}"))
}

fn error(err: impl std::fmt::Display) -> String {
    log::sanitize(&err.to_string())
}

/// A local feed is only honoured by debug builds. HTTP is accepted solely for
/// loopback, which is what the local-feed test uses; HTTPS is accepted anywhere.
fn allowed_endpoint(raw: &str) -> Option<String> {
    let url = url::Url::parse(raw).ok()?;
    let loopback = matches!(url.host_str(), Some("localhost" | "127.0.0.1" | "::1"));
    match url.scheme() {
        "https" => Some(raw.to_string()),
        "http" if loopback => Some(raw.to_string()),
        _ => None,
    }
}

fn test_endpoint() -> Option<String> {
    if !cfg!(debug_assertions) {
        return None;
    }
    std::env::var("COUCOU_UPDATER_ENDPOINT")
        .ok()
        .and_then(|raw| allowed_endpoint(&raw))
}

#[cfg(test)]
mod tests {
    use super::allowed_endpoint;

    #[test]
    fn https_endpoints_are_accepted() {
        assert_eq!(
            allowed_endpoint(
                "https://github.com/kiramizuky/Mochi/releases/latest/download/latest.json"
            )
            .as_deref(),
            Some("https://github.com/kiramizuky/Mochi/releases/latest/download/latest.json")
        );
    }

    #[test]
    fn loopback_http_is_accepted_for_the_local_feed() {
        for raw in [
            "http://127.0.0.1:8787/latest.json",
            "http://localhost:8787/latest.json",
        ] {
            assert_eq!(allowed_endpoint(raw).as_deref(), Some(raw));
        }
    }

    #[test]
    fn remote_http_and_other_schemes_are_refused() {
        for raw in [
            "http://example.com/latest.json",
            "file:///C:/Windows/System32/calc.exe",
            "javascript:alert(1)",
            "not a url",
        ] {
            assert_eq!(allowed_endpoint(raw), None, "{raw} must be refused");
        }
    }
}
