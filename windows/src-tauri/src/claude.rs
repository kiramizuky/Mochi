// Chat client — one chat history, dispatched to whichever provider the user
// picked in Settings. The provider registry and the request/response shapes live
// in providers.rs; this file only owns the conversation and file context.
//
// Everything happens here rather than in the island: the API key never leaves
// the Credential Manager, and file bytes never cross the IPC boundary.

use std::sync::Mutex;

use serde::{Deserialize, Serialize};

use crate::providers::{self, Attachment, Provider, Turn};
use crate::secrets;

/// Text and code files are inlined; anything larger is skipped, as on macOS.
const MAX_INLINE_TEXT: u64 = 200_000;

const SYSTEM_PROMPT: &str = "You are Mochi, a personal AI assistant living at the top of the user's screen. \
You have web search access and can help with absolutely anything — research, coding, finding places, recommendations, tasks, questions. \
Respond in the user's language. Be thorough and complete — use as much detail as the task requires. \
No markdown formatting (no **, no ##, no bullet dashes). Use plain text with line breaks.";

#[derive(Default)]
pub struct Chat {
    /// Provider-neutral history. Attachments ride on the turn they were sent
    /// with, so switching providers never sends a provider-specific block.
    messages: Mutex<Vec<Turn>>,
}

impl Chat {
    pub fn reset(&self) {
        self.messages.lock().unwrap().clear();
    }

    fn is_empty(&self) -> bool {
        self.messages.lock().unwrap().is_empty()
    }

    fn push(&self, turn: Turn) {
        self.messages.lock().unwrap().push(turn);
    }

    fn pop(&self) {
        self.messages.lock().unwrap().pop();
    }

    fn snapshot(&self) -> Vec<Turn> {
        self.messages.lock().unwrap().clone()
    }
}

#[derive(Debug, Clone, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum ChatContext {
    File {
        name: String,
        path: String,
    },
    Window {
        app_name: String,
        title: String,
        url: Option<String>,
    },
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ChatReply {
    pub text: String,
}

