// Preferences, stored as plain JSON in %APPDATA%\Coucou\settings.json.
// No secret ever lands here — API keys live in the Windows Credential Manager.

use serde::{Deserialize, Serialize};
use std::path::PathBuf;

use crate::launchers;
use crate::providers;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Settings {
    pub sound_enabled: bool,
    pub sound_volume: f64,
    pub auto_close_interval: f64,
    pub absence_interval: f64,
    pub active_integrations: Vec<String>,
    /// "primary" = the main display, "cursor" = whichever display the mouse is on.
    pub screen: String,
    pub autostart: bool,
    pub hooks_installed: bool,
    /// Provider selected in Settings: anthropic, openai, gemini, groq or local_mlx.
    /// Defaulted explicitly so a settings.json written by an older build still loads.
    #[serde(default = "default_provider")]
    pub provider: String,
    /// Model used by the chat. Empty values fall back to the provider's default;
    /// a dynamic model id chosen from the live list is kept as-is.
    #[serde(default = "default_model")]
    pub model: String,
    /// OpenAI-compatible base URL for the local provider (Ollama, LM Studio, MLX).
    /// Not a secret: it is only ever a URL, never a token.
    #[serde(default = "default_local_endpoint")]
    pub local_endpoint: String,
    /// Editor opened by "Open in editor" on a Claude Code task. One of the ids
    /// in `launchers::EDITORS`; anything else is repaired to "auto".
    #[serde(default = "default_launcher")]
    pub preferred_editor: String,
    /// Terminal opened by "Open terminal". One of `launchers::TERMINALS`.
    #[serde(default = "default_launcher")]
    pub preferred_terminal: String,
    /// False until the first-run welcome card is finished or skipped, so the
    /// settings window opens once on a fresh install.
    #[serde(default)]
    pub onboarded: bool,
    /// Ask GitHub Releases for a newer version when Settings opens. Only the
    /// update manifest is fetched; installing is always an explicit click.
    #[serde(default = "default_auto_check_updates")]
    pub auto_check_updates: bool,
}

fn default_auto_check_updates() -> bool {
    true
}

fn default_provider() -> String {
    providers::DEFAULT_PROVIDER.to_string()
}

fn default_model() -> String {
    providers::resolve(providers::DEFAULT_PROVIDER)
        .default_model()
        .to_string()
}

fn default_local_endpoint() -> String {
    providers::DEFAULT_LOCAL_ENDPOINT.to_string()
}

fn default_launcher() -> String {
    "auto".to_string()
}

impl Settings {
    /// Repairs values a hand-edited file (or an older build) may have left in an
    /// unusable state. Never fails: the app always boots with a working chat.
    pub fn normalized(mut self) -> Self {
        let provider = providers::resolve(&self.provider);
        self.provider = provider.id().to_string();
        if self.model.trim().is_empty() {
            self.model = provider.default_model().to_string();
        } else {
            self.model = self.model.trim().to_string();
        }
        self.local_endpoint = providers::normalize_local_endpoint(&self.local_endpoint);
        self.preferred_editor = launchers::normalize_editor(&self.preferred_editor);
        self.preferred_terminal = launchers::normalize_terminal(&self.preferred_terminal);
        self
    }
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            sound_enabled: true,
            sound_volume: 0.12,
            auto_close_interval: 15.0,
            absence_interval: 180.0,
            active_integrations: vec![
                "integration_resend".into(),
                "integration_n8n".into(),
                "integration_vercel".into(),
                "integration_github".into(),
            ],
            screen: "primary".into(),
            autostart: false,
            hooks_installed: false,
            provider: default_provider(),
            model: default_model(),
            local_endpoint: default_local_endpoint(),
            preferred_editor: default_launcher(),
            preferred_terminal: default_launcher(),
            onboarded: false,
            auto_check_updates: default_auto_check_updates(),
        }
    }
}

/// %APPDATA%\Coucou
pub fn config_dir() -> PathBuf {
    let base = std::env::var_os("APPDATA")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("."));
    base.join("Coucou")
}

/// %LOCALAPPDATA%\Coucou — where coucou-hook.exe and the log live.
pub fn local_dir() -> PathBuf {
    let base = std::env::var_os("LOCALAPPDATA")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("."));
    base.join("Coucou")
}

pub fn hook_exe_path() -> PathBuf {
    local_dir().join("bin").join("coucou-hook.exe")
}

fn settings_path() -> PathBuf {
    config_dir().join("settings.json")
}

pub fn load() -> Settings {
    match std::fs::read(settings_path()) {
        Ok(bytes) => serde_json::from_slice::<Settings>(&bytes)
            .map(Settings::normalized)
            .unwrap_or_default(),
        Err(_) => Settings::default(),
    }
}

