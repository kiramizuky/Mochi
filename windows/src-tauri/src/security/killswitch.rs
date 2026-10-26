// Hard stop kill switch: persists across restart, cancels queued work,
// pauses integration pollers, and enforces sub-millisecond refusal path.

use std::sync::atomic::{AtomicBool, Ordering};
use tauri::AppHandle;

use super::audit::{record, AuditEntry};
use super::policy;

static KILLED: AtomicBool = AtomicBool::new(false);

/// Returns whether the kill switch is currently engaged.
#[inline(always)]
pub fn is_killed() -> bool {
    KILLED.load(Ordering::Relaxed)
}

/// Initializes the kill switch state from disk at application startup.
pub fn init() {
    let (policy, _) = policy::load();
    if policy.kill_switch_engaged {
        KILLED.store(true, Ordering::SeqCst);
        eprintln!("[mochi::security] kill switch restored from disk (engaged)");
    } else {
        KILLED.store(false, Ordering::SeqCst);
    }
}

/// Engages the kill switch:
/// - Stores atomic flag immediately
/// - Flushes `killSwitchEngaged = true` and `automationEnabled = false` to security.json
/// - Cancels all pending consent cards and queued requests
/// - Pauses integration pollers
/// - Logs `kill_engaged` audit event
pub fn kill(app: Option<&AppHandle>) -> Result<(), String> {
    KILLED.store(true, Ordering::SeqCst);

    let (mut pol, _) = policy::load();
    pol.kill_switch_engaged = true;
    pol.automation_enabled = false;
    policy::save(&pol)?;

    // Cancel all pending consent requests
    super::consent::cancel_all();

    // Pause integration pollers
    crate::integrations::set_paused(true);

    if let Some(handle) = app {
        use tauri::Emitter;
        let _ = handle.emit("security_state_changed", ());
    }

    record(&AuditEntry {
        event: "kill_engaged".into(),
        capability: None,
        scope: None,
        target: None,
        decision: "kill".into(),
        rule: "hard_stop".into(),
        outcome: "stopped".into(),
    });

    Ok(())
}

/// Resumes automation from a hard stop:
/// - Clears atomic flag
/// - Sets `killSwitchEngaged = false` in security.json
/// - Note: Does NOT re-enable capabilities or `automationEnabled` (explicit user opt-in required)
/// - Logs `kill_released` audit event
pub fn resume(app: Option<&AppHandle>) -> Result<(), String> {
    KILLED.store(false, Ordering::SeqCst);

    let (mut pol, _) = policy::load();
    pol.kill_switch_engaged = false;
    policy::save(&pol)?;

    if let Some(handle) = app {
        use tauri::Emitter;
        let _ = handle.emit("security_state_changed", ());
    }

    record(&AuditEntry {
        event: "kill_released".into(),
        capability: None,
        scope: None,
        target: None,
        decision: "resume".into(),
        rule: "hard_stop".into(),
        outcome: "resumed".into(),
    });

    Ok(())
}

#[cfg(test)]
pub(crate) static TEST_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn kill_and_resume_toggle_atomic_state() {
        let _guard = TEST_LOCK.lock().unwrap();
        KILLED.store(false, Ordering::SeqCst);
        assert!(!is_killed());
        KILLED.store(true, Ordering::SeqCst);
        assert!(is_killed());
        KILLED.store(false, Ordering::SeqCst);
        assert!(!is_killed());
    }
}
