use serde::{Deserialize, Serialize};

// Same file as the Mac app's config.json: a missing key takes its default, a key
// of the wrong type is an error, unknown keys are ignored. Fields stay in
// alphabetical order so the file is written with sorted keys.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct Config {
    pub auto_paste: bool,
    pub context: String,
    pub cursor_context: bool,
    pub hotkey: String,
    pub language_hints: Vec<String>,
    pub launch_at_login: bool,
    pub model: String,
    pub notch_minimized: bool,
    pub onboarded: bool,
    pub restore_clipboard: bool,
    pub save_history: bool,
    pub silence_stop_ms: f64,
    pub translate_to: String,

    // Per session, never saved.
    #[serde(skip)]
    pub label_speakers: bool,
}

pub const DEFAULT_HOTKEY: &str = "Control+Shift+Space";

impl Default for Config {
    fn default() -> Self {
        Self {
            auto_paste: true,
            context: String::new(),
            cursor_context: true,
            hotkey: DEFAULT_HOTKEY.into(),
            language_hints: vec!["en".into()],
            launch_at_login: true,
            model: "stt-rt-v6".into(),
            notch_minimized: false,
            onboarded: false,
            restore_clipboard: false,
            save_history: true,
            silence_stop_ms: 0.0,
            translate_to: String::new(),
            label_speakers: false,
        }
    }
}

impl Config {
    /// Context terms, separated by commas or lines.
    pub fn terms(&self) -> Vec<String> {
        self.context
            .split([',', '\n'])
            .map(str::trim)
            .filter(|term| !term.is_empty())
            .map(String::from)
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn decode(json: &str) -> serde_json::Result<Config> {
        serde_json::from_str(json)
    }

    #[test]
    fn drops_unknown_and_retired_keys() {
        let config = decode(r#"{"hotkey":"Control+K","apiKeyEnc":"aabb","trigger":"DoubleCommand","cleanupEnabled":true}"#).unwrap();
        assert_eq!(config.hotkey, "Control+K");
        assert_eq!(Config { hotkey: DEFAULT_HOTKEY.into(), ..config }, Config::default());
    }

    #[test]
    fn missing_keys_get_defaults() {
        let config = decode("{}").unwrap();
        assert_eq!(config, Config::default());
        assert_eq!(config.model, "stt-rt-v6");
        assert_eq!(config.language_hints, ["en"]);
        assert!(!config.onboarded);
    }

    #[test]
    fn reads_a_mac_config() {
        let config = decode(
            r#"{"autoPaste":false,"context":"ENKI","cursorContext":true,"hotkey":"Option+Space","languageHints":["sl","en"],
                "launchAtLogin":true,"model":"stt-rt-v6","notchMinimized":true,"restoreClipboard":true,"saveHistory":true,
                "silenceStopMs":1500,"translateTo":""}"#,
        )
        .unwrap();
        assert!(!config.auto_paste);
        assert_eq!(config.language_hints, ["sl", "en"]);
        assert_eq!(config.silence_stop_ms, 1500.0);
    }

    #[test]
    fn terms_split_on_commas_and_lines() {
        let config = Config { context: " ENKI, SOMA44 ,\nHONED,, ".into(), ..Config::default() };
        assert_eq!(config.terms(), ["ENKI", "SOMA44", "HONED"]);
    }

    #[test]
    fn type_mismatch_is_an_error() {
        assert!(decode(r#"{"hotkey":123}"#).is_err());
        assert!(decode(r#"{"languageHints":"en"}"#).is_err());
        assert!(decode("[1,2]").is_err());
    }

    #[test]
    fn encoding_omits_session_fields_and_round_trips() {
        let config = Config { label_speakers: true, ..Config::default() };
        let value = serde_json::to_value(&config).unwrap();
        assert!(value.get("labelSpeakers").is_none());
        assert!(value.get("apiKey").is_none());
        assert_eq!(value["hotkey"], DEFAULT_HOTKEY);
        assert_eq!(serde_json::from_value::<Config>(value).unwrap(), Config::default());
    }
}
