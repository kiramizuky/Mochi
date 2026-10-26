// Opt-in runtime smoke test for the parts unit tests cannot reach: a real
// WebView2 island and its monitor geometry, the hidden settings window, the tray
// icon, the named-pipe relay and the inbox.
//
// It runs only when `COUCOU_SMOKE_TEST=1`, writes a JSON report (path from
// `COUCOU_SMOKE_REPORT`) and exits 0/1. `scripts/smoke-app.ps1` owns the
// timeout, the console output and the cleanup.
//
// A smoke run must never change user state: settings are read but not saved,
// Claude Code hooks are not installed, the credential store is untouched and the
// integration pollers are not started (see `lib::run`). The one file it writes
// is a temporary drop that it also deletes.

use std::collections::HashSet;
use std::io::Write;
use std::os::windows::process::CommandExt;
use std::path::PathBuf;
use std::process::{Child, Command, Output, Stdio};
use std::sync::atomic::Ordering;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde::Serialize;
use tauri::{AppHandle, Manager};

use crate::{files, island, log, pipe, settings, Shared};

const CREATE_NO_WINDOW: u32 = 0x0800_0000;

/// Same switch as `windows/scripts/smoke-app.ps1`; exact match, so a stray value
/// in the environment can never turn a normal launch into a self-test.
pub fn requested() -> bool {
    std::env::var("COUCOU_SMOKE_TEST").as_deref() == Ok("1")
}

#[derive(Serialize, Clone)]
struct Check {
    name: &'static str,
    ok: bool,
    detail: String,
}

/// Physical window position and size, as read back from the window manager.
type Geometry = ((i32, i32), (u32, u32));

impl Check {
    fn pass(name: &'static str, detail: impl Into<String>) -> Self {
        Self {
            name,
            ok: true,
            detail: detail.into(),
        }
    }

    fn fail(name: &'static str, detail: impl Into<String>) -> Self {
        Self {
            name,
            ok: false,
            detail: detail.into(),
        }
    }
}

#[derive(Serialize)]
struct Report {
    ok: bool,
    version: &'static str,
    duration_ms: u128,
    finished_at_unix: u64,
    checks: Vec<Check>,
}

/// Start the checks on a worker thread so the Tauri event loop keeps running
/// (the settings window and WebView2 need it).
pub fn run(app: AppHandle) {
    std::thread::spawn(move || {
        let started = Instant::now();
        log::line("smoke test starting");
        let checks = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| checks(&app)))
            .unwrap_or_else(|payload| {
                let message = payload
                    .downcast_ref::<&str>()
                    .map(|s| (*s).to_string())
                    .or_else(|| payload.downcast_ref::<String>().cloned())
                    .unwrap_or_else(|| "unknown panic".into());
                vec![Check::fail(
                    "no_panic",
                    format!("smoke test panicked: {message}"),
                )]
            });
        let ok = checks.iter().all(|c| c.ok);
        let duration_ms = started.elapsed().as_millis();
        write_report(&checks, ok, duration_ms);
        log::line(format!(
            "smoke test {} in {duration_ms} ms",
            if ok { "passed" } else { "failed" }
        ));
        app.exit(if ok { 0 } else { 1 });
        // `exit` posts to the event loop; give it a moment, then make sure a
        // broken loop can never leave CI hanging.
        std::thread::sleep(Duration::from_secs(5));
        std::process::exit(if ok { 0 } else { 1 });
    });
}

fn checks(app: &AppHandle) -> Vec<Check> {
    vec![
        island_window(app),
        island_geometry(app),
        frontend_ready(app),
        settings_window(app),
        settings_frontend(app),
        tray_icon(app),
        hook_copy(),
        relay_round_trip(app),
        file_drop(),
    ]
}

fn island_window(app: &AppHandle) -> Check {
    let Some(win) = app.get_webview_window("island") else {
        return Check::fail("island_window", "the island window was not created");
    };
    match (win.is_visible(), win.inner_size()) {
        (Ok(true), Ok(size)) if size.width > 0 && size.height > 0 => Check::pass(
            "island_window",
            format!("visible at {}x{}", size.width, size.height),
        ),
        (Ok(visible), Ok(size)) => Check::fail(
            "island_window",
            format!("visible={visible}, size={}x{}", size.width, size.height),
        ),
        (Err(err), _) => Check::fail("island_window", format!("cannot read the window: {err}")),
        (_, Err(err)) => Check::fail("island_window", format!("cannot read the size: {err}")),
    }
}

