// Coucou for Windows — app wiring and the commands the island calls.

mod claude;
mod crash;
mod files;
mod hooks;
mod integrations;
mod island;
mod launchers;
mod log;
mod pipe;
mod providers;
mod secrets;
mod security;
mod settings;
mod smoke;
mod tray;
mod updates;
mod win_user;

use std::os::windows::process::CommandExt;
use std::process::Command;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use serde::Serialize;
use tauri::{AppHandle, Emitter, Manager, State, WebviewUrl, WebviewWindowBuilder};
use tauri_plugin_autostart::{MacosLauncher, ManagerExt};

use claude::{Chat, ChatContext, ChatReply};
use files::DroppedFile;
use hooks::{HookPreview, HookStatus};
use island::{PollGate, ScreenInfo};
use pipe::Pending;
use providers::{ModelOption, ProviderInfo};
use settings::Settings;

/// Keeps spawned helpers from flashing a console window.
const CREATE_NO_WINDOW: u32 = 0x0800_0000;

pub struct Shared {
    pub settings: Mutex<Settings>,
    pub gate: Arc<PollGate>,
    /// Set by the island once its JavaScript is running and talking IPC. Only the
    /// smoke test reads it; it costs one relaxed store at boot.
    pub ui_ready: AtomicBool,
    /// Same idea for the Settings webview: set after the first full render.
    pub settings_ready: AtomicBool,
    /// Whether that render included the first-run Welcome card.
    pub welcome_shown: AtomicBool,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BootInfo {
    settings: Settings,
    screen: ScreenInfo,
    version: String,
    hook_path: String,
    smoke: bool,
}

#[tauri::command]
fn boot(app: AppHandle, shared: State<Shared>) -> BootInfo {
    let mut settings = shared.settings.lock().unwrap().clone();
    // The real state of ~/.claude/settings.json wins over whatever we stored.
    settings.hooks_installed = hooks::status().installed;
    let screen = island::screen_info(&app, &settings.screen);
    BootInfo {
        settings,
        screen,
        version: env!("CARGO_PKG_VERSION").to_string(),
        hook_path: settings::hook_exe_path().to_string_lossy().to_string(),
        smoke: smoke::requested(),
    }
}

/// The island's JavaScript reached the backend. The app smoke test waits for
/// this instead of assuming that a visible window means a working webview.
#[tauri::command]
fn ui_ready(shared: State<Shared>) {
    shared.ui_ready.store(true, Ordering::Relaxed);
}

/// The Settings window finished its first render. `welcome` says whether the
/// first-run card was part of it, which the smoke test compares with the
/// `onboarded` preference instead of guessing from a window title.
#[tauri::command]
fn settings_ready(shared: State<Shared>, welcome: bool) {
    shared.welcome_shown.store(welcome, Ordering::Relaxed);
    shared.settings_ready.store(true, Ordering::Relaxed);
}

#[tauri::command]
fn save_settings(app: AppHandle, shared: State<Shared>, settings: Settings) {
    let settings = settings.normalized();
    let (screen_changed, autostart_changed) = {
        let mut current = shared.settings.lock().unwrap();
        let screen_changed = current.screen != settings.screen;
        let autostart_changed = current.autostart != settings.autostart;
        *current = settings.clone();
        (screen_changed, autostart_changed)
    };
    if let Err(err) = settings::save(&settings) {
        eprintln!("[coucou] could not save settings: {err}");
    }
    if autostart_changed {
        let manager = app.autolaunch();
        let result = if settings.autostart {
            manager.enable()
        } else {
            manager.disable()
        };
        if let Err(err) = result {
            eprintln!("[coucou] autostart: {err}");
        }
    }
    if screen_changed {
        let collapsed = shared.gate.collapsed.load(Ordering::Relaxed);
        island::apply_geometry(&app, &settings.screen, collapsed);
    }
    // Keep the other window in step (island ⇄ settings window).
    let _ = app.emit("settings-changed", settings);
}

/// Hidden island → shrink the window to the invisible wake strip and park the
/// cursor poll; anything else → full panel and 60 Hz polling.
#[tauri::command]
fn set_collapsed(app: AppHandle, shared: State<Shared>, collapsed: bool) {
    let pref = shared.settings.lock().unwrap().screen.clone();
    shared.gate.collapsed.store(collapsed, Ordering::Relaxed);
    island::apply_geometry(&app, &pref, collapsed);
    // The wake strip must always take the mouse, and a resize invalidates the flag.
    island::set_ignore_cursor(&app, false);
    shared.gate.forget_ignore_state();
    shared.gate.set_active(!collapsed);
}

/// The front end pushes the island shape; Rust decides click-through from it.
#[tauri::command]
fn set_island_rect(shared: State<Shared>, x: f64, y: f64, width: f64, height: f64) {
    shared.gate.set_rect(island::IslandRect {
        x,
        y,
        w: width,
        h: height,
    });
}

#[tauri::command]
fn focus_window(app: AppHandle, focused: bool) {
    let Some(win) = island::window(&app) else {
        return;
    };
    island::set_activating(&win, focused);
    if focused {
        let _ = win.set_focus();
    }
}

#[tauri::command]
fn reposition(app: AppHandle, shared: State<Shared>) {
    let pref = shared.settings.lock().unwrap().screen.clone();
    let collapsed = shared.gate.collapsed.load(Ordering::Relaxed);
    island::apply_geometry(&app, &pref, collapsed);
}

#[tauri::command]
fn open_url(url: String) {
    if !is_openable_url(&url) {
        return;
    }
    let _ = Command::new("rundll32.exe")
        .args(["url.dll,FileProtocolHandler", &url])
        .creation_flags(CREATE_NO_WINDOW)
        .spawn();
}

/// Only real web URLs reach the shell.
///
/// `rundll32 url.dll,FileProtocolHandler` will happily open `file:`, `javascript:`
/// or a UNC path if it is handed one, and the island can pass a URL coming from
/// an integration payload. Parsing first — and requiring an absolute http(s) URL
/// with a host — keeps this from becoming a generic protocol launcher. The length
/// cap is a cheap guard against pathological input.
fn is_openable_url(input: &str) -> bool {
    if input.len() > 8_192 {
        return false;
    }
    let Ok(url) = url::Url::parse(input) else {
        return false;
    };
    matches!(url.scheme(), "http" | "https") && url.host_str().is_some()
}

/// "Open in editor" on a Claude Code task. The editor comes from Settings and
/// falls back to Explorer when none is installed.
#[tauri::command]
fn open_editor(shared: State<Shared>, path: Option<String>) -> bool {
    let preferred = shared.settings.lock().unwrap().preferred_editor.clone();
    launchers::open_editor(&preferred, path.as_deref())
}

/// "Open terminal" opens the preferred terminal at the session folder.
#[tauri::command]
fn open_terminal(shared: State<Shared>, path: Option<String>) -> bool {
    let preferred = shared.settings.lock().unwrap().preferred_terminal.clone();
    launchers::open_terminal(&preferred, path.as_deref())
}

/// Detected editors and terminals for the settings window.
#[tauri::command]
fn launchers_catalog() -> launchers::LauncherCatalog {
    launchers::catalog()
}

#[tauri::command]
fn quit_app(app: AppHandle) {
    app.exit(0);
}

/// Tray → Pause. Paused means paused: the pollers stop talking to the network,
/// not just the island stopping showing things.
#[tauri::command]
fn set_paused(paused: bool) {
    integrations::set_paused(paused);
}

// ── Claude Code hooks ─────────────────────────────────────────────────────────

#[tauri::command]
fn hooks_status() -> HookStatus {
    hooks::status()
}

/// Returns the diff the user has to look at before anything is written.
#[tauri::command]
fn hooks_preview(install: bool) -> Result<HookPreview, String> {
    hooks::preview(install)
}

/// Only ever called from an explicit click in the settings window.
#[tauri::command]
fn hooks_apply(
    app: AppHandle,
    shared: State<Shared>,
    install: bool,
    fingerprint: String,
) -> Result<String, String> {
    // The fingerprint comes from the preview the user actually looked at, so a
    // settings.json that changed in between is refused rather than overwritten.
    let backup = hooks::write(install, &fingerprint)?;
    security::record(&security::AuditEntry {
        event: "action_succeeded".into(),
        capability: Some("fs.write".into()),
        scope: Some("settings.json".into()),
        target: Some("~/.claude/settings.json".into()),
        decision: "allow".into(),
        rule: "user_action".into(),
        outcome: if install { "installed" } else { "uninstalled" }.into(),
    });
    let updated = {
        let mut current = shared.settings.lock().unwrap();
        current.hooks_installed = install;
        let _ = settings::save(&current);
        current.clone()
    };
    let _ = app.emit("settings-changed", updated);
    Ok(backup)
}

#[tauri::command]
fn approval_decision(app: AppHandle, request_id: String, decision: String) {
    pipe::answer(&app, &request_id, &decision);
}

/// The island has the card on screen, so the long wait for a human may begin.
/// Until this arrives the relay only waits a few hundred milliseconds, which is
/// what stops a paused or unresponsive island from freezing Claude Code.
#[tauri::command]
fn approval_ack(app: AppHandle, request_id: String) {
    pipe::acknowledge(&app, &request_id);
}

/// Nobody can act on this request — the island is paused, or another card is
/// already up. Claude Code falls back to asking in the terminal immediately.
#[tauri::command]
fn approval_decline(app: AppHandle, request_id: String) {
    pipe::decline(&app, &request_id);
}

// ── Chat, files and secrets ───────────────────────────────────────────────────

/// One chat turn. The API key and any file bytes stay on the Rust side.
#[tauri::command]
async fn chat_send(
    shared: State<'_, Shared>,
    chat: State<'_, Chat>,
    query: String,
    context: Option<ChatContext>,
) -> Result<ChatReply, String> {
    let (provider, model, local_endpoint) = {
        let current = shared.settings.lock().unwrap();
        (
            providers::resolve(&current.provider),
            current.model.clone(),
            current.local_endpoint.clone(),
        )
    };
    claude::send(&chat, provider, &model, &local_endpoint, query, context).await
}

/// Provider catalogue for the settings window. Labels and key names only.
#[tauri::command]
fn providers_catalog() -> Vec<ProviderInfo> {
    providers::catalog()
}

/// Live model list with the static catalogue as a fallback. Never returns a key.
#[tauri::command]
async fn provider_models(
    shared: State<'_, Shared>,
    provider: String,
) -> Result<Vec<ModelOption>, String> {
    let selected = providers::resolve(&provider);
    let local_endpoint = shared.settings.lock().unwrap().local_endpoint.clone();
    let key = secrets::get(selected.key_name());
    Ok(providers::list_models(selected, key.as_deref(), &local_endpoint).await)
}

#[tauri::command]
fn chat_reset(chat: State<Chat>) {
    chat.reset();
}

/// Copies a dropped file into the inbox and reports its name back.
#[tauri::command]
fn ingest_file(path: String) -> Result<DroppedFile, String> {
    files::ingest(&path)
}

/// The island may only ask whether a key exists — never read it.
#[tauri::command]
fn secret_present(key: String) -> bool {
    secrets::present(&key)
}

#[tauri::command]
fn secret_set(key: String, value: String) -> Result<(), String> {
    let res = secrets::set(&key, &value);
    if res.is_ok() {
        security::record(&security::AuditEntry {
            event: "action_succeeded".into(),
            capability: Some("security.credential".into()),
            scope: None,
            target: Some(key),
            decision: "allow".into(),
            rule: "user_action".into(),
            outcome: "set".into(),
        });
    }
    res
}

#[tauri::command]
fn secret_clear(key: String) -> Result<(), String> {
    let res = secrets::clear(&key);
    if res.is_ok() {
        security::record(&security::AuditEntry {
            event: "action_succeeded".into(),
            capability: Some("security.credential".into()),
            scope: None,
            target: Some(key),
            decision: "allow".into(),
            rule: "user_action".into(),
            outcome: "cleared".into(),
        });
    }
    res
}

/// Opens the configured n8n instance — the URL lives in the Credential Manager.
#[tauri::command]
fn open_n8n() {
    if let Some(url) = secrets::get("n8n-url") {
        open_url(url);
    }
}

/// Refresh buttons in the integration cards.
#[tauri::command]
async fn refresh_integration(app: AppHandle, id: String) {
    integrations::poll_once(app, &id).await;
}

/// Last poll result per integration, plus why it is not polling.
#[tauri::command]
fn integrations_health(app: AppHandle) -> Vec<integrations::IntegrationHealth> {
    integrations::health(&app)
}

/// Writes a sanitised copy of the log next to the original and returns its path.
#[tauri::command]
fn export_log() -> Result<String, String> {
    log::export()
        .map(|path| path.to_string_lossy().to_string())
        .map_err(|err| format!("Could not export the log: {err}"))
}

/// Local crash reports, newest first. Messages were sanitised when written and
/// are sanitised again when read.
#[tauri::command]
fn crash_reports() -> Vec<crash::CrashReport> {
    crash::reports()
}

#[tauri::command]
fn clear_crash_reports() -> Result<(), String> {
    crash::clear().map_err(|err| err.to_string())
}

#[tauri::command]
fn open_crash_folder() {
    crash::open_folder();
}

/// Opens the folder that holds the log and the exported copy.
#[tauri::command]
fn open_log_folder() {
    let _ = Command::new("explorer").arg(settings::local_dir()).spawn();
}

/// Lets the island write to the same log as the Rust side.
#[tauri::command]
fn log_line(message: String) {
    log::line(format!("ui  {message}"));
}

// ── Updates ───────────────────────────────────────────────────────────────────

/// Asks the signed update manifest for a newer version. `None` means the
/// installed build is current. The manifest only carries a version and notes;
/// the installer itself is verified against the app's minisign key when it is
/// downloaded, and only from an explicit click in Settings.
#[tauri::command]
async fn update_check(app: AppHandle) -> Result<Option<updates::UpdateInfo>, String> {
    updates::check(&app).await
}

/// Downloads, verifies and installs the announced update. On Windows the plugin
/// starts the NSIS installer, exits this process, and the app restarts.
#[tauri::command]
async fn update_install(app: AppHandle) -> Result<(), String> {
    updates::install(app).await
}

// ── Settings window ───────────────────────────────────────────────────────────

/// WebView2 allows exactly one browser environment per app, and its options are
/// fixed by whichever webview is created first. Every window must therefore ask
/// for the *same* arguments as the island (see `additionalBrowserArgs` in
/// tauri.conf.json) — a mismatch makes the second window come up blank, with no
/// error anywhere.
///
/// These are the only two arguments we ship, and neither weakens a Windows
/// protection: `msWebOOUI`/`msPdfOOUI` remove the built-in PDF/download chrome
/// from a frameless window, and the autoplay policy lets the launch greeting
/// play a cue. `msSmartScreenProtection` used to be disabled here; it must never
/// come back, in dev or release.
const BROWSER_ARGS: &str =
    "--disable-features=msWebOOUI,msPdfOOUI --autoplay-policy=no-user-gesture-required";

/// In a dev build the pages are served by Vite, so the second window needs the
/// absolute dev URL; a bundled build resolves it inside the app bundle.
fn settings_page_url(app: &AppHandle) -> WebviewUrl {
    #[cfg(dev)]
    if let Some(mut base) = app.config().build.dev_url.clone() {
        base.set_path("/settings.html");
        return WebviewUrl::External(base);
    }
    let _ = app;
    WebviewUrl::App("settings.html".into())
}

/// The settings window is created hidden at launch and only ever shown and
/// hidden afterwards. A WebView2 window created later — on the main thread or
/// not — silently comes up blank in this app, so the window that works is the
/// one that exists before the island's webview does.
fn create_settings_window(app: &AppHandle) {
    let url = settings_page_url(app);
    match WebviewWindowBuilder::new(app, "settings", url)
        .additional_browser_args(BROWSER_ARGS)
        .title("Settings — Coucou")
        .inner_size(560.0, 680.0)
        .min_inner_size(460.0, 480.0)
        .resizable(true)
        .visible(false)
        .center()
        .build()
    {
        Ok(win) => {
            // Closing it must only hide it, or it could never be reopened.
            let hidden = win.clone();
            win.on_window_event(move |event| {
                if let tauri::WindowEvent::CloseRequested { api, .. } = event {
                    api.prevent_close();
                    let _ = hidden.hide();
                }
            });
        }
        Err(err) => log::line(format!("settings window failed: {err}")),
    }
}

pub fn show_settings_window(app: &AppHandle) {
    let Some(win) = app.get_webview_window("settings") else {
        log::line("settings window missing");
        return;
    };
    let _ = win.unminimize();
    let _ = win.show();
    let _ = win.set_focus();
    // The Settings page runs a quiet update check only when it is opened, never
    // at boot while the window is still hidden.
    let _ = app.emit_to("settings", "settings-opened", ());
}

#[tauri::command]
fn open_settings_window(app: AppHandle) {
    show_settings_window(&app);
}

pub fn run() {
    // Before anything else can panic, so a crash leaves a local report.
    crash::install();
    let loaded = settings::load();
    let gate = Arc::new(PollGate::new());
    let smoke_mode = smoke::requested();

    tauri::Builder::default()
        .plugin(tauri_plugin_single_instance::init(|app, _argv, _cwd| {
            let _ = app.emit_to(island::WINDOW_LABEL, "tray", "open".to_string());
        }))
        .plugin(tauri_plugin_autostart::init(
            MacosLauncher::LaunchAgent,
            None,
        ))
        .plugin(tauri_plugin_updater::Builder::new().build())
        .manage(Shared {
            settings: Mutex::new(loaded.clone()),
            gate: gate.clone(),
            ui_ready: AtomicBool::new(false),
            settings_ready: AtomicBool::new(false),
            welcome_shown: AtomicBool::new(false),
        })
        .manage(Pending::default())
        .manage(Chat::default())
        .invoke_handler(tauri::generate_handler![
            boot,
            ui_ready,
            settings_ready,
            save_settings,
            set_collapsed,
            set_island_rect,
            focus_window,
            reposition,
            open_url,
            open_editor,
            open_terminal,
            launchers_catalog,
            quit_app,
            hooks_status,
            hooks_preview,
            hooks_apply,
            approval_decision,
            approval_ack,
            approval_decline,
            log_line,
            chat_send,
            chat_reset,
            providers_catalog,
            provider_models,
            ingest_file,
            secret_present,
            secret_set,
            secret_clear,
            refresh_integration,
            integrations_health,
            export_log,
            open_log_folder,
            crash_reports,
            clear_crash_reports,
            open_crash_folder,
            open_n8n,
            open_settings_window,
            set_paused,
            update_check,
            update_install,
            security::security_status,
            security::security_set_capability,
            security::security_consent_decide,
            security::security_kill,
            security::security_resume,
            security::audit_recent,
            security::audit_export,
            security::audit_open_folder,
        ])
        .setup(move |app| {
            security::init_killswitch();
            let handle = app.handle().clone();
            tray::build(&handle)?;
            // Before the island: see create_settings_window.
            create_settings_window(&handle);

            if let Some(win) = island::window(&handle) {
                island::make_non_activating(&win);
                island::apply_geometry(&handle, &loaded.screen, false);
                let _ = win.show();
            }
            gate.collapsed.store(false, Ordering::Relaxed);
            gate.set_active(true);
            island::spawn_cursor_poll(handle.clone(), gate.clone());

            log::line(format!(
                "--- Coucou {} started ---",
                env!("CARGO_PKG_VERSION")
            ));
            hooks::ensure_hook_exe(&handle);
            // A fresh install opens Settings once so the welcome card, key and
            // hook install are one click away. It never opens in a smoke run.
            if !smoke_mode && !loaded.onboarded {
                show_settings_window(&handle);
            }
            pipe::start(handle.clone());
            if smoke_mode {
                // No network calls while measuring the shell, and no chance of a
                // smoke run poking an integration the user configured.
                log::line("smoke mode: integration pollers disabled");
            } else {
                integrations::start(handle.clone());
            }
            if smoke_mode {
                smoke::run(handle.clone());
            }
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running Coucou");
}

#[cfg(test)]
mod tests {
    use super::is_openable_url;

    #[test]
    fn only_absolute_http_and_https_urls_are_opened() {
        for url in [
            "https://example.com",
            "http://localhost:3000/path?q=1#frag",
            "https://api.anthropic.com/v1/messages",
        ] {
            assert!(is_openable_url(url), "{url} should be allowed");
        }

        for url in [
            "",
            "example.com",
            "//example.com",
            "file:///C:/Windows/System32/calc.exe",
            "javascript:alert(1)",
            "data:text/html,<script>alert(1)</script>",
            "mailto:someone@example.com",
            "ms-settings:privacy",
            "\\\\server\\share",
            "https://",
            "https://:443",
            "https:// ",
        ] {
            assert!(!is_openable_url(url), "{url} must be refused");
        }
    }

    #[test]
    fn absurdly_long_urls_are_refused() {
        let long = format!("https://example.com/{}", "a".repeat(9_000));
        assert!(!is_openable_url(&long));
    }
}
