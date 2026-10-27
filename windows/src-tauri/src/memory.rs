// JARVIS Long-Term Memory Service for Windows
// Paritas dengan Phase 5 (PLAN-autonomous.md: MemoryService).
//
// Menyimpan preferensi & fakta jangka panjang pengguna di %APPDATA%\Mochi\memory.json
// yang disuntikkan secara dinamis ke system prompt AI.

use std::fs;
use std::path::PathBuf;
use std::sync::Mutex;

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct MemoryItem {
    pub id: String,
    pub fact: String,
    pub created_at: String,
}

#[derive(Debug, Default, Serialize, Deserialize)]
struct MemoryStore {
    items: Vec<MemoryItem>,
}

static MEMORY_LOCK: Mutex<()> = Mutex::new(());

fn memory_path() -> PathBuf {
    crate::settings::config_dir().join("memory.json")
}

fn load_store() -> MemoryStore {
    let path = memory_path();
    if let Ok(bytes) = fs::read(&path) {
        serde_json::from_slice(&bytes).unwrap_or_default()
    } else {
        MemoryStore::default()
    }
}

fn save_store(store: &MemoryStore) -> Result<(), String> {
    let _lock = MEMORY_LOCK.lock().unwrap();
    let dir = crate::settings::config_dir();
    let _ = fs::create_dir_all(&dir);
    let path = memory_path();
    let tmp = path.with_extension("tmp");
    let bytes = serde_json::to_vec_pretty(store).map_err(|e| e.to_string())?;
    fs::write(&tmp, bytes).map_err(|e| e.to_string())?;
    fs::rename(&tmp, &path).map_err(|e| e.to_string())?;
    Ok(())
}

fn chrono_now_string() -> String {
    let t = unsafe { windows::Win32::System::SystemInformation::GetLocalTime() };
    format!(
        "{:04}-{:02}-{:02} {:02}:{:02}:{:02}",
        t.wYear, t.wMonth, t.wDay, t.wHour, t.wMinute, t.wSecond
    )
}

/// Menambahkan fakta baru ke memori pengguna.
/// Melakukan sanitasi whitespace dan deduplikasi case-insensitive.
pub fn remember(fact: &str) -> Result<(MemoryItem, bool), String> {
    let clean = fact.trim();
    if clean.is_empty() {
        return Err("Fakta tidak boleh kosong.".into());
    }

    let mut store = load_store();
    let lower = clean.to_lowercase();

    // Cek apakah fakta sudah ada
    if let Some(pos) = store.items.iter().position(|i| i.fact.to_lowercase() == lower) {
        let existing = store.items[pos].clone();
        return Ok((existing, false));
    }

    let item = MemoryItem {
        id: uuid::Uuid::new_v4().to_string(),
        fact: clean.to_string(),
        created_at: chrono_now_string(),
    };

    store.items.push(item.clone());
    save_store(&store)?;
    Ok((item, true))
}

/// Mengambil seluruh memori fakta pengguna
pub fn all() -> Vec<MemoryItem> {
    load_store().items
}

/// Menghapus fakta berdasarkan ID
pub fn forget(id: &str) -> Result<bool, String> {
    let mut store = load_store();
    let len_before = store.items.len();
    store.items.retain(|i| i.id != id);
    if store.items.len() != len_before {
        save_store(&store)?;
        Ok(true)
    } else {
        Ok(false)
    }
}

/// Membersihkan seluruh memori
#[allow(dead_code)]
pub fn clear() -> Result<(), String> {
    let store = MemoryStore::default();
    save_store(&store)
}

/// Memformat seluruh fakta memori untuk disuntikkan ke system prompt AI
pub fn format_for_system_prompt() -> String {
    let items = all();
    if items.is_empty() {
        return String::new();
    }

    let mut out = String::from("\nFacts you remember about the user:\n");
    for item in items.iter().take(20) {
        out.push_str(&format!("• {}\n", item.fact));
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn remember_and_deduplicate() {
        let test_fact = format!("Test fact {}", uuid::Uuid::new_v4());
        let (first, is_new) = remember(&test_fact).unwrap();
        assert!(is_new);
        assert_eq!(first.fact, test_fact);

        let (second, is_new_2) = remember(&test_fact).unwrap();
        assert!(!is_new_2);
        assert_eq!(first.id, second.id);

        let deleted = forget(&first.id).unwrap();
        assert!(deleted);
    }
}