/// One chat turn. Returns the assistant's text, or a message the island shows
/// in the note view.
pub async fn send(
    chat: &Chat,
    provider: Provider,
    model: &str,
    local_endpoint: &str,
    query: String,
    context: Option<ChatContext>,
) -> Result<ChatReply, String> {
    let key = secrets::get(provider.key_name());

    let mut attachments: Vec<Attachment> = Vec::new();
    let mut preamble = String::new();

    // File / window context rides along with the first message only, exactly
    // like ClaudeService.chat() on macOS.
    if chat.is_empty() {
        match &context {
            Some(ChatContext::File { name, path }) => {
                match file_attachment(path) {
                    Some(attachment) => attachments.push(attachment),
                    None => {
                        if let Some(contents) = read_text(path) {
                            preamble.push_str(&format!("File contents:\n{contents}\n\n"));
                        }
                    }
                }
                preamble.push_str(&format!("File: {name}\n\n"));
            }
            Some(ChatContext::Window {
                app_name,
                title,
                url,
            }) => {
                let mut text = format!("Context — App: {app_name}, Window: {title}");
                if let Some(url) = url {
                    text.push_str(&format!(", URL: {url}"));
                }
                preamble.push_str(&text);
                preamble.push_str("\n\n");
            }
            None => {}
        }
    }

    preamble.push_str(&query);
    chat.push(Turn {
        role: "user",
        text: preamble,
        attachments,
    });

    let q_lower = query.to_lowercase();

    // JARVIS Direct Action: Remember user facts
    if q_lower.starts_with("ingat bahwa ") || q_lower.starts_with("ingat: ") || q_lower.starts_with("remember that ") {
        let fact = query
            .trim_start_matches("ingat bahwa ")
            .trim_start_matches("ingat: ")
            .trim_start_matches("remember that ")
            .trim();
        if !fact.is_empty() {
            let _ = crate::memory::remember(fact);
            let reply = format!("Baik, saya sudah mengingatnya: \"{}\"", fact);
            chat.push(Turn {
                role: "assistant",
                text: reply.clone(),
                attachments: Vec::new(),
            });
            return Ok(ChatReply { text: reply });
        }
    }

    // JARVIS Sentinel Tool Direct Integration
    if q_lower.contains("audit keamanan") || q_lower.contains("cek keamanan") || q_lower.contains("security audit") {
        let report = crate::sentinel::audit_pc_security();
        let reply = report.summary_markdown;
        chat.push(Turn {
            role: "assistant",
            text: reply.clone(),
            attachments: Vec::new(),
        });
        return Ok(ChatReply { text: reply });
    }

    if q_lower.contains("siapa saja di wifi") || q_lower.contains("scan wifi") || q_lower.contains("pindai jaringan") || q_lower.contains("scan lan") {
        let scan = crate::sentinel::scan_local_network();
        let mut reply = format!("### Hasil Pemindaian Jaringan Lokal (LAN)\n{}\n\n", scan.summary_text);
        for d in &scan.devices {
            reply.push_str(&format!("• `{}` ({}) — {}\n", d.ip_address, d.mac_address, d.device_type_guess));
        }
        chat.push(Turn {
            role: "assistant",
            text: reply.clone(),
            attachments: Vec::new(),
        });
        return Ok(ChatReply { text: reply });
    }

    // ── Desktop Applications & Server Integrations Direct Actions ────────────

    // Running Apps listing
    if q_lower.contains("aplikasi apa saja")
        || q_lower.contains("aplikasi yang jalan")
        || q_lower.contains("aplikasi yang terbuka")
        || q_lower.contains("list aplikasi")
        || q_lower.contains("running apps")
    {
        let apps = crate::app_integrations::list_running_apps();
        let reply = if apps.is_empty() {
            "Tidak ditemukan aplikasi desktop dengan jendela aktif yang sedang berjalan.".into()
        } else {
            let mut s = format!("### Aplikasi Desktop yang Sedang Berjalan ({}):\n", apps.len());
            for app in &apps {
                s.push_str(&format!("• **{}** (PID: {}) — *{}*\n", app.process_name, app.pid, app.window_title));
            }
            s
        };
        chat.push(Turn {
            role: "assistant",
            text: reply.clone(),
            attachments: Vec::new(),
        });
        return Ok(ChatReply { text: reply });
    }

    // Launch app
    if q_lower.starts_with("buka ") || q_lower.starts_with("jalankan ") || q_lower.starts_with("launch ") || q_lower.starts_with("open ") {
        let app_target = query
            .trim_start_matches("buka ")
            .trim_start_matches("jalankan ")
            .trim_start_matches("launch ")
            .trim_start_matches("open ")
            .trim();
        if !app_target.is_empty() && !app_target.starts_with("http") {
            let res = crate::app_integrations::launch_app(app_target, None);
            let reply = match res {
                Ok(msg) => msg,
                Err(err) => format!("Tidak dapat membuka '{}': {}", app_target, err),
            };
            chat.push(Turn {
                role: "assistant",
                text: reply.clone(),
                attachments: Vec::new(),
            });
            return Ok(ChatReply { text: reply });
        }
    }

    // Close app
    if q_lower.starts_with("tutup ") || q_lower.starts_with("close ") || q_lower.starts_with("kill ") {
        let app_target = query
            .trim_start_matches("tutup ")
            .trim_start_matches("close ")
            .trim_start_matches("kill ")
            .trim();
        if !app_target.is_empty() {
            let res = crate::app_integrations::close_app(app_target);
            let reply = match res {
                Ok(msg) => msg,
                Err(err) => err,
            };
            chat.push(Turn {
                role: "assistant",
                text: reply.clone(),
                attachments: Vec::new(),
            });
            return Ok(ChatReply { text: reply });
        }
    }

    // Git Status
    if q_lower.contains("git status") || q_lower.contains("status git") || q_lower.contains("cek git") {
        let status = crate::app_integrations::inspect_git_status(None);
        let reply = status.summary_markdown;
        chat.push(Turn {
            role: "assistant",
            text: reply.clone(),
            attachments: Vec::new(),
        });
        return Ok(ChatReply { text: reply });
    }

    // Docker Status & Management
    if q_lower.contains("cek docker") || q_lower.contains("status docker") || q_lower.contains("kontainer docker") || q_lower.contains("docker ps") {
        let docker = crate::app_integrations::inspect_docker();
        let reply = docker.summary_markdown;
        chat.push(Turn {
            role: "assistant",
            text: reply.clone(),
            attachments: Vec::new(),
        });
        return Ok(ChatReply { text: reply });
    }

    if q_lower.starts_with("restart kontainer ") || q_lower.starts_with("restart container ") {
        let id = query.trim_start_matches("restart kontainer ").trim_start_matches("restart container ").trim();
        let res = crate::app_integrations::manage_docker_container("restart", id);
        let reply = match res {
            Ok(msg) => msg,
            Err(err) => err,
        };
        chat.push(Turn {
            role: "assistant",
            text: reply.clone(),
            attachments: Vec::new(),
        });
        return Ok(ChatReply { text: reply });
    }

    if q_lower.starts_with("log kontainer ") || q_lower.starts_with("log container ") {
        let id = query.trim_start_matches("log kontainer ").trim_start_matches("log container ").trim();
        let res = crate::app_integrations::manage_docker_container("logs", id);
        let reply = match res {
            Ok(msg) => msg,
            Err(err) => err,
        };
        chat.push(Turn {
            role: "assistant",
            text: reply.clone(),
            attachments: Vec::new(),
        });
        return Ok(ChatReply { text: reply });
    }

    let memory_context = crate::memory::format_for_system_prompt();
    let full_system_prompt = format!("{SYSTEM_PROMPT}{memory_context}");

    let answer = match providers::complete(
        provider,
        key.as_deref(),
        model,
        local_endpoint,
        &full_system_prompt,
        &chat.snapshot(),
    )
    .await
    {
        Ok(answer) => answer,
        Err(err) => {
            chat.pop(); // keep the history consistent with what the model saw
            return Err(err);
        }
    };

    chat.push(Turn {
        role: "assistant",
        text: answer.clone(),
        attachments: Vec::new(),
    });
    Ok(ChatReply { text: answer })
}

