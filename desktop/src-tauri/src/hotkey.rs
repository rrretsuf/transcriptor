use std::str::FromStr;
use tauri_plugin_global_shortcut::{Modifiers, Shortcut};

// A hotkey is an accelerator like "Control+Shift+Space": modifiers first, one
// key last, the same form the Mac app writes to config.json. The Mac-only
// "tap:<modifier>:<count>" form and anything unreadable fall back to the default.

pub fn parse(hotkey: &str) -> Option<Shortcut> {
    Shortcut::from_str(hotkey).ok()
}

/// A dictation hotkey needs a modifier, or it would swallow typing. Function keys are fine alone.
pub fn usable(hotkey: &str) -> bool {
    let Some(shortcut) = parse(hotkey) else { return false };
    let key = hotkey.rsplit('+').next().unwrap_or_default().trim().to_uppercase();
    let function_key = key.len() > 1 && key.starts_with('F') && key[1..].chars().all(|c| c.is_ascii_digit());
    !shortcut.mods.is_empty() || function_key
}

/// "Control+Shift+Space" → "Ctrl + Shift + Space", with the key names of this system.
pub fn display(hotkey: &str) -> String {
    let Some(shortcut) = parse(hotkey) else { return hotkey.to_string() };
    let mut parts: Vec<String> = Vec::new();
    for (modifier, name) in [
        (Modifiers::CONTROL, "Ctrl"),
        (Modifiers::ALT, "Alt"),
        (Modifiers::SHIFT, "Shift"),
        (Modifiers::SUPER, if cfg!(target_os = "windows") { "Win" } else { "Super" }),
    ] {
        if shortcut.mods.contains(modifier) {
            parts.push(name.into());
        }
    }
    let key = hotkey.rsplit('+').next().unwrap_or_default().trim();
    parts.push(match key.to_lowercase().as_str() {
        "escape" | "esc" => "Esc".into(),
        "return" | "enter" => "Enter".into(),
        "backspace" | "delete" => "Backspace".into(),
        "up" | "arrowup" => "↑".into(),
        "down" | "arrowdown" => "↓".into(),
        "left" | "arrowleft" => "←".into(),
        "right" | "arrowright" => "→".into(),
        name if name.len() > 3 && name.starts_with("key") => name[3..].to_uppercase(),
        name if name.len() > 5 && name.starts_with("digit") => name[5..].to_string(),
        name => {
            let mut chars = name.chars();
            chars.next().map(|first| first.to_uppercase().chain(chars).collect()).unwrap_or_default()
        }
    });
    parts.join(" + ")
}

#[cfg(test)]
mod tests {
    use super::*;
    use tauri_plugin_global_shortcut::Code;

    #[test]
    fn parses_accelerators_in_the_mac_form() {
        let shortcut = parse("Control+Shift+Space").unwrap();
        assert_eq!(shortcut.mods, Modifiers::CONTROL | Modifiers::SHIFT);
        assert_eq!(shortcut.key, Code::Space);
        assert_eq!(parse("Option+Space").unwrap().mods, Modifiers::ALT);
        assert_eq!(parse("Command+Shift+E").unwrap().mods, Modifiers::SUPER | Modifiers::SHIFT);
        let escape = parse("Escape").unwrap();
        assert_eq!(escape.key, Code::Escape);
        assert!(escape.mods.is_empty());
    }

    #[test]
    fn rejects_garbage_and_mac_taps() {
        for hotkey in ["garbage++x", "Control+", "", "Nope", "tap:Command:2", "Control+C+Shift"] {
            assert!(parse(hotkey).is_none(), "{hotkey}");
            assert!(!usable(hotkey), "{hotkey}");
        }
    }

    #[test]
    fn a_bare_key_is_not_a_hotkey_but_a_function_key_is() {
        assert!(!usable("Space"));
        assert!(!usable("F"));
        assert!(usable("F5"));
        assert!(usable("Alt+F"));
        assert!(usable(crate::config::DEFAULT_HOTKEY));
    }

    #[test]
    fn displays_the_systems_key_names() {
        assert_eq!(display("Control+Shift+Space"), "Ctrl + Shift + Space");
        assert_eq!(display("Option+Space"), "Alt + Space");
        assert_eq!(display("Shift+Control+KeyK"), "Ctrl + Shift + K");
        assert_eq!(display("Alt+f5"), "Alt + F5");
        assert_eq!(display("Control+Up"), "Ctrl + ↑");
        let win = if cfg!(target_os = "windows") { "Win" } else { "Super" };
        assert_eq!(display("Super+Digit1"), format!("{win} + 1"));
        assert_eq!(display("tap:Command:2"), "tap:Command:2");
    }
}
