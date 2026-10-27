// Security subsystem: policy engine, authorization gate, consent flow,
// local tamper-evident audit log, and hard stop kill switch.

pub mod audit;
pub mod consent;
pub mod gate;
pub mod killswitch;
pub mod policy;

#[allow(unused_imports)]
pub use audit::{export_sanitized, recent, record, AuditEntry};
#[allow(unused_imports)]
pub use consent::{decide, Decision, PendingConsent};
#[allow(unused_imports)]
pub use gate::{authorize, ActionGrant, ActionRequest, ConsentBasis, SecurityError};
#[allow(unused_imports)]
pub use killswitch::{init as init_killswitch, is_killed, kill, resume};
#[allow(unused_imports)]
pub use policy::{normalize_scope, Capability, CapabilityGrant, GrantMode, PolicyFile, Scope};

pub fn record_audit(
    event: &str,
    capability: Option<&str>,
    scope: Option<&str>,
    target: Option<&str>,
    decision: &str,
    rule: &str,
    outcome: &str,
) {
    audit::record(&AuditEntry {
        event: event.to_string(),
        capability: capability.map(String::from),
        scope: scope.map(String::from),
        target: target.map(String::from),
        decision: decision.to_string(),
        rule: rule.to_string(),
        outcome: outcome.to_string(),
    });
}

use serde::Serialize;
use tauri::AppHandle;

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CapabilityInfo {
    pub id: String,
    pub label: String,
    pub mode: GrantMode,
    pub scopes: Vec<Scope>,
    pub is_high_risk: bool,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SecurityStatus {
    pub automation_enabled: bool,
    pub kill_switch_engaged: bool,
    pub status_reason: String,
    pub capabilities: Vec<CapabilityInfo>,
    pub recent_denials_24h: u32,
}

pub fn get_security_status() -> SecurityStatus {
    let (pol, is_invalid) = policy::load();
    let kill_engaged = killswitch::is_killed();

    let reason = if kill_engaged {
        "Stopped: kill switch is engaged".to_string()
    } else if is_invalid {
        "Denied: security policy file is corrupt or invalid".to_string()
    } else if !pol.automation_enabled {
        "Off: automation is disabled".to_string()
    } else {
        "Active: automation is enabled".to_string()
    };

    let mut capabilities = Vec::new();
    for cap in Capability::ALL {
        let grant = pol
            .capabilities
            .get(cap.as_str())
            .cloned()
            .unwrap_or_default();
        capabilities.push(CapabilityInfo {
            id: cap.as_str().to_string(),
            label: match cap {
                Capability::FsRead => "Read files and folders",
                Capability::FsWrite => "Create and modify files",
                Capability::NetRequest => "Network and web requests",
                Capability::ProcessRun => "Run programs and scripts",
                Capability::AppControl => "Control applications and windows",
                Capability::ScreenCapture => "Capture screen contents",
                Capability::RemoteCommand => "Execute remote commands",
                Capability::Autonomy => "Multi-step autonomous execution",
                Capability::MoneySpend => "Financial and paid actions",
            }
            .to_string(),
            mode: grant.mode,
            scopes: grant.scopes,
            is_high_risk: cap.is_high_risk(),
        });
    }

    let recent_denials = audit::count_recent_denials_24h();

    SecurityStatus {
        automation_enabled: pol.automation_enabled && !kill_engaged,
        kill_switch_engaged: kill_engaged,
        status_reason: reason,
        capabilities,
        recent_denials_24h: recent_denials,
    }
}

// ── Tauri Commands ─────────────────────────────────────────────────────────────

#[tauri::command]
pub fn security_status() -> SecurityStatus {
    get_security_status()
}

#[tauri::command]
pub fn security_set_capability(
    capability: String,
    mode: GrantMode,
    scopes: Vec<Scope>,
) -> Result<(), String> {
    let cap = Capability::from_str(&capability)
        .ok_or_else(|| format!("Unknown capability: {capability}"))?;

    // High risk capabilities cannot be permanently "Always" allowed without explicit restriction
    if cap.is_high_risk() && mode == GrantMode::Always && scopes.is_empty() {
        return Err("High-risk capabilities cannot be granted Always without explicit scopes".into());
    }

    let mut normalized_scopes = Vec::with_capacity(scopes.len());
    for s in scopes {
        normalized_scopes.push(policy::normalize_scope(&s)?);
    }

    let (mut pol, _) = policy::load();
    pol.capabilities.insert(
        cap.as_str().to_string(),
        CapabilityGrant {
            mode,
            scopes: normalized_scopes,
        },
    );

    policy::save(&pol)?;

    audit::record(&AuditEntry {
        event: "policy_changed".into(),
        capability: Some(cap.as_str().to_string()),
        scope: None,
        target: None,
        decision: format!("{mode:?}").to_ascii_lowercase(),
        rule: "user_configuration".into(),
        outcome: "saved".into(),
    });

    Ok(())
}

#[tauri::command]
pub fn security_consent_decide(
    id: String,
    args_hash: String,
    decision: Decision,
) -> Result<(), String> {
    consent::decide(&id, &args_hash, decision)
}

#[tauri::command]
pub fn security_kill(app: AppHandle) -> Result<(), String> {
    killswitch::kill(Some(&app))
}

#[tauri::command]
pub fn security_resume(app: AppHandle) -> Result<(), String> {
    killswitch::resume(Some(&app))
}

#[tauri::command]
pub fn audit_recent(limit: Option<usize>) -> Vec<serde_json::Value> {
    audit::recent(limit.unwrap_or(50))
}

#[tauri::command]
pub fn audit_export() -> Result<String, String> {
    audit::export_sanitized()
}

#[tauri::command]
pub fn audit_open_folder() -> Result<(), String> {
    let dir = audit::audit_dir();
    let _ = std::fs::create_dir_all(&dir);
    std::process::Command::new("explorer")
        .arg(&dir)
        .spawn()
        .map_err(|e| format!("failed to open audit folder: {e}"))?;
    Ok(())
}