/// A visible window proves little; this waits for `ui_ready`, which the island
/// only sends after its JavaScript booted and the IPC bridge works.
fn frontend_ready(app: &AppHandle) -> Check {
    let ready = wait_until(Duration::from_secs(20), || {
        app.state::<Shared>().ui_ready.load(Ordering::Relaxed)
    });
    if ready {
        Check::pass(
            "frontend_ready",
            "island JavaScript booted and called ui_ready",
        )
    } else {
        Check::fail(
            "frontend_ready",
            "island JavaScript never called ui_ready within 20 s",
        )
    }
}

fn settings_window(app: &AppHandle) -> Check {
    let Some(win) = app.get_webview_window("settings") else {
        return Check::fail("settings_window", "the settings window was not created");
    };
    // Show it the way the tray does, but without stealing focus from whatever
    // the developer is doing.
    if let Err(err) = win.show() {
        return Check::fail("settings_window", format!("cannot show it: {err}"));
    }
    let shown = wait_until(Duration::from_secs(3), || win.is_visible().unwrap_or(false));
    let _ = win.hide();
    if shown {
        Check::pass("settings_window", "opened and hidden again")
    } else {
        Check::fail("settings_window", "did not become visible within 3 s")
    }
}

/// A window that exists is not a page that rendered. The script starts the app
/// with a clean %APPDATA%, so this also proves the first-run Welcome card is
/// built from defaults instead of relying on whatever the developer has saved.
fn settings_frontend(app: &AppHandle) -> Check {
    let Some(win) = app.get_webview_window("settings") else {
        return Check::fail("settings_frontend", "the settings window was not created");
    };
    let _ = win.show();
    let shared = app.state::<Shared>();
    let ready = wait_until(Duration::from_secs(20), || {
        shared.settings_ready.load(Ordering::Relaxed)
    });
    let _ = win.hide();
    if !ready {
        return Check::fail(
            "settings_frontend",
            "Settings JavaScript never called settings_ready within 20 s",
        );
    }

    let onboarded = shared.settings.lock().unwrap().onboarded;
    let welcome = shared.welcome_shown.load(Ordering::Relaxed);
    if welcome == !onboarded {
        Check::pass(
            "settings_frontend",
            if welcome {
                "rendered; first-run Welcome card shown"
            } else {
                "rendered; profile already onboarded, no Welcome card"
            },
        )
    } else {
        Check::fail(
            "settings_frontend",
            format!("Welcome card shown={welcome}, but onboarded={onboarded}"),
        )
    }
}

/// The island must sit at the top centre of its monitor, at the panel size and
/// again at the wake-strip size, with always-on-top still set. Unit tests cover
/// the arithmetic; this covers the real monitor's DPI and origin plus the window
/// manager actually accepting both resizes.
fn island_geometry(app: &AppHandle) -> Check {
    let Some(win) = app.get_webview_window("island") else {
        return Check::fail("island_geometry", "the island window was not created");
    };
    let shared = app.state::<Shared>();
    let pref = shared.settings.lock().unwrap().screen.clone();
    let Some(monitor) = island::target_monitor(app, &pref) else {
        return Check::fail("island_geometry", "no monitor was reported");
    };
    let mp = *monitor.position();
    let ms = *monitor.size();
    let scale = monitor.scale_factor();
    let panel = island::placement((mp.x, mp.y), (ms.width, ms.height), scale, false);
    let strip = island::placement((mp.x, mp.y), (ms.width, ms.height), scale, true);

    let read = || -> Result<Geometry, String> {
        let pos = win
            .outer_position()
            .map_err(|e| format!("cannot read the position: {e}"))?;
        let size = win
            .inner_size()
            .map_err(|e| format!("cannot read the size: {e}"))?;
        Ok(((pos.x, pos.y), (size.width, size.height)))
    };
    // One pixel of slack: Win32 rounds physical sizes and positions.
    let fits = |want: island::Placement, got: Geometry| {
        let ((x, y), (w, h)) = got;
        (x - want.x).abs() <= 1
            && (y - want.y).abs() <= 1
            && (w as i64 - want.width as i64).abs() <= 1
            && (h as i64 - want.height as i64).abs() <= 1
    };
    let describe = |p: island::Placement| format!("{}x{} at {},{}", p.width, p.height, p.x, p.y);

    let ((px, py), (pw, ph)) = match read() {
        Ok(got) => got,
        Err(err) => return Check::fail("island_geometry", err),
    };
    if !fits(panel, ((px, py), (pw, ph))) {
        return Check::fail(
            "island_geometry",
            format!(
                "panel is {pw}x{ph} at {px},{py}; expected {} on a {}x{} monitor at {scale}x",
                describe(panel),
                ms.width,
                ms.height
            ),
        );
    }

    // Resize to the wake strip and back. Both states are used in real life, and
    // the restore proves the geometry survives a collapse/expand cycle.
    island::apply_geometry(app, &pref, true);
    let strip_ok = wait_until(Duration::from_secs(2), || {
        read().map(|got| fits(strip, got)).unwrap_or(false)
    });
    let strip_got = read().unwrap_or(((0, 0), (0, 0)));
    island::apply_geometry(app, &pref, false);
    let restore_ok = wait_until(Duration::from_secs(2), || {
        read().map(|got| fits(panel, got)).unwrap_or(false)
    });
    let always_on_top = win.is_always_on_top().unwrap_or(false);

    if !strip_ok {
        let ((sx, sy), (sw, sh)) = strip_got;
        return Check::fail(
            "island_geometry",
            format!(
                "wake strip is {sw}x{sh} at {sx},{sy}; expected {}",
                describe(strip)
            ),
        );
    }
    if !restore_ok {
        return Check::fail(
            "island_geometry",
            "the panel geometry did not come back after the wake-strip resize",
        );
    }
    if !always_on_top {
        return Check::fail("island_geometry", "the island is not always on top");
    }

    Check::pass(
        "island_geometry",
        format!(
            "panel {} and strip {} on a {}x{} monitor at {scale}x, always on top",
            describe(panel),
            describe(strip),
            ms.width,
            ms.height
        ),
    )
}