pub fn save(settings: &Settings) -> std::io::Result<()> {
    let dir = config_dir();
    std::fs::create_dir_all(&dir)?;
    let json = serde_json::to_vec_pretty(&settings.clone().normalized())
        .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e))?;
    std::fs::write(settings_path(), json)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn defaults_are_in_range_and_use_the_shared_model_constant() {
        let s = Settings::default();
        assert!(s.sound_enabled);
        assert!(
            (0.0..=0.2).contains(&s.sound_volume),
            "volume must match the slider range"
        );
        assert!(s.auto_close_interval > 0.0);
        assert!(s.absence_interval > 0.0);
        assert_eq!(s.provider, crate::providers::DEFAULT_PROVIDER);
        assert_eq!(
            s.model,
            crate::providers::Provider::Anthropic.default_model()
        );
        assert_eq!(s.local_endpoint, crate::providers::DEFAULT_LOCAL_ENDPOINT);
        assert_eq!(s.preferred_editor, "auto");
        assert_eq!(s.preferred_terminal, "auto");
        assert!(!s.onboarded);
        assert!(s.auto_check_updates);
        assert_eq!(s.screen, "primary");
        assert!(s.active_integrations.len() <= 4);
    }

    #[test]
    fn serialises_with_camel_case_and_never_with_a_secret() {
        let json = serde_json::to_value(Settings::default()).unwrap();
        for field in [
            "soundEnabled",
            "soundVolume",
            "autoCloseInterval",
            "activeIntegrations",
            "hooksInstalled",
            "provider",
            "model",
            "localEndpoint",
            "preferredEditor",
            "preferredTerminal",
            "onboarded",
            "autoCheckUpdates",
        ] {
            assert!(json.get(field).is_some(), "missing {field}");
        }
        let text = json.to_string().to_lowercase();
        for secret in ["apikey", "api_key", "token", "password", "secret"] {
            assert!(
                !text.contains(secret),
                "settings.json must never carry {secret}"
            );
        }
    }

    #[test]
    fn an_older_settings_file_without_model_still_loads() {
        let legacy = serde_json::json!({
            "soundEnabled": false,
            "soundVolume": 0.05,
            "autoCloseInterval": 10.0,
            "absenceInterval": 60.0,
            "activeIntegrations": ["integration_n8n"],
            "screen": "cursor",
            "autostart": true,
            "hooksInstalled": true
        });
        let parsed: Settings = serde_json::from_value(legacy).expect("must stay compatible");
        assert_eq!(parsed.provider, crate::providers::DEFAULT_PROVIDER);
        assert_eq!(
            parsed.model,
            crate::providers::Provider::Anthropic.default_model()
        );
        assert_eq!(
            parsed.local_endpoint,
            crate::providers::DEFAULT_LOCAL_ENDPOINT
        );
        assert_eq!(parsed.preferred_editor, "auto");
        assert_eq!(parsed.preferred_terminal, "auto");
        assert!(
            !parsed.onboarded,
            "an upgrade must see the welcome card once"
        );
        assert!(
            parsed.auto_check_updates,
            "an older file opts into the update check by default"
        );
        assert!(!parsed.sound_enabled);
        assert_eq!(parsed.screen, "cursor");
    }

    #[test]
    fn garbage_provider_and_endpoint_are_repaired_on_load() {
        let broken = serde_json::json!({
            "provider": "not-a-provider",
            "model": "   ",
            "localEndpoint": "file:///C:/Windows/System32/calc.exe",
            "preferredEditor": "calc.exe",
            "preferredTerminal": "cmd /C calc",
            "onboarded": true,
            "soundEnabled": true,
            "soundVolume": 0.12,
            "autoCloseInterval": 15.0,
            "absenceInterval": 180.0,
            "activeIntegrations": [],
            "screen": "primary",
            "autostart": false,
            "hooksInstalled": false
        });
        let parsed: Settings = serde_json::from_value::<Settings>(broken)
            .expect("must stay compatible")
            .normalized();
        assert_eq!(parsed.provider, crate::providers::DEFAULT_PROVIDER);
        assert_eq!(
            parsed.model,
            crate::providers::Provider::Anthropic.default_model()
        );
        assert_eq!(
            parsed.local_endpoint,
            crate::providers::DEFAULT_LOCAL_ENDPOINT
        );
        assert_eq!(parsed.preferred_editor, "auto");
        assert_eq!(parsed.preferred_terminal, "auto");
        assert!(parsed.onboarded, "a stored true must survive");
    }

    /// One filesystem test, because APPDATA is process-wide.
    #[test]
    fn saves_atomically_enough_for_a_restart_and_recovers_from_garbage() {
        let tmp = std::env::temp_dir().join(format!("coucou-settings-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&tmp);
        std::fs::create_dir_all(&tmp).unwrap();
        std::env::set_var("APPDATA", &tmp);

        assert!(
            config_dir().starts_with(&tmp),
            "the test must not touch the real profile"
        );
        assert_eq!(
            load().model,
            Settings::default().model,
            "missing file means defaults"
        );

        let settings = Settings {
            sound_enabled: false,
            provider: "openai".into(),
            model: "gpt-6.1-sol".into(),
            local_endpoint: "http://localhost:1234/v1/".into(),
            preferred_editor: "cursor".into(),
            preferred_terminal: "pwsh".into(),
            onboarded: true,
            screen: "cursor".into(),
            active_integrations: vec!["integration_n8n".into()],
            ..Settings::default()
        };
        save(&settings).unwrap();

        let loaded = load();
        assert!(!loaded.sound_enabled);
        assert_eq!(loaded.provider, "openai");
        assert_eq!(loaded.model, "gpt-6.1-sol");
        assert_eq!(loaded.local_endpoint, "http://localhost:1234/v1");
        assert_eq!(loaded.preferred_editor, "cursor");
        assert_eq!(loaded.preferred_terminal, "pwsh");
        assert!(loaded.onboarded);
        assert_eq!(loaded.screen, "cursor");
        assert_eq!(
            loaded.active_integrations,
            vec!["integration_n8n".to_string()]
        );

        // A half-written or hand-edited file must not take the app down.
        std::fs::write(settings_path(), b"{ not json").unwrap();
        assert_eq!(load().model, Settings::default().model);
        assert_eq!(load().provider, Settings::default().provider);

        let _ = std::fs::remove_dir_all(&tmp);
    }
}
