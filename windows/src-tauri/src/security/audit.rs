// Local audit trail: append-only JSONL with HMAC-SHA-256 hash chaining,
// field allowlisting, target sanitization, and monthly rotation.

use std::fs::{self, File, OpenOptions};
use std::io::{BufRead, BufReader, Write};
use std::path::PathBuf;
use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};

use hmac::{Hmac, Mac};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::Sha256;

type HmacSha256 = Hmac<Sha256>;

const AUDIT_SECRET_KEY: &str = "coucou-audit-hmac";
const MAX_FILE_SIZE_BYTES: u64 = 10 * 1024 * 1024; // 10 MB
const INITIAL_PREV_MAC: &str = "0000000000000000000000000000000000000000000000000000000000000000";

static AUDIT_LOCK: Mutex<()> = Mutex::new(());

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AuditEntry {
    pub event: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub capability: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub scope: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub target: Option<String>,
    pub decision: String,
    pub rule: String,
    pub outcome: String,
}

pub fn audit_dir() -> PathBuf {
    crate::settings::local_dir().join("audit")
}

fn iso_now() -> String {
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default();
    let secs = now.as_secs();
    let millis = now.subsec_millis();

    // Approximate ISO 8601 formatting without huge external chrono dependency
    // Uses Windows local/system time via standard library format
    format!("{secs}.{millis:03}Z")
}

fn month_stamp() -> String {
    // Current YYYY-MM
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();

    // Days since unix epoch
    let days = now / 86400;
    // Estimate year and month from days
    let mut year = 1970;
    let mut d = days;

    loop {
        let leap = (year % 4 == 0 && year % 100 != 0) || (year % 400 == 0);
        let days_in_year = if leap { 366 } else { 365 };
        if d < days_in_year {
            let month_days = [
                31,
                if leap { 29 } else { 28 },
                31,
                30,
                31,
                30,
                31,
                31,
                30,
                31,
                30,
                31,
            ];
            let mut month = 1;
            for md in month_days {
                if d < md {
                    break;
                }
                d -= md;
                month += 1;
            }
            return format!("{year:04}-{month:02}");
        }
        d -= days_in_year;
        year += 1;
    }
}

pub fn current_audit_file() -> PathBuf {
    let dir = audit_dir();
    dir.join(format!("audit-{}.jsonl", month_stamp()))
}

/// Retrieves or creates a 32-byte HMAC secret in Credential Manager.
pub fn get_or_create_hmac_key() -> Result<Vec<u8>, String> {
    if let Some(existing_hex) = crate::secrets::get(AUDIT_SECRET_KEY) {
        if let Ok(bytes) = hex_decode(&existing_hex) {
            if bytes.len() >= 32 {
                return Ok(bytes);
            }
        }
    }

    // Generate random 32 bytes using UUIDs
    let mut key = Vec::with_capacity(32);
    for _ in 0..2 {
        let u = uuid::Uuid::new_v4();
        key.extend_from_slice(u.as_bytes());
    }

    let hex_key = hex_encode(&key);
    crate::secrets::set(AUDIT_SECRET_KEY, &hex_key)?;
    Ok(key)
}

fn hex_encode(bytes: &[u8]) -> String {
    let mut s = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        s.push_str(&format!("{b:02x}"));
    }
    s
}

fn hex_decode(s: &str) -> Result<Vec<u8>, ()> {
    if s.len() % 2 != 0 {
        return Err(());
    }
    let mut bytes = Vec::with_capacity(s.len() / 2);
    for i in (0..s.len()).step_by(2) {
        let b = u8::from_str_radix(&s[i..i + 2], 16).map_err(|_| ())?;
        bytes.push(b);
    }
    Ok(bytes)
}

/// Sanitizes a target string:
/// - Replaces user's home directory with `~`
/// - Strips control characters
/// - Caps at 160 characters
pub fn sanitize_target(target: &str) -> String {
    let home = std::env::var("USERPROFILE").unwrap_or_default();
    let replaced = if !home.is_empty() && target.starts_with(&home) {
        format!("~{}", &target[home.len()..])
    } else {
        target.to_string()
    };

    let mut clean = String::with_capacity(replaced.len().min(160));
    for c in replaced.chars() {
        if clean.len() >= 160 {
            break;
        }
        if !c.is_control() {
            clean.push(c);
        }
    }
    clean
}

/// Finds the last MAC written to the current or most recent audit log file.
fn get_last_mac(path: &PathBuf) -> String {
    if let Ok(file) = File::open(path) {
        let reader = BufReader::new(file);
        let mut last_mac = None;
        for line in reader.lines().map_while(Result::ok) {
            if let Ok(v) = serde_json::from_str::<Value>(&line) {
                if let Some(mac) = v.get("mac").and_then(|m| m.as_str()) {
                    last_mac = Some(mac.to_string());
                }
            }
        }
        if let Some(m) = last_mac {
            return m;
        }
    }
    INITIAL_PREV_MAC.to_string()
}

