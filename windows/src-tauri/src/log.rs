// Small append-only log at %LOCALAPPDATA%\Coucou\coucou.log — the Windows
// equivalent of nbLog() in HookServer.swift. Nothing leaves the machine.
//
// Every line is sanitised before it is written: token-shaped values are
// redacted, control characters are flattened, and a single line is capped. The
// file is bounded, and the user can export a sanitised copy from Settings.

use std::io::Write;
use std::path::{Path, PathBuf};

use windows::Win32::System::SystemInformation::GetLocalTime;

use crate::settings;

const MAX_LOG_BYTES: u64 = 1_000_000;
const MAX_EXPORT_BYTES: usize = 512 * 1024;
const MAX_LINE_CHARS: usize = 2_000;

/// Token prefixes that are worth redacting on sight. Longest first so
/// `sk-ant-…` wins over `sk-…` at the same position.
const SECRET_MARKERS: &[&str] = &[
    "github_pat_",
    "sk-ant-",
    "xoxb-",
    "xoxp-",
    "gsk_",
    "ghp_",
    "gho_",
    "AIza",
    "ntn_",
    "cal_",
    "re_",
    "sk-",
    "Bearer ",
    "api_key=",
    "api-key=",
    "apikey=",
    "password=",
    "secret=",
    "token=",
    "token: ",
    "authorization: ",
];

pub fn line(message: impl AsRef<str>) {
    let t = unsafe { GetLocalTime() };
    let stamp = format!(
        "{:04}-{:02}-{:02} {:02}:{:02}:{:02}",
        t.wYear, t.wMonth, t.wDay, t.wHour, t.wMinute, t.wSecond
    );
    let dir = settings::local_dir();
    if std::fs::create_dir_all(&dir).is_err() {
        return;
    }
    let path = dir.join("coucou.log");
    rotate_if_needed(&path);
    if let Ok(mut file) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)
    {
        let _ = writeln!(file, "{stamp} {}", sanitize(message.as_ref()));
    }
}

/// Bounded by construction: one previous file keeps the total at roughly two
/// megabytes even when the app has been running for weeks.
fn rotate_if_needed(path: &Path) {
    if std::fs::metadata(path)
        .map(|m| m.len() > MAX_LOG_BYTES)
        .unwrap_or(false)
    {
        let previous = path.with_extension("log.1");
        let _ = std::fs::remove_file(&previous);
        let _ = std::fs::rename(path, previous);
    }
}

/// Writes a sanitised, size-capped copy next to the log and returns its path.
/// The original stays untouched so the user can keep debugging if they want.
pub fn export() -> std::io::Result<PathBuf> {
    let dir = settings::local_dir();
    std::fs::create_dir_all(&dir)?;
    let target = dir.join("coucou-log-export.txt");
    let mut out = String::new();
    for name in ["coucou.log.1", "coucou.log"] {
        let Ok(text) = std::fs::read_to_string(dir.join(name)) else {
            continue;
        };
        for line in text.lines() {
            if out.len() >= MAX_EXPORT_BYTES {
                break;
            }
            out.push_str(&sanitize(line));
            out.push('\n');
        }
    }
    // `sanitize` caps each line, but the total still needs a hard byte ceiling.
    if out.len() > MAX_EXPORT_BYTES {
        out.truncate(MAX_EXPORT_BYTES);
        while !out.is_char_boundary(out.len()) {
            out.pop();
        }
    }
    std::fs::write(&target, out)?;
    Ok(target)
}

/// Redacts token-shaped values and flattens control characters. This is applied
/// both when writing a line and again when exporting, so an old log written by a
/// previous build cannot leak a secret through the export button.
pub fn sanitize(input: &str) -> String {
    let flattened: String = input
        .chars()
        .map(|c| if c.is_control() { ' ' } else { c })
        .collect();
    let redacted = redact(&flattened);
    redacted.chars().take(MAX_LINE_CHARS).collect()
}

fn redact(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut rest = text;
    while let Some((index, marker)) = find_marker(rest) {
        out.push_str(&rest[..index]);
        out.push_str(marker);
        let after = &rest[index + marker.len()..];
        let end = after
            .char_indices()
            .find(|(_, c)| {
                c.is_whitespace() || matches!(c, '"' | '\'' | ',' | ';' | '}' | ')' | ']')
            })
            .map(|(i, _)| i)
            .unwrap_or(after.len());
        out.push_str("[redacted]");
        rest = &after[end..];
    }
    out.push_str(rest);
    out
}

fn find_marker(text: &str) -> Option<(usize, &'static str)> {
    let mut best: Option<(usize, &'static str)> = None;
    for marker in SECRET_MARKERS {
        let mut from = 0;
        while let Some(offset) = text[from..].find(marker) {
            let index = from + offset;
            let boundary = text[..index]
                .chars()
                .next_back()
                .map(|c| !c.is_ascii_alphanumeric())
                .unwrap_or(true);
            if boundary {
                let better = match best {
                    None => true,
                    Some((best_index, best_marker)) => {
                        index < best_index
                            || (index == best_index && marker.len() > best_marker.len())
                    }
                };
                if better {
                    best = Some((index, marker));
                }
            }
            from = index + marker.len();
        }
    }
    best
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn token_shapes_are_redacted() {
        for (input, leaked) in [
            ("key sk-ant-abc123 next", "abc123"),
            ("gsk_abcdefghij", "abcdefghij"),
            ("AIzaSyABCDEFGH", "SyABCDEFGH"),
            ("Authorization: Bearer abc.def.ghi", "abc.def.ghi"),
            ("token=abc&x=1", "abc"),
            ("password=hunter2", "hunter2"),
            ("github_pat_11ABCDEFG", "11ABCDEFG"),
        ] {
            let clean = sanitize(input);
            assert!(!clean.contains(leaked), "{input} leaked as {clean}");
            assert!(
                clean.contains("[redacted]"),
                "{input} was not redacted: {clean}"
            );
        }
    }

    #[test]
    fn ordinary_words_are_not_redacted() {
        assert_eq!(sanitize("brisk-walk is fine"), "brisk-walk is fine");
        assert_eq!(sanitize("token bucket is fine"), "token bucket is fine");
        assert_eq!(sanitize("no secrets here"), "no secrets here");
    }

    #[test]
    fn control_characters_and_line_length_are_capped() {
        let flat = sanitize("line one\r\nline two\tend");
        assert!(!flat.contains('\n'));
        assert!(!flat.contains('\r'));
        assert!(!flat.contains('\t'));

        let long = sanitize(&"x".repeat(MAX_LINE_CHARS + 500));
        assert_eq!(long.chars().count(), MAX_LINE_CHARS);
    }
}
