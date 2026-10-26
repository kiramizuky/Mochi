// AI provider registry: Anthropic, OpenAI, Gemini, Groq and a local
// OpenAI-compatible server (Ollama, LM Studio, MLX).
//
// Requests and responses live in Rust so an API key never crosses the IPC
// boundary. The front end only ever learns whether a key exists, which models a
// provider offers, and the assistant's reply.

use std::time::Duration;

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

pub const ANTHROPIC_ENDPOINT: &str = "https://api.anthropic.com/v1/messages";
const ANTHROPIC_MODELS_ENDPOINT: &str = "https://api.anthropic.com/v1/models?limit=100";
const ANTHROPIC_VERSION: &str = "2023-06-01";
/// Server-side fallback: on a policy decline the API retries the same request on
/// a fallback model inside the same call, so the island never shows a dead end.
const FALLBACK_BETA: &str = "server-side-fallback-2026-07-01";
const OPENAI_ENDPOINT: &str = "https://api.openai.com/v1/chat/completions";
const OPENAI_MODELS_ENDPOINT: &str = "https://api.openai.com/v1/models";
const GROQ_ENDPOINT: &str = "https://api.groq.com/openai/v1/chat/completions";
const GROQ_MODELS_ENDPOINT: &str = "https://api.groq.com/openai/v1/models";
const GEMINI_BASE: &str = "https://generativelanguage.googleapis.com/v1beta";

const MAX_TOKENS: u32 = 4096;
const MAX_MODELS: usize = 100;
const NETWORK_TIMEOUT: Duration = Duration::from_secs(90);
const MODELS_TIMEOUT: Duration = Duration::from_secs(10);

pub const DEFAULT_PROVIDER: &str = "anthropic";
pub const DEFAULT_LOCAL_ENDPOINT: &str = "http://127.0.0.1:11434/v1";

/// Anthropic models offered before the live list arrives (or when it cannot).
pub const ANTHROPIC_MODELS: &[(&str, &str)] = &[
    ("claude-opus-5", "Claude Opus 5"),
    ("claude-sonnet-5", "Claude Sonnet 5"),
    ("claude-haiku-4-5", "Claude Haiku 4.5"),
    ("claude-sonnet-4-6", "Claude Sonnet 4.6"),
];

const OPENAI_MODELS: &[(&str, &str)] = &[
    ("gpt-6.1-sol", "GPT-6.1 Sol"),
    ("gpt-6-astra", "GPT-6 Astra"),
    ("gpt-6-sol", "GPT-6 Sol"),
    ("gpt-6-luna", "GPT-6 Luna"),
    ("gpt-5.6-terra", "GPT-5.6 Terra"),
];

const GEMINI_MODELS: &[(&str, &str)] = &[
    ("gemini-3.6-flash", "Gemini 3.6 Flash"),
    ("gemini-3.5-flash-lite", "Gemini 3.5 Flash Lite"),
    ("gemini-3.1-flash-lite", "Gemini 3.1 Flash Lite"),
    ("gemini-3.1-pro-preview", "Gemini 3.1 Pro (preview)"),
    ("gemini-2.5-flash", "Gemini 2.5 Flash"),
];

const GROQ_MODELS: &[(&str, &str)] = &[
    ("openai/gpt-oss-120b", "GPT-OSS 120B (Groq)"),
    ("qwen/qwen3.8-27b", "Qwen 3.8 27B (Groq)"),
    ("openai/gpt-oss-20b", "GPT-OSS 20B (Groq)"),
    ("allam-2-7b", "ALLaM 2 7B (Groq)"),
    ("llama-3.3-70b-versatile", "Llama 3.3 70B Versatile"),
    ("llama-3.1-8b-instant", "Llama 3.1 8B Instant"),
];

const LOCAL_MODELS: &[(&str, &str)] = &[
    ("qwen2.5:7b", "Qwen 2.5 7B (Recommended)"),
    ("llama3.2:3b", "Llama 3.2 3B (Fast)"),
    ("deepseek-r1:7b", "DeepSeek R1 7B (Reasoning)"),
    ("mistral:7b", "Mistral 7B"),
];

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Provider {
    Anthropic,
    OpenAi,
    Gemini,
    Groq,
    Local,
}

impl Provider {
    pub fn from_id(id: &str) -> Option<Self> {
        match id {
            "anthropic" => Some(Self::Anthropic),
            "openai" => Some(Self::OpenAi),
            "gemini" => Some(Self::Gemini),
            "groq" => Some(Self::Groq),
            "local_mlx" => Some(Self::Local),
            _ => None,
        }
    }

