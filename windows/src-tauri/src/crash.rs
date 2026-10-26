// Local crash reports, the Windows equivalent of CrashReporter.swift.
//
// A panic is written to %LOCALAPPDATA%\Coucou\crashes\reports.json (newest
// first, at most 50). Nothing is uploaded: the only network requests the app
// makes are the ones the user configures. Every field is passed through the log
// sanitiser before it is stored, so a panic message containing a token cannot
// turn the report into a secret stash.

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};

use serde::{Deserialize, Serialize};
use windows::Win32::System::SystemInformation::GetLocalTime;

use crate::{log, settings};

const MAX_REPORTS: usize = 50;
const REPORTS_FILE: &str = "reports.json";

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CrashReport {
    pub timestamp: String,
    pub message: String,
    pub location: String,
    pub thread: String,
    pub app_version: String,
}

impl CrashReport {
    fn sanitise(&mut self) {
        self.timestamp = log::sanitize(&self.timestamp);
        self.message = log::sanitize(&self.message);
        self.location = log::sanitize(&self.location);
        self.thread = log::sanitize(&self.thread);
        self.app_version = log::sanitize(&self.app_version);
    }
}

/// Installs the panic hook. Called once, before the Tauri event loop starts.
pub fn install() {
    let previous = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |info| {
        record(info);
        // Keep the default stderr message for developers and CI logs.
        previous(info);
    }));
}

/// %LOCALAPPDATA%\Coucou\crashes - next to the log, so one folder explains
/// everything the app wrote locally.
pub fn dir() -> PathBuf {
    settings::local_dir().join("crashes")
}

pub fn reports() -> Vec<CrashReport> {
    read_reports(&dir())
}

pub fn clear() -> std::io::Result<()> {
    clear_in(&dir())
}

pub fn open_folder() {
    let dir = dir();
    let _ = std::fs::create_dir_all(&dir);
    let _ = std::process::Command::new("explorer").arg(&dir).spawn();
}

fn record(info: &std::panic::PanicHookInfo<'_>) {
    // A panic while writing a report must not recurse forever. Losing that one
    // report is better than freezing the process that is already in trouble.
    static RECORDING: AtomicBool = AtomicBool::new(false);
    if RECORDING.swap(true, Ordering::SeqCst) {
        return;
    }

    let report = CrashReport {
        timestamp: timestamp(),
        message: payload_message(info.payload()),
        location: info
            .location()
            .map(|l| format!("{}:{}:{}", l.file(), l.line(), l.column()))
            .unwrap_or_else(|| "unknown location".to_string()),
        thread: std::thread::current()
            .name()
            .unwrap_or("unnamed thread")
            .to_string(),
        app_version: env!("CARGO_PKG_VERSION").to_string(),
    };
    append(&dir(), report.clone());
    // Also leave a one-line marker in the normal log so an existing export
    // includes the crash without opening the JSON file.
    log::line(format!("panic: {}", report.message));
    RECORDING.store(false, Ordering::SeqCst);
}

fn append(dir: &Path, mut report: CrashReport) {
    if std::fs::create_dir_all(dir).is_err() {
        return;
    }
    report.sanitise();
    let mut list = read_reports(dir);
    list.insert(0, report);
    list.truncate(MAX_REPORTS);

    let Ok(bytes) = serde_json::to_vec_pretty(&list) else {
        return;
    };
    let target = dir.join(REPORTS_FILE);
    let temporary = dir.join(format!("{REPORTS_FILE}.tmp"));
    if std::fs::write(&temporary, &bytes).is_ok() && std::fs::rename(&temporary, &target).is_err() {
        // Never leave the only copy in a .tmp file.
        let _ = std::fs::write(&target, &bytes);
        let _ = std::fs::remove_file(&temporary);
    }
}

fn read_reports(dir: &Path) -> Vec<CrashReport> {
    let Ok(bytes) = std::fs::read(dir.join(REPORTS_FILE)) else {
        return Vec::new();
    };
    let Ok(mut list) = serde_json::from_slice::<Vec<CrashReport>>(&bytes) else {
        return Vec::new();
    };
    list.truncate(MAX_REPORTS);
    // A file edited by hand (or written by an older build) is still sanitised
    // before it reaches Settings.
    for report in &mut list {
        report.sanitise();
    }
    list
}

fn clear_in(dir: &Path) -> std::io::Result<()> {
    match std::fs::remove_dir_all(dir) {
        Ok(()) => Ok(()),
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(err) => Err(err),
    }
}

fn payload_message(payload: &(dyn std::any::Any + Send)) -> String {
    payload
        .downcast_ref::<&str>()
        .map(|s| (*s).to_string())
        .or_else(|| payload.downcast_ref::<String>().cloned())
        .unwrap_or_else(|| "panic with a non-string payload".to_string())
}

fn timestamp() -> String {
    let t = unsafe { GetLocalTime() };
    format!(
        "{:04}-{:02}-{:02} {:02}:{:02}:{:02}",
        t.wYear, t.wMonth, t.wDay, t.wHour, t.wMinute, t.wSecond
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_dir(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("coucou-crash-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        dir
    }

    fn sample(index: usize) -> CrashReport {
        CrashReport {
            timestamp: format!("2026-10-26 12:00:{index:02}"),
            message: format!("panic {index} sk-ant-secret-{index}"),
            location: "src/main.rs:10:3".to_string(),
            thread: "main".to_string(),
            app_version: "0.1.1".to_string(),
        }
    }

    #[test]
    fn reports_are_sanitised_capped_and_newest_first() {
        let dir = temp_dir("cap");
        for index in 0..(MAX_REPORTS + 5) {
            append(&dir, sample(index));
        }

        let list = read_reports(&dir);
        assert_eq!(list.len(), MAX_REPORTS);
        assert!(list[0].message.contains(&(MAX_REPORTS + 4).to_string()));
        assert!(list[MAX_REPORTS - 1]
            .message
            .contains(&(MAX_REPORTS + 5 - MAX_REPORTS).to_string()));
        assert!(
            list.iter().all(|r| !r.message.contains("secret")),
            "a panic message leaked a token"
        );
        assert!(list.iter().all(|r| r.message.contains("[redacted]")));

        clear_in(&dir).unwrap();
    }

    #[test]
    fn a_corrupt_file_is_replaced_instead_of_crashing() {
        let dir = temp_dir("corrupt");
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join(REPORTS_FILE), b"not json").unwrap();

        append(&dir, sample(1));

        let list = read_reports(&dir);
        assert_eq!(list.len(), 1);
        assert!(list[0].message.contains("panic 1"));
        clear_in(&dir).unwrap();
    }

    #[test]
    fn clearing_is_idempotent() {
        let dir = temp_dir("clear");
        append(&dir, sample(1));
        assert_eq!(read_reports(&dir).len(), 1);
        clear_in(&dir).unwrap();
        clear_in(&dir).unwrap();
        assert!(!dir.exists());
    }

    #[test]
    fn the_saved_shape_is_camel_case_and_has_no_secret_field() {
        let dir = temp_dir("shape");
        append(&dir, sample(7));
        let json = std::fs::read_to_string(dir.join(REPORTS_FILE)).unwrap();

        for key in ["timestamp", "message", "location", "thread", "appVersion"] {
            assert!(json.contains(key), "{key} missing from {json}");
        }
        assert!(!json.contains("apiKey") && !json.contains("token"));
        clear_in(&dir).unwrap();
    }
}