fn read_text(path: &str) -> Option<String> {
    let len = std::fs::metadata(path).ok()?.len();
    if len > MAX_INLINE_TEXT {
        return None;
    }
    std::fs::read_to_string(path).ok()
}

/// PDF → document attachment, image → image attachment, text/code → inline
/// text on the turn. Mirrors readFileAsBlock() in ClaudeService.swift.
fn file_attachment(path: &str) -> Option<Attachment> {
    let ext = std::path::Path::new(path)
        .extension()
        .and_then(|e| e.to_str())
        .unwrap_or("")
        .to_lowercase();

    let media_type = match ext.as_str() {
        "pdf" => Some(("document", "application/pdf")),
        "jpg" | "jpeg" => Some(("image", "image/jpeg")),
        "png" => Some(("image", "image/png")),
        "gif" => Some(("image", "image/gif")),
        "webp" => Some(("image", "image/webp")),
        _ => None,
    };

    let (kind, media) = media_type?;
    let bytes = std::fs::read(path).ok()?;
    let data = base64(&bytes);
    Some(if kind == "image" {
        Attachment::Image {
            media_type: media.to_string(),
            data,
        }
    } else {
        Attachment::Document {
            media_type: media.to_string(),
            data,
        }
    })
}

/// Small standalone base64 encoder — not worth another dependency.
/// Also used for Stripe's basic auth.
pub(crate) fn base64_for(bytes: &[u8]) -> String {
    base64(bytes)
}

fn base64(bytes: &[u8]) -> String {
    const TABLE: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        let b = [
            chunk[0],
            *chunk.get(1).unwrap_or(&0),
            *chunk.get(2).unwrap_or(&0),
        ];
        let n = ((b[0] as u32) << 16) | ((b[1] as u32) << 8) | b[2] as u32;
        out.push(TABLE[(n >> 18) as usize & 63] as char);
        out.push(TABLE[(n >> 12) as usize & 63] as char);
        out.push(if chunk.len() > 1 {
            TABLE[(n >> 6) as usize & 63] as char
        } else {
            '='
        });
        out.push(if chunk.len() > 2 {
            TABLE[n as usize & 63] as char
        } else {
            '='
        });
    }
    out
}

#[cfg(test)]
mod tests {
    use super::base64;

    #[test]
    fn base64_matches_rfc4648_vectors() {
        assert_eq!(base64(b""), "");
        assert_eq!(base64(b"f"), "Zg==");
        assert_eq!(base64(b"fo"), "Zm8=");
        assert_eq!(base64(b"foo"), "Zm9v");
        assert_eq!(base64(b"foob"), "Zm9vYg==");
        assert_eq!(base64(b"fooba"), "Zm9vYmE=");
        assert_eq!(base64(b"foobar"), "Zm9vYmFy");
    }

    #[test]
    fn the_default_model_belongs_to_anthropic() {
        assert!(crate::providers::ANTHROPIC_MODELS
            .iter()
            .any(|(id, _)| *id == crate::providers::Provider::Anthropic.default_model()));
    }
}