    pub fn id(self) -> &'static str {
        match self {
            Self::Anthropic => "anthropic",
            Self::OpenAi => "openai",
            Self::Gemini => "gemini",
            Self::Groq => "groq",
            Self::Local => "local_mlx",
        }
    }

    pub fn name(self) -> &'static str {
        match self {
            Self::Anthropic => "Anthropic",
            Self::OpenAi => "OpenAI",
            Self::Gemini => "Google Gemini",
            Self::Groq => "Groq",
            Self::Local => "Local model",
        }
    }

    pub fn default_model(self) -> &'static str {
        self.models()[0].0
    }

    pub fn models(self) -> &'static [(&'static str, &'static str)] {
        match self {
            Self::Anthropic => ANTHROPIC_MODELS,
            Self::OpenAi => OPENAI_MODELS,
            Self::Gemini => GEMINI_MODELS,
            Self::Groq => GROQ_MODELS,
            Self::Local => LOCAL_MODELS,
        }
    }

    pub fn key_name(self) -> &'static str {
        match self {
            Self::Anthropic => "anthropic-api-key",
            Self::OpenAi => "openai-api-key",
            Self::Gemini => "gemini-api-key",
            Self::Groq => "groq-api-key",
            Self::Local => "local-api-key",
        }
    }

    pub fn key_placeholder(self) -> &'static str {
        match self {
            Self::Anthropic => "sk-ant-…",
            Self::OpenAi => "sk-…",
            Self::Gemini => "AIza…",
            Self::Groq => "gsk_…",
            Self::Local => "optional",
        }
    }

    /// A local server may be unauthenticated; every hosted provider needs a key.
    pub fn requires_key(self) -> bool {
        self != Self::Local
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct ModelOption {
    pub id: String,
    pub label: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProviderInfo {
    pub id: &'static str,
    pub name: &'static str,
    pub default_model: &'static str,
    pub models: Vec<ModelOption>,
    pub key_name: &'static str,
    pub key_placeholder: &'static str,
    pub requires_key: bool,
    pub is_local: bool,
}

/// The selector's catalogue. The front end gets labels and key names only —
/// never a key value.
pub fn catalog() -> Vec<ProviderInfo> {
    [
        Provider::Anthropic,
        Provider::OpenAi,
        Provider::Gemini,
        Provider::Groq,
        Provider::Local,
    ]
    .into_iter()
    .map(|provider| ProviderInfo {
        id: provider.id(),
        name: provider.name(),
        default_model: provider.default_model(),
        models: static_models(provider),
        key_name: provider.key_name(),
        key_placeholder: provider.key_placeholder(),
        requires_key: provider.requires_key(),
        is_local: provider == Provider::Local,
    })
    .collect()
}

pub fn resolve(id: &str) -> Provider {
    Provider::from_id(id).unwrap_or(Provider::Anthropic)
}

/// Keeps a hand-edited settings.json from pointing the local client at a
/// non-HTTP scheme. Empty or malformed values fall back to the default.
pub fn normalize_local_endpoint(value: &str) -> String {
    let trimmed = value.trim().trim_end_matches('/');
    if trimmed.is_empty() {
        return DEFAULT_LOCAL_ENDPOINT.to_string();
    }
    match url::Url::parse(trimmed) {
        Ok(url) if matches!(url.scheme(), "http" | "https") && url.host_str().is_some() => {
            trimmed.to_string()
        }
        _ => DEFAULT_LOCAL_ENDPOINT.to_string(),
    }
}

// ── Chat request shapes ───────────────────────────────────────────────────────

#[derive(Debug, Clone)]
pub struct Turn {
    pub role: &'static str,
    pub text: String,
    pub attachments: Vec<Attachment>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Attachment {
    Image { media_type: String, data: String },
    Document { media_type: String, data: String },
}

/// One chat turn against the selected provider. Returns the assistant text.
pub async fn complete(
    provider: Provider,
    key: Option<&str>,
    model: &str,
    local_endpoint: &str,
    system: &str,
    turns: &[Turn],
) -> Result<String, String> {
    if provider.requires_key() && key.is_none() {
        return Err(format!(
            "{} API key missing. Open Settings.",
            provider.name()
        ));
    }

    match provider {
        Provider::Anthropic => {
            let key = key.ok_or_else(|| "Anthropic API key missing. Open Settings.".to_string())?;
            let body = anthropic_body(model, system, turns);
            let response = post_json(
                ANTHROPIC_ENDPOINT,
                &[
                    ("x-api-key", key),
                    ("anthropic-version", ANTHROPIC_VERSION),
                    ("anthropic-beta", FALLBACK_BETA),
                ],
                &body,
                provider,
            )
            .await?;
            anthropic_text(&response)
        }
        Provider::OpenAi | Provider::Groq | Provider::Local => {
            let endpoint = match provider {
                Provider::OpenAi => OPENAI_ENDPOINT.to_string(),
                Provider::Groq => GROQ_ENDPOINT.to_string(),
                _ => format!(
                    "{}/chat/completions",
                    normalize_local_endpoint(local_endpoint)
                ),
            };
            let body = openai_body(provider, model, system, turns);
            let bearer = key.map(|key| format!("Bearer {key}"));
            let headers: Vec<(&str, &str)> = match bearer.as_deref() {
                Some(value) => vec![("authorization", value)],
                None => Vec::new(),
            };
            let response = post_json(&endpoint, &headers, &body, provider).await?;
            openai_text(&response, provider)
        }
        Provider::Gemini => {
            let key = key.ok_or_else(|| "Gemini API key missing. Open Settings.".to_string())?;
            let endpoint = format!(
                "{GEMINI_BASE}/models/{}:generateContent",
                percent_encode(model)
            );
            let body = gemini_body(model, system, turns);
            let response =
                post_json(&endpoint, &[("x-goog-api-key", key)], &body, provider).await?;
            gemini_text(&response)
        }
    }
}

pub fn anthropic_body(model: &str, system: &str, turns: &[Turn]) -> Value {
    let messages: Vec<Value> = turns
        .iter()
        .map(|turn| json!({ "role": turn.role, "content": anthropic_content(turn) }))
        .collect();
    json!({
        "model": model,
        "max_tokens": MAX_TOKENS,
        "system": system,
        "tools": [{ "type": "web_search_20260209", "name": "web_search", "max_uses": 5 }],
        "fallbacks": "default",
        "messages": messages,
    })
}

fn anthropic_content(turn: &Turn) -> Value {
    let mut blocks: Vec<Value> = turn.attachments.iter().map(anthropic_attachment).collect();
    blocks.push(json!({ "type": "text", "text": turn.text }));
    Value::Array(blocks)
}

fn anthropic_attachment(attachment: &Attachment) -> Value {
    match attachment {
        Attachment::Image { media_type, data } => json!({
            "type": "image",
            "source": { "type": "base64", "media_type": media_type, "data": data },
        }),
        Attachment::Document { media_type, data } => json!({
            "type": "document",
            "source": { "type": "base64", "media_type": media_type, "data": data },
        }),
    }
}

pub fn openai_body(provider: Provider, model: &str, system: &str, turns: &[Turn]) -> Value {
    let mut messages = vec![json!({ "role": "system", "content": system })];
    for turn in turns {
        messages.push(openai_message(turn));
    }
    let mut body = json!({ "model": model, "messages": messages });
    // OpenAI's newer models reject `max_tokens`; the compatible servers still
    // use it. Keeping them separate avoids a provider-specific retry.
    if provider == Provider::OpenAi {
        body["max_completion_tokens"] = json!(MAX_TOKENS);
    } else {
        body["max_tokens"] = json!(MAX_TOKENS);
    }
    body
}

fn openai_message(turn: &Turn) -> Value {
    if turn.attachments.is_empty() {
        return json!({ "role": turn.role, "content": turn.text });
    }
    let mut parts = vec![json!({ "type": "text", "text": turn.text })];
    for attachment in &turn.attachments {
        match attachment {
            Attachment::Image { media_type, data } => parts.push(json!({
                "type": "image_url",
                "image_url": { "url": format!("data:{media_type};base64,{data}") },
            })),
            // Chat Completions cannot take a PDF. Say so instead of sending
            // bytes the model would never see.
            Attachment::Document { .. } => parts.push(json!({
                "type": "text",
                "text": "[Attached PDF omitted: this provider cannot read PDFs.]",
            })),
        }
    }
    json!({ "role": turn.role, "content": parts })
}

pub fn gemini_body(_model: &str, system: &str, turns: &[Turn]) -> Value {
    let contents: Vec<Value> = turns
        .iter()
        .map(|turn| {
            let role = if turn.role == "assistant" {
                "model"
            } else {
                "user"
            };
            json!({ "role": role, "parts": gemini_parts(turn) })
        })
        .collect();
    json!({
        "system_instruction": { "parts": [{ "text": system }] },
        "contents": contents,
        "generationConfig": { "maxOutputTokens": MAX_TOKENS },
    })
}

fn gemini_parts(turn: &Turn) -> Vec<Value> {
    let mut parts = Vec::with_capacity(turn.attachments.len() + 1);
    for attachment in &turn.attachments {
        match attachment {
            Attachment::Image { media_type, data } | Attachment::Document { media_type, data } => {
                parts.push(json!({
                    "inline_data": { "mime_type": media_type, "data": data },
                }));
            }
        }
    }
    parts.push(json!({ "text": turn.text }));
    parts
}

// ── Response shapes ───────────────────────────────────────────────────────────

fn anthropic_text(response: &Value) -> Result<String, String> {
    if response.get("stop_reason").and_then(Value::as_str) == Some("refusal") {
        let why = response
            .get("stop_details")
            .and_then(|d| d.get("explanation"))
            .and_then(Value::as_str)
            .unwrap_or("Claude declined this one.");
        return Err(why.to_string());
    }
    let blocks = response
        .get("content")
        .and_then(Value::as_array)
        .ok_or_else(|| "Unexpected response from Anthropic.".to_string())?;
    let text = blocks
        .iter()
        .filter(|b| b.get("type").and_then(Value::as_str) == Some("text"))
        .filter_map(|b| b.get("text").and_then(Value::as_str))
        .collect::<Vec<_>>()
        .join("\n")
        .trim()
        .to_string();
    non_empty(text, "Anthropic")
}

fn openai_text(response: &Value, provider: Provider) -> Result<String, String> {
    let choice = response
        .get("choices")
        .and_then(Value::as_array)
        .and_then(|choices| choices.first())
        .ok_or_else(|| format!("Unexpected response from {}.", provider.name()))?;

    let message = choice.get("message");
    if let Some(refusal) = message
        .and_then(|m| m.get("refusal"))
        .and_then(Value::as_str)
        .filter(|s| !s.trim().is_empty())
    {
        return Err(refusal.to_string());
    }

    let text = match message.and_then(|m| m.get("content")) {
        Some(Value::String(text)) => text.clone(),
        Some(Value::Array(parts)) => parts
            .iter()
            .filter_map(|part| part.get("text").and_then(Value::as_str))
            .collect::<Vec<_>>()
            .join("\n"),
        _ => choice
            .get("text")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string(),
    };
    non_empty(text.trim().to_string(), provider.name())
}

fn gemini_text(response: &Value) -> Result<String, String> {
    if let Some(reason) = response
        .pointer("/promptFeedback/blockReason")
        .and_then(Value::as_str)
    {
        return Err(format!("Gemini blocked the request ({reason})."));
    }
    let parts = response
        .pointer("/candidates/0/content/parts")
        .and_then(Value::as_array)
        .ok_or_else(|| "Unexpected response from Google Gemini.".to_string())?;
    let text = parts
        .iter()
        .filter_map(|part| part.get("text").and_then(Value::as_str))
        .collect::<Vec<_>>()
        .join("\n")
        .trim()
        .to_string();
    non_empty(text, "Google Gemini")
}

fn non_empty(text: String, provider: &str) -> Result<String, String> {
    if text.is_empty() {
        Err(format!("{provider} returned no text."))
    } else {
        Ok(text)
    }
}

// ── Model discovery ───────────────────────────────────────────────────────────

pub fn static_models(provider: Provider) -> Vec<ModelOption> {
    provider
        .models()
        .iter()
        .map(|(id, label)| ModelOption {
            id: (*id).to_string(),
            label: (*label).to_string(),
        })
        .collect()
}

/// Live model list, with the static catalogue as a guaranteed fallback. A
/// missing key, a network failure or an unexpected payload never breaks the
/// selector.
pub async fn list_models(
    provider: Provider,
    key: Option<&str>,
    local_endpoint: &str,
) -> Vec<ModelOption> {
    let fallback = static_models(provider);
    if provider.requires_key() && key.is_none() {
        return fallback;
    }

    let fetched = match provider {
        Provider::Anthropic => {
            let Some(key) = key else { return fallback };
            get_json(
                ANTHROPIC_MODELS_ENDPOINT,
                &[("x-api-key", key), ("anthropic-version", ANTHROPIC_VERSION)],
            )
            .await
            .map(|value| parse_model_list(provider, &value))
        }
        Provider::OpenAi => {
            let Some(key) = key else { return fallback };
            let bearer = format!("Bearer {key}");
            get_json(OPENAI_MODELS_ENDPOINT, &[("authorization", &bearer)])
                .await
                .map(|value| parse_model_list(provider, &value))
        }
        Provider::Groq => {
            let Some(key) = key else { return fallback };
            let bearer = format!("Bearer {key}");
            get_json(GROQ_MODELS_ENDPOINT, &[("authorization", &bearer)])
                .await
                .map(|value| parse_model_list(provider, &value))
        }
        Provider::Gemini => {
            let Some(key) = key else { return fallback };
            get_json(
                &format!("{GEMINI_BASE}/models?pageSize=1000"),
                &[("x-goog-api-key", key)],
            )
            .await
            .map(|value| parse_model_list(provider, &value))
        }
        Provider::Local => {
            let base = normalize_local_endpoint(local_endpoint);
            let direct = get_json(&format!("{base}/models"), &[]).await;
            let parsed = direct
                .map(|value| parse_model_list(provider, &value))
                .unwrap_or_default();
            if !parsed.is_empty() {
                Some(parsed)
            } else {
                // Ollama's native endpoint is the fallback when the server does
                // not expose the OpenAI-compatible /v1/models route.
                let root = base.strip_suffix("/v1").unwrap_or(&base);
                get_json(&format!("{root}/api/tags"), &[])
                    .await
                    .map(|value| parse_ollama_models(&value))
            }
        }
    };

    match fetched {
        Some(models) if !models.is_empty() => models,
        _ => fallback,
    }
}

/// Pure parser, exposed for tests. Returns an empty list for an unrecognised
/// payload so the caller can fall back to the static catalogue.
pub fn parse_model_list(provider: Provider, value: &Value) -> Vec<ModelOption> {
    match provider {
        Provider::Anthropic => parse_anthropic_models(value),
        Provider::Gemini => parse_gemini_models(value),
        Provider::OpenAi => parse_openai_models(value),
        Provider::Groq => parse_groq_models(value),
        Provider::Local => parse_openai_models(value),
    }
}

fn parse_anthropic_models(value: &Value) -> Vec<ModelOption> {
    let Some(items) = value.get("data").and_then(Value::as_array) else {
        return Vec::new();
    };
    items
        .iter()
        .filter_map(|item| {
            let id = item.get("id").and_then(Value::as_str)?;
            let label = item
                .get("display_name")
                .and_then(Value::as_str)
                .unwrap_or(id);
            Some(ModelOption {
                id: id.to_string(),
                label: label.to_string(),
            })
        })
        .take(MAX_MODELS)
        .collect()
}

fn parse_openai_models(value: &Value) -> Vec<ModelOption> {
    const PREFIXES: &[&str] = &["gpt-", "o1", "o3", "o4", "o5"];
    const EXCLUDED: &[&str] = &[
        "embedding",
        "whisper",
        "tts",
        "dall-e",
        "image",
        "audio",
        "transcribe",
        "moderation",
        "realtime",
        "codex",
        "search",
        "transcript",
    ];
    let Some(items) = value.get("data").and_then(Value::as_array) else {
        return Vec::new();
    };
    let mut picked: Vec<(ModelOption, i64)> = items
        .iter()
        .filter_map(|item| {
            let id = item.get("id").and_then(Value::as_str)?;
            let lower = id.to_lowercase();
            if !PREFIXES.iter().any(|prefix| lower.starts_with(prefix)) {
                return None;
            }
            if EXCLUDED.iter().any(|needle| lower.contains(needle)) {
                return None;
            }
            let created = item.get("created").and_then(Value::as_i64).unwrap_or(0);
            Some((
                ModelOption {
                    id: id.to_string(),
                    label: id.to_string(),
                },
                created,
            ))
        })
        .collect();
    // Newest first, matching how OpenAI orders its own documentation.
    picked.sort_by_key(|a| std::cmp::Reverse(a.1));
    picked
        .into_iter()
        .take(MAX_MODELS)
        .map(|(model, _)| model)
        .collect()
}

fn parse_groq_models(value: &Value) -> Vec<ModelOption> {
    let Some(items) = value.get("data").and_then(Value::as_array) else {
        return Vec::new();
    };
    let mut picked: Vec<(ModelOption, i64)> = items
        .iter()
        .filter_map(|item| {
            let id = item.get("id").and_then(Value::as_str)?;
            let lower = id.to_lowercase();
            if ["whisper", "tts", "orpheus", "safeguard"]
                .iter()
                .any(|needle| lower.contains(needle))
            {
                return None;
            }
            let created = item.get("created").and_then(Value::as_i64).unwrap_or(0);
            Some((
                ModelOption {
                    id: id.to_string(),
                    label: id.to_string(),
                },
                created,
            ))
        })
        .collect();
    picked.sort_by_key(|a| std::cmp::Reverse(a.1));
    picked
        .into_iter()
        .take(MAX_MODELS)
        .map(|(model, _)| model)
        .collect()
}

fn parse_gemini_models(value: &Value) -> Vec<ModelOption> {
    let Some(items) = value.get("models").and_then(Value::as_array) else {
        return Vec::new();
    };
    items
        .iter()
        .filter_map(|item| {
            let raw = item.get("name").and_then(Value::as_str)?;
            let methods = item
                .get("supportedGenerationMethods")
                .and_then(Value::as_array)
                .map(|methods| methods.iter().filter_map(Value::as_str).collect::<Vec<_>>())
                .unwrap_or_default();
            if !methods.contains(&"generateContent") {
                return None;
            }
            let id = raw.strip_prefix("models/").unwrap_or(raw);
            if id.is_empty() {
                return None;
            }
            let label = item
                .get("displayName")
                .and_then(Value::as_str)
                .unwrap_or(id);
            Some(ModelOption {
                id: id.to_string(),
                label: label.to_string(),
            })
        })
        .take(MAX_MODELS)
        .collect()
}

fn parse_ollama_models(value: &Value) -> Vec<ModelOption> {
    let Some(items) = value.get("models").and_then(Value::as_array) else {
        return Vec::new();
    };
    items
        .iter()
        .filter_map(|item| {
            let id = item.get("name").and_then(Value::as_str)?;
            Some(ModelOption {
                id: id.to_string(),
                label: format!("Local: {id}"),
            })
        })
        .take(MAX_MODELS)
        .collect()
}

// ── HTTP helpers ──────────────────────────────────────────────────────────────

async fn post_json(
    url: &str,
    headers: &[(&str, &str)],
    body: &Value,
    provider: Provider,
) -> Result<Value, String> {
    let client = reqwest::Client::builder()
        .timeout(NETWORK_TIMEOUT)
        .build()
        .map_err(|e| e.to_string())?;
    let mut request = client.post(url).header("content-type", "application/json");
    for (name, value) in headers {
        request = request.header(*name, *value);
    }
    let response = request
        .json(body)
        .send()
        .await
        .map_err(|e| format!("Network error: {e}"))?;

    let status = response.status();
    let text = response.text().await.map_err(|e| e.to_string())?;
    if !status.is_success() {
        return Err(api_error(provider, status.as_u16(), &text));
    }
    serde_json::from_str(&text).map_err(|e| format!("Bad {} API response: {e}", provider.name()))
}

async fn get_json(url: &str, headers: &[(&str, &str)]) -> Option<Value> {
    let client = reqwest::Client::builder()
        .timeout(MODELS_TIMEOUT)
        .build()
        .ok()?;
    let mut request = client.get(url);
    for (name, value) in headers {
        request = request.header(*name, *value);
    }
    let response = request.send().await.ok()?;
    if !response.status().is_success() {
        return None;
    }
    response.json::<Value>().await.ok()
}

fn api_error(provider: Provider, status: u16, body: &str) -> String {
    if matches!(status, 401 | 403) {
        return format!(
            "{} rejected the API key. Open Settings and check it.",
            provider.name()
        );
    }
    if status == 429 {
        return format!(
            "{} is rate-limiting requests. Try again in a moment.",
            provider.name()
        );
    }
    let detail = error_detail(body);
    if detail.is_empty() {
        format!("{} API {status}.", provider.name())
    } else {
        format!("{} API {status}: {detail}", provider.name())
    }
}

/// The API's `error.message` when it sent one, otherwise a short excerpt.
/// The excerpt is capped so a broken gateway page cannot flood the island.
pub fn error_detail(body: &str) -> String {
    serde_json::from_str::<Value>(body)
        .ok()
        .and_then(|value| {
            value
                .get("error")
                .and_then(|error| error.get("message"))
                .and_then(Value::as_str)
                .map(str::to_string)
        })
        .unwrap_or_else(|| body.chars().take(200).collect())
}

/// Model ids are path segments for Gemini, so keep them from changing the URL.
fn percent_encode(value: &str) -> String {
    url::form_urlencoded::byte_serialize(value.as_bytes()).collect()
}

/// Every provider key name must exist in the Credential Manager allow-list.
#[cfg(test)]
pub fn key_names() -> Vec<&'static str> {
    [
        Provider::Anthropic,
        Provider::OpenAi,
        Provider::Gemini,
        Provider::Groq,
        Provider::Local,
    ]
    .into_iter()
    .map(Provider::key_name)
    .collect()
}

/// True when every provider has a Credential Manager slot. Used by tests.
#[cfg(test)]
pub fn keys_are_registered() -> bool {
    key_names()
        .into_iter()
        .all(|key| crate::secrets::KNOWN_KEYS.contains(&key))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn turn(text: &str) -> Turn {
        Turn {
            role: "user",
            text: text.to_string(),
            attachments: Vec::new(),
        }
    }

    #[test]
    fn every_provider_is_distinct_and_has_a_default_in_its_own_list() {
        let catalog = catalog();
        assert_eq!(catalog.len(), 5);
        let unique: std::collections::HashSet<_> = catalog.iter().map(|p| p.id).collect();
        assert_eq!(unique.len(), catalog.len(), "duplicate provider id");
        for info in &catalog {
            assert!(!info.models.is_empty(), "{} has no models", info.id);
            assert_eq!(info.models[0].id, info.default_model);
            assert_eq!(Provider::from_id(info.id).unwrap().id(), info.id);
            assert!(keys_are_registered(), "{} key is not registered", info.id);
        }
    }

    #[test]
    fn unknown_providers_fall_back_to_anthropic() {
        assert_eq!(resolve("nope"), Provider::Anthropic);
        assert_eq!(resolve(""), Provider::Anthropic);
        assert_eq!(resolve("openai"), Provider::OpenAi);
    }

    #[test]
    fn local_endpoint_falls_back_unless_it_is_an_absolute_http_url() {
        assert_eq!(
            normalize_local_endpoint("http://localhost:1234/v1/"),
            "http://localhost:1234/v1"
        );
        assert_eq!(
            normalize_local_endpoint("https://models.example.test/v1"),
            "https://models.example.test/v1"
        );
        for bad in [
            "",
            "   ",
            "file:///C:/model",
            "localhost:11434",
            "javascript:alert(1)",
        ] {
            assert_eq!(
                normalize_local_endpoint(bad),
                DEFAULT_LOCAL_ENDPOINT,
                "{bad}"
            );
        }
    }

    #[test]
    fn anthropic_body_keeps_web_search_and_inlines_attachments() {
        let mut turn = turn("What is in this?");
        turn.attachments.push(Attachment::Image {
            media_type: "image/png".into(),
            data: "AAAA".into(),
        });
        let body = anthropic_body("claude-opus-5", "system", &[turn]);
        assert_eq!(body["model"], "claude-opus-5");
        assert_eq!(body["max_tokens"], MAX_TOKENS);
        assert_eq!(body["tools"][0]["type"], "web_search_20260209");
        assert_eq!(body["messages"][0]["content"][0]["type"], "image");
        assert_eq!(
            body["messages"][0]["content"][0]["source"]["media_type"],
            "image/png"
        );
        assert_eq!(
            body["messages"][0]["content"][1]["text"],
            "What is in this?"
        );
    }

    #[test]
    fn openai_body_uses_the_right_token_field_and_image_part() {
        let mut turn = turn("Describe it");
        turn.attachments.push(Attachment::Image {
            media_type: "image/jpeg".into(),
            data: "BBBB".into(),
        });
        let openai = openai_body(Provider::OpenAi, "gpt-6.1-sol", "system", &[turn.clone()]);
        assert!(openai.get("max_completion_tokens").is_some());
        assert!(openai.get("max_tokens").is_none());
        assert_eq!(openai["messages"][0]["role"], "system");
        assert_eq!(
            openai["messages"][1]["content"][1]["image_url"]["url"],
            "data:image/jpeg;base64,BBBB"
        );

        let groq = openai_body(Provider::Groq, "openai/gpt-oss-120b", "system", &[turn]);
        assert!(groq.get("max_tokens").is_some());
        assert!(groq.get("max_completion_tokens").is_none());
    }

    #[test]
    fn gemini_body_uses_inline_data_and_model_roles() {
        let mut user = turn("Look");
        user.attachments.push(Attachment::Document {
            media_type: "application/pdf".into(),
            data: "CCCC".into(),
        });
        let assistant = Turn {
            role: "assistant",
            text: "Sure".into(),
            attachments: Vec::new(),
        };
        let body = gemini_body("gemini-3.6-flash", "system", &[user, assistant]);
        assert_eq!(body["contents"][0]["role"], "user");
        assert_eq!(
            body["contents"][0]["parts"][0]["inline_data"]["mime_type"],
            "application/pdf"
        );
        assert_eq!(body["contents"][1]["role"], "model");
        assert_eq!(body["generationConfig"]["maxOutputTokens"], MAX_TOKENS);
    }

    #[test]
    fn responses_are_extracted_and_refusals_are_errors() {
        let anthropic = json!({
            "stop_reason": "end_turn",
            "content": [
                { "type": "text", "text": "Hello" },
                { "type": "text", "text": "world" }
            ]
        });
        assert_eq!(anthropic_text(&anthropic).unwrap(), "Hello\nworld");

        let refusal = json!({
            "stop_reason": "refusal",
            "stop_details": { "explanation": "Not allowed." }
        });
        assert_eq!(anthropic_text(&refusal).unwrap_err(), "Not allowed.");

        let openai = json!({ "choices": [{ "message": { "content": "Hi" } }] });
        assert_eq!(openai_text(&openai, Provider::OpenAi).unwrap(), "Hi");
        let openai_parts = json!({
            "choices": [{ "message": { "content": [{ "type": "text", "text": "A" }, { "type": "text", "text": "B" }] } }]
        });
        assert_eq!(
            openai_text(&openai_parts, Provider::OpenAi).unwrap(),
            "A\nB"
        );

        let blocked = json!({ "promptFeedback": { "blockReason": "SAFETY" } });
        assert!(gemini_text(&blocked).unwrap_err().contains("SAFETY"));

        let gemini = json!({ "candidates": [{ "content": { "parts": [{ "text": "Hi" }] } }] });
        assert_eq!(gemini_text(&gemini).unwrap(), "Hi");
    }

    #[test]
    fn model_lists_are_filtered_and_stripped() {
        let openai = json!({ "data": [
            { "id": "gpt-6-sol", "created": 10 },
            { "id": "gpt-6-astra", "created": 20 },
            { "id": "text-embedding-3", "created": 30 },
            { "id": "whisper-1", "created": 40 }
        ]});
        let parsed = parse_model_list(Provider::OpenAi, &openai);
        assert_eq!(
            parsed.iter().map(|m| m.id.as_str()).collect::<Vec<_>>(),
            ["gpt-6-astra", "gpt-6-sol"]
        );

        let gemini = json!({ "models": [
            { "name": "models/gemini-3.6-flash", "displayName": "Gemini 3.6 Flash", "supportedGenerationMethods": ["generateContent"] },
            { "name": "models/embedding-001", "supportedGenerationMethods": ["embedContent"] }
        ]});
        let parsed = parse_model_list(Provider::Gemini, &gemini);
        assert_eq!(
            parsed,
            vec![ModelOption {
                id: "gemini-3.6-flash".into(),
                label: "Gemini 3.6 Flash".into()
            }]
        );

        let ollama = json!({ "models": [{ "name": "qwen2.5:7b" }] });
        assert_eq!(parse_ollama_models(&ollama)[0].id, "qwen2.5:7b");
        assert!(parse_model_list(Provider::Anthropic, &json!({ "nope": true })).is_empty());
    }

    #[test]
    fn errors_never_contain_the_api_key() {
        let key = "sk-ant-secret-value";
        let message = api_error(
            Provider::Anthropic,
            401,
            "{\"error\":{\"message\":\"invalid x-api-key\"}}",
        );
        assert!(!message.contains(key));
        assert!(message.contains("rejected the API key"));

        let message = api_error(Provider::OpenAi, 500, "gateway exploded");
        assert_eq!(message, "OpenAI API 500: gateway exploded");
    }

    #[test]
    fn error_detail_is_capped() {
        let html = "<html>".to_string() + &"x".repeat(2_000);
        assert_eq!(error_detail(&html).chars().count(), 200);
        assert_eq!(error_detail(""), "");
    }
}