fn tray_icon(app: &AppHandle) -> Check {
    if app.tray_by_id("mochi").is_some() || app.tray_by_id("coucou").is_some() {
        Check::pass("tray_icon", "notification-area icon registered")
    } else {
        Check::fail("tray_icon", "no tray icon with id \"mochi\"")
    }
}

fn hook_copy() -> Check {
    let path = settings::hook_exe_path();
    if path.is_file() {
        let size = std::fs::metadata(&path).map(|m| m.len()).unwrap_or(0);
        Check::pass("hook_copy", format!("{} ({size} bytes)", path.display()))
    } else {
        Check::fail(
            "hook_copy",
            format!("coucou-hook.exe was not staged at {}", path.display()),
        )
    }
}

/// Spawns the real relay, lets it wait on the real pipe, answers like the island
/// would, and checks the JSON Claude Code would receive.
fn relay_round_trip(app: &AppHandle) -> Check {
    let hook = settings::hook_exe_path();
    if !hook.is_file() {
        return Check::fail("relay_round_trip", "the relay executable is missing");
    }

    let before: HashSet<String> = pending_ids(app).into_iter().collect();
    let spawned = Instant::now();
    let mut child = match Command::new(&hook)
        .arg("PermissionRequest")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .creation_flags(CREATE_NO_WINDOW)
        .spawn()
    {
        Ok(child) => child,
        Err(err) => {
            return Check::fail("relay_round_trip", format!("cannot start {hook:?}: {err}"))
        }
    };

    let payload = serde_json::json!({
        "hook_event_name": "PermissionRequest",
        "session_id": "coucou-smoke",
        "cwd": std::env::temp_dir(),
        "tool_name": "Bash",
        "tool_input": { "command": "echo smoke" }
    });
    if let Some(mut stdin) = child.stdin.take() {
        let _ = stdin.write_all(payload.to_string().as_bytes());
        let _ = stdin.write_all(b"\n");
        // Dropping stdin closes the pipe, exactly as Claude Code does.
    }

    let Some(id) = wait_for_new_request(app, &before, Duration::from_secs(5)) else {
        let _ = child.kill();
        let _ = child.wait();
        return Check::fail(
            "relay_round_trip",
            "the relay never produced a permission request",
        );
    };
    let found_after = spawned.elapsed().as_millis();

    pipe::acknowledge(app, &id);
    pipe::answer(app, &id, "allow");

    let output = match wait_child(child, Duration::from_secs(10)) {
        Ok(output) => output,
        Err(err) => return Check::fail("relay_round_trip", err),
    };
    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    if !output.status.success() {
        return Check::fail(
            "relay_round_trip",
            format!("relay exited {:?}: {}", output.status.code(), stderr.trim()),
        );
    }
    if !stdout.contains(r#""behavior":"allow""#) {
        return Check::fail(
            "relay_round_trip",
            format!("relay did not return allow; stdout={:?}", stdout.trim()),
        );
    }
    Check::pass(
        "relay_round_trip",
        format!("request {id} found after {found_after} ms, acknowledged and allowed end to end"),
    )
}

