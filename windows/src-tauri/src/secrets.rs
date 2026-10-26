// API keys live in the Windows Credential Manager, never on disk and never in
// the front end — the island can only ask whether a key is present.

use keyring::Entry;

const SERVICE: &str = "id.pcstudio.mochi";

/// Every key Coucou may store. Anything outside this list is refused.
pub const KNOWN_KEYS: &[&str] = &[
    "anthropic-api-key",
    "openai-api-key",
    "gemini-api-key",
    "groq-api-key",
    "local-api-key",
    "n8n-url",
    "n8n-api-key",
    "vercel-token",
    "github-token",
    "stripe-api-key",
    "resend-api-key",
    "notion-api-key",
    "calcom-api-key",
];

fn entry(key: &str) -> Option<Entry> {
    if !KNOWN_KEYS.contains(&key) {
        return None;
    }
    Entry::new(SERVICE, key).ok()
}

pub fn get(key: &str) -> Option<String> {
    entry(key)?.get_password().ok().filter(|v| !v.is_empty())
}

pub fn set(key: &str, value: &str) -> Result<(), String> {
    let entry = entry(key).ok_or_else(|| format!("unknown key {key}"))?;
    if value.is_empty() {
        let _ = entry.delete_credential();
        return Ok(());
    }
    entry.set_password(value).map_err(|e| e.to_string())
}

pub fn clear(key: &str) -> Result<(), String> {
    let entry = entry(key).ok_or_else(|| format!("unknown key {key}"))?;
    match entry.delete_credential() {
        Ok(()) | Err(keyring::Error::NoEntry) => Ok(()),
        Err(e) => Err(e.to_string()),
    }
}

pub fn present(key: &str) -> bool {
    get(key).is_some()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_known_keys_can_reach_the_credential_manager() {
        assert!(KNOWN_KEYS.len() >= 13);
        let unique: std::collections::HashSet<_> = KNOWN_KEYS.iter().collect();
        assert_eq!(unique.len(), KNOWN_KEYS.len(), "duplicate key alias");
        for key in KNOWN_KEYS {
            assert!(!key.is_empty());
            assert!(
                key.chars()
                    .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-'),
                "unexpected key shape: {key}"
            );
        }
    }

    #[test]
    fn an_unknown_key_is_refused_before_touching_windows() {
        for key in [
            "",
            "ANTHROPIC-API-KEY",
            "anthropic_api_key",
            "password",
            "../escape",
        ] {
            assert!(entry(key).is_none(), "{key} should not be addressable");
            assert!(get(key).is_none());
            assert!(!present(key));
            assert!(set(key, "value").is_err());
            assert!(clear(key).is_err());
        }
    }

    #[test]
    fn the_service_name_matches_the_bundle_identifier() {
        assert_eq!(SERVICE, "id.pcstudio.mochi");
    }
}