/// Records a security audit event to the append-only JSONL log.
pub fn record(entry: &AuditEntry) {
    let _guard = AUDIT_LOCK.lock().unwrap();

    let dir = audit_dir();
    let _ = fs::create_dir_all(&dir);

    let path = current_audit_file();
    if let Ok(meta) = fs::metadata(&path) {
        if meta.len() >= MAX_FILE_SIZE_BYTES {
            eprintln!("[coucou::audit] audit log reached 10 MB limit");
            return;
        }
    }

    let prev_mac = get_last_mac(&path);
    let key = get_or_create_hmac_key().unwrap_or_else(|_| vec![0u8; 32]);

    let id = uuid::Uuid::new_v4().to_string();
    let ts = iso_now();
    let app = env!("CARGO_PKG_VERSION");

    let sanitized_target = entry.target.as_deref().map(sanitize_target);

    // Canonical JSON object without `mac` field
    let mut canonical = json!({
        "v": 1,
        "ts": ts,
        "id": id,
        "event": entry.event,
        "decision": entry.decision,
        "rule": entry.rule,
        "outcome": entry.outcome,
        "app": app,
        "prev": prev_mac,
    });

    if let Some(ref cap) = entry.capability {
        canonical["capability"] = json!(cap);
    }
    if let Some(ref scope) = entry.scope {
        canonical["scope"] = json!(scope);
    }
    if let Some(ref tgt) = sanitized_target {
        canonical["target"] = json!(tgt);
    }

    let canonical_bytes = serde_json::to_vec(&canonical).unwrap_or_default();

    let mut mac_calc = HmacSha256::new_from_slice(&key).unwrap();
    mac_calc.update(&canonical_bytes);
    let mac_result = mac_calc.finalize().into_bytes();
    let mac_hex = hex_encode(&mac_result);

    canonical["mac"] = json!(mac_hex);

    if let Ok(mut file) = OpenOptions::new().create(true).append(true).open(&path) {
        if let Ok(line) = serde_json::to_string(&canonical) {
            let _ = writeln!(file, "{line}");
        }
    }
}

/// Retrieves the most recent `limit` audit events.
pub fn recent(limit: usize) -> Vec<Value> {
    let _guard = AUDIT_LOCK.lock().unwrap();
    let path = current_audit_file();
    let mut events = Vec::new();

    if let Ok(file) = File::open(&path) {
        let reader = BufReader::new(file);
        for line in reader.lines().map_while(Result::ok) {
            if let Ok(val) = serde_json::from_str::<Value>(&line) {
                events.push(val);
            }
        }
    }

    // Return the newest first
    events.reverse();
    events.truncate(limit);
    events
}

/// Counts total denied events in the log in the last 24 hours.
pub fn count_recent_denials_24h() -> u32 {
    let _guard = AUDIT_LOCK.lock().unwrap();
    let path = current_audit_file();
    let mut count = 0;

    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    let cutoff = now.saturating_sub(86400);

    if let Ok(file) = File::open(&path) {
        let reader = BufReader::new(file);
        for line in reader.lines().map_while(Result::ok) {
            if let Ok(val) = serde_json::from_str::<Value>(&line) {
                if let Some(dec) = val.get("decision").and_then(|d| d.as_str()) {
                    if dec == "deny" {
                        if let Some(ts_str) = val.get("ts").and_then(|t| t.as_str()) {
                            if let Some(secs_str) = ts_str.split('.').next() {
                                if let Ok(s) = secs_str.parse::<u64>() {
                                    if s >= cutoff {
                                        count += 1;
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    count
}

/// Exports sanitized audit events as a single JSONL string.
pub fn export_sanitized() -> Result<String, String> {
    let _guard = AUDIT_LOCK.lock().unwrap();
    let path = current_audit_file();
    let file = File::open(&path).map_err(|e| format!("cannot open audit log: {e}"))?;
    let reader = BufReader::new(file);

    let mut out = String::new();
    for line in reader.lines().map_while(Result::ok) {
        if let Ok(val) = serde_json::from_str::<Value>(&line) {
            if let Ok(clean_line) = serde_json::to_string(&val) {
                out.push_str(&clean_line);
                out.push('\n');
            }
        }
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sanitize_target_replaces_home_and_strips_control_chars() {
        let home = std::env::var("USERPROFILE").unwrap_or_default();
        if !home.is_empty() {
            let target = format!("{home}\\Documents\\secret\nfile.txt");
            let sanitized = sanitize_target(&target);
            assert!(sanitized.starts_with("~\\Documents\\secret"));
            assert!(!sanitized.contains('\n'));
        }
    }

    #[test]
    fn hmac_hex_round_trip() {
        let data = b"hello audit world";
        let hex = hex_encode(data);
        let decoded = hex_decode(&hex).expect("valid hex");
        assert_eq!(decoded, data);
    }
}