/// Copies a file with Unicode in its name the way the drag-and-drop handler does,
/// checks the copy, and removes both sides again.
fn file_drop() -> Check {
    let dir = std::env::temp_dir().join(format!("coucou-smoke-{}", std::process::id()));
    if let Err(err) = std::fs::create_dir_all(&dir) {
        return Check::fail(
            "file_drop",
            format!("cannot create {}: {err}", dir.display()),
        );
    }
    let src = dir.join("smoke-ü-测试.txt");
    let content = b"coucou smoke\n";
    if let Err(err) = std::fs::write(&src, content) {
        let _ = std::fs::remove_dir_all(&dir);
        return Check::fail(
            "file_drop",
            format!("cannot write {}: {err}", src.display()),
        );
    }

    let result = files::ingest(&src.to_string_lossy());
    let outcome = match result {
        Ok(dropped) => {
            let copy = PathBuf::from(&dropped.path);
            let copied = std::fs::read(&copy).unwrap_or_default();
            let result = if dropped.size as usize != content.len() || copied != content {
                Err(format!(
                    "copy at {} does not match the source ({} bytes)",
                    copy.display(),
                    dropped.size
                ))
            } else {
                Ok(format!("{} copied to the inbox", dropped.name))
            };
            // Leave the inbox as we found it.
            let _ = std::fs::remove_file(&copy);
            result
        }
        Err(err) => Err(err),
    };
    let _ = std::fs::remove_dir_all(&dir);

    match outcome {
        Ok(detail) => Check::pass("file_drop", detail),
        Err(err) => Check::fail("file_drop", err),
    }
}

fn pending_ids(app: &AppHandle) -> Vec<String> {
    app.state::<pipe::Pending>()
        .0
        .lock()
        .unwrap()
        .keys()
        .cloned()
        .collect()
}

fn wait_for_new_request(
    app: &AppHandle,
    before: &HashSet<String>,
    timeout: Duration,
) -> Option<String> {
    let deadline = Instant::now() + timeout;
    loop {
        if let Some(id) = pending_ids(app).into_iter().find(|id| !before.contains(id)) {
            return Some(id);
        }
        if Instant::now() >= deadline {
            return None;
        }
        std::thread::sleep(Duration::from_millis(25));
    }
}

fn wait_child(mut child: Child, timeout: Duration) -> Result<Output, String> {
    let deadline = Instant::now() + timeout;
    loop {
        match child.try_wait() {
            Ok(Some(_)) => {
                return child
                    .wait_with_output()
                    .map_err(|e| format!("cannot read the relay output: {e}"))
            }
            Ok(None) if Instant::now() >= deadline => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(format!(
                    "the relay did not exit within {} s",
                    timeout.as_secs()
                ));
            }
            Ok(None) => std::thread::sleep(Duration::from_millis(25)),
            Err(err) => return Err(format!("cannot wait for the relay: {err}")),
        }
    }
}

fn wait_until(timeout: Duration, mut condition: impl FnMut() -> bool) -> bool {
    let deadline = Instant::now() + timeout;
    loop {
        if condition() {
            return true;
        }
        if Instant::now() >= deadline {
            return false;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
}

fn write_report(checks: &[Check], ok: bool, duration_ms: u128) {
    let path = std::env::var_os("COUCOU_SMOKE_REPORT")
        .map(PathBuf::from)
        .unwrap_or_else(|| settings::local_dir().join("smoke-report.json"));
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    let finished_at_unix = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let report = Report {
        ok,
        version: env!("CARGO_PKG_VERSION"),
        duration_ms,
        finished_at_unix,
        checks: checks.to_vec(),
    };
    match serde_json::to_vec_pretty(&report) {
        Ok(bytes) => {
            if let Err(err) = std::fs::write(&path, bytes) {
                log::line(format!(
                    "smoke report not written to {}: {err}",
                    path.display()
                ));
            }
        }
        Err(err) => log::line(format!("smoke report cannot be serialised: {err}")),
    }
}
