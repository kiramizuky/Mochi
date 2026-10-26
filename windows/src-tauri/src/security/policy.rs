#![allow(dead_code)]

use std::collections::HashMap;
use std::fs;
use std::path::{Component, Path, PathBuf};

use serde::{Deserialize, Serialize};

pub const SCHEMA_VERSION: u32 = 1;

/// Fixed set of capabilities. A model, external client, or remote payload
/// cannot invent a new capability string.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum Capability {
    #[serde(rename = "fs.read")]
    FsRead,
    #[serde(rename = "fs.write")]
    FsWrite,
    #[serde(rename = "net.request")]
    NetRequest,
    #[serde(rename = "process.run")]
    ProcessRun,
    #[serde(rename = "app.control")]
    AppControl,
    #[serde(rename = "screen.capture")]
    ScreenCapture,
    #[serde(rename = "remote.command")]
    RemoteCommand,
    #[serde(rename = "autonomy")]
    Autonomy,
    #[serde(rename = "money.spend")]
    MoneySpend,
}

impl Capability {
    pub const ALL: &'static [Capability] = &[
        Capability::FsRead,
        Capability::FsWrite,
        Capability::NetRequest,
        Capability::ProcessRun,
        Capability::AppControl,
        Capability::ScreenCapture,
        Capability::RemoteCommand,
        Capability::Autonomy,
        Capability::MoneySpend,
    ];

    pub fn as_str(&self) -> &'static str {
        match self {
            Capability::FsRead => "fs.read",
            Capability::FsWrite => "fs.write",
            Capability::NetRequest => "net.request",
            Capability::ProcessRun => "process.run",
            Capability::AppControl => "app.control",
            Capability::ScreenCapture => "screen.capture",
            Capability::RemoteCommand => "remote.command",
            Capability::Autonomy => "autonomy",
            Capability::MoneySpend => "money.spend",
        }
    }

    pub fn from_str(s: &str) -> Option<Capability> {
        match s {
            "fs.read" => Some(Capability::FsRead),
            "fs.write" => Some(Capability::FsWrite),
            "net.request" => Some(Capability::NetRequest),
            "process.run" => Some(Capability::ProcessRun),
            "app.control" => Some(Capability::AppControl),
            "screen.capture" => Some(Capability::ScreenCapture),
            "remote.command" => Some(Capability::RemoteCommand),
            "autonomy" => Some(Capability::Autonomy),
            "money.spend" => Some(Capability::MoneySpend),
            _ => None,
        }
    }

    /// Whether this capability class is high-risk and requires explicit human
    /// consent even if autopilot is ON.
    pub fn is_high_risk(&self) -> bool {
        matches!(
            self,
            Capability::ProcessRun
                | Capability::MoneySpend
                | Capability::RemoteCommand
                | Capability::Autonomy
        )
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum GrantMode {
    Denied,
    Session,
    Always,
}

impl Default for GrantMode {
    fn default() -> Self {
        GrantMode::Denied
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum Scope {
    #[serde(rename = "folder")]
    Folder { path: String },
    #[serde(rename = "window")]
    Window { process: String },
    #[serde(rename = "recipient")]
    Recipient { id: String },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CapabilityGrant {
    pub mode: GrantMode,
    #[serde(default)]
    pub scopes: Vec<Scope>,
}

impl Default for CapabilityGrant {
    fn default() -> Self {
        Self {
            mode: GrantMode::Denied,
            scopes: Vec::new(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PolicyFile {
    pub schema_version: u32,
    pub automation_enabled: bool,
    pub kill_switch_engaged: bool,
    pub capabilities: HashMap<String, CapabilityGrant>,
}

impl Default for PolicyFile {
    fn default() -> Self {
        let mut capabilities = HashMap::new();
        for cap in Capability::ALL {
            capabilities.insert(cap.as_str().to_string(), CapabilityGrant::default());
        }
        Self {
            schema_version: SCHEMA_VERSION,
            automation_enabled: false,
            kill_switch_engaged: false,
            capabilities,
        }
    }
}

pub fn policy_path() -> PathBuf {
    crate::settings::config_dir().join("security.json")
}

/// Normalizes a folder path for Windows security scope comparison:
/// - Rejects parent traversal (`..`)
/// - Rejects alternate data streams (`:`)
/// - Rejects environment variable syntax (`%` or `$`)
/// - Rejects reserved device names (CON, PRN, AUX, NUL, COM1-9, LPT1-9)
/// - Normalizes slashes, trims trailing spaces and dots from components
/// - Compares case-insensitively
pub fn normalize_folder_path(raw: &str) -> Result<String, String> {
    if raw.trim().is_empty() {
        return Err("Path cannot be empty".into());
    }
    if raw.contains('%') || raw.contains('$') {
        return Err("Environment variables are forbidden in scopes".into());
    }

    let p = Path::new(raw);
    let mut normalized_parts: Vec<String> = Vec::new();

    for comp in p.components() {
        match comp {
            Component::Prefix(prefix) => {
                normalized_parts.push(prefix.as_os_str().to_string_lossy().to_string());
            }
            Component::RootDir => {
                if normalized_parts.is_empty() {
                    normalized_parts.push("\\".to_string());
                }
            }
            Component::CurDir => continue,
            Component::ParentDir => {
                return Err("Parent directory traversal (..) is forbidden".into());
            }
            Component::Normal(os_str) => {
                let part = os_str.to_string_lossy();
                let clean = part.trim_end_matches([' ', '.']);
                if clean.is_empty() {
                    return Err("Invalid path component".into());
                }
                if clean.contains(':') {
                    return Err("Alternate data streams are forbidden".into());
                }

                // Check Windows reserved device names (e.g. NUL, NUL.txt, CON, COM1.log)
                let stem = clean.split('.').next().unwrap_or(clean);
                let uppercase = stem.to_ascii_uppercase();
                let is_reserved = matches!(
                    uppercase.as_str(),
                    "CON"
                        | "PRN"
                        | "AUX"
                        | "NUL"
                        | "COM1"
                        | "COM2"
                        | "COM3"
                        | "COM4"
                        | "COM5"
                        | "COM6"
                        | "COM7"
                        | "COM8"
                        | "COM9"
                        | "LPT1"
                        | "LPT2"
                        | "LPT3"
                        | "LPT4"
                        | "LPT5"
                        | "LPT6"
                        | "LPT7"
                        | "LPT8"
                        | "LPT9"
                );
                if is_reserved {
                    return Err(format!("Reserved Windows device name: {clean}"));
                }
                normalized_parts.push(clean.to_string());
            }
        }
    }

    if normalized_parts.is_empty() {
        return Err("Empty normalized path".into());
    }

    // Join with backslash, ensuring clean Windows format
    let mut res = String::new();
    for (i, part) in normalized_parts.iter().enumerate() {
        if i == 0 {
            res.push_str(part);
            if part.ends_with(':') {
                res.push('\\');
            }
        } else {
            if !res.ends_with('\\') {
                res.push('\\');
            }
            res.push_str(part);
        }
    }

    Ok(res)
}

/// Normalizes a scope for storage and comparison.
pub fn normalize_scope(scope: &Scope) -> Result<Scope, String> {
    match scope {
        Scope::Folder { path } => {
            let normalized = normalize_folder_path(path)?;
            Ok(Scope::Folder { path: normalized })
        }
        Scope::Window { process } => {
            let trimmed = process.trim();
            if trimmed.is_empty() {
                return Err("Process name cannot be empty".into());
            }
            if trimmed.contains('\\') || trimmed.contains('/') {
                return Err("Process must be an executable name, not a path".into());
            }
            Ok(Scope::Window {
                process: trimmed.to_ascii_lowercase(),
            })
        }
        Scope::Recipient { id } => {
            let trimmed = id.trim();
            if trimmed.is_empty() {
                return Err("Recipient id cannot be empty".into());
            }
            Ok(Scope::Recipient {
                id: trimmed.to_string(),
            })
        }
    }
}

/// Checks whether `target` falls within `granted`.
/// Path comparison matches component boundaries, so `C:\Data` matches
/// `C:\Data\sub\file.txt`, but never `C:\DataBackup`.
pub fn scope_matches(granted: &Scope, target: &Scope) -> bool {
    match (granted, target) {
        (Scope::Folder { path: g_path }, Scope::Folder { path: t_path }) => {
            let g_norm = match normalize_folder_path(g_path) {
                Ok(p) => p,
                Err(_) => return false,
            };
            let t_norm = match normalize_folder_path(t_path) {
                Ok(p) => p,
                Err(_) => return false,
            };

            let g_lower = g_norm.to_ascii_lowercase();
            let t_lower = t_norm.to_ascii_lowercase();

            if g_lower == t_lower {
                return true;
            }

            let g_prefix = if g_lower.ends_with('\\') {
                g_lower
            } else {
                format!("{g_lower}\\")
            };

            t_lower.starts_with(&g_prefix)
        }
        (Scope::Window { process: g_proc }, Scope::Window { process: t_proc }) => {
            g_proc.eq_ignore_ascii_case(t_proc)
        }
        (Scope::Recipient { id: g_id }, Scope::Recipient { id: t_id }) => g_id == t_id,
        _ => false,
    }
}

/// Loads policy from `%APPDATA%\Coucou\security.json`.
/// Returns `(policy, is_invalid)`.
/// If the file does not exist, returns `(default_deny_policy, false)`.
/// If the file is corrupt or has an unknown schema, returns `(default_deny_policy, true)`.
pub fn load() -> (PolicyFile, bool) {
    let path = policy_path();
    let bytes = match fs::read(&path) {
        Ok(b) => b,
        Err(_) => return (PolicyFile::default(), false),
    };

    let parsed: Result<PolicyFile, _> = serde_json::from_slice(&bytes);
    match parsed {
        Ok(policy) => {
            if policy.schema_version != SCHEMA_VERSION {
                eprintln!(
                    "[mochi::security] unknown schemaVersion {}",
                    policy.schema_version
                );
                return (PolicyFile::default(), true);
            }
            (policy, false)
        }
        Err(err) => {
            eprintln!("[mochi::security] corrupt policy file: {err}");
            (PolicyFile::default(), true)
        }
    }
}

/// Atomically saves the policy file via a temporary file in the same directory.
pub fn save(policy: &PolicyFile) -> Result<(), String> {
    let path = policy_path();
    if let Some(parent) = path.parent() {
        let _ = fs::create_dir_all(parent);
    }

    let json_bytes = serde_json::to_vec_pretty(policy).map_err(|e| e.to_string())?;

    let tmp = path.with_extension(format!("json.tmp-{}", std::process::id()));
    fs::write(&tmp, &json_bytes).map_err(|e| format!("failed to write temp policy: {e}"))?;

    // Atomic replace on Windows
    if let Err(e) = fs::rename(&tmp, &path) {
        let _ = fs::remove_file(&tmp);
        return Err(format!("failed to replace policy file: {e}"));
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_policy_denies_all_capabilities() {
        let policy = PolicyFile::default();
        assert!(!policy.automation_enabled);
        assert!(!policy.kill_switch_engaged);
        assert_eq!(policy.capabilities.len(), Capability::ALL.len());
        for cap in Capability::ALL {
            let grant = policy.capabilities.get(cap.as_str()).unwrap();
            assert_eq!(grant.mode, GrantMode::Denied);
            assert!(grant.scopes.is_empty());
        }
    }

    #[test]
    fn scope_normalisation_rejects_dangerous_paths() {
        assert!(normalize_folder_path("..\\something").is_err());
        assert!(normalize_folder_path("C:\\safe\\..\\escaped").is_err());
        assert!(normalize_folder_path("C:\\data\\CON").is_err());
        assert!(normalize_folder_path("C:\\data\\NUL.txt").is_err());
        assert!(normalize_folder_path("C:\\file.txt:stream").is_err());
        assert!(normalize_folder_path("%USERPROFILE%\\docs").is_err());
    }

    #[test]
    fn scope_matching_respects_component_boundaries() {
        let granted = Scope::Folder {
            path: "C:\\Data".into(),
        };
        let target_sub = Scope::Folder {
            path: "C:\\Data\\project\\file.txt".into(),
        };
        let target_exact = Scope::Folder {
            path: "C:\\data".into(),
        };
        let target_sibling = Scope::Folder {
            path: "C:\\DataBackup\\file.txt".into(),
        };

        assert!(scope_matches(&granted, &target_sub));
        assert!(scope_matches(&granted, &target_exact));
        assert!(!scope_matches(&granted, &target_sibling));
    }
}
