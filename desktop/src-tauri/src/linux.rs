use ashpd::desktop::global_shortcuts::{GlobalShortcuts, NewShortcut};
use ashpd::desktop::remote_desktop::{DeviceType, KeyState, RemoteDesktop, SelectDevicesOptions};
use ashpd::desktop::settings::{ColorScheme, Settings};
use ashpd::desktop::{PersistMode, Session};
use futures_util::StreamExt;
use std::path::PathBuf;
use std::sync::OnceLock;
use std::time::Duration;

// Wayland keeps apps away from global keys and other apps' input on purpose.
// The portals are the sanctioned way in: GlobalShortcuts for the hotkey,
// RemoteDesktop for the Ctrl+V. Where a desktop has neither, `transcriptor
// --toggle` bound to a key in the desktop's own settings starts dictation and
// the text stays on the clipboard.

static WAYLAND: OnceLock<bool> = OnceLock::new();

/// Read once at launch, before the window toolkit is pointed at XWayland.
pub fn is_wayland() -> bool {
    *WAYLAND.get_or_init(|| {
        std::env::var("XDG_SESSION_TYPE").is_ok_and(|t| t == "wayland") || std::env::var_os("WAYLAND_DISPLAY").is_some()
    })
}

/// A Wayland compositor decides where windows go and which one has the
/// keyboard; an overlay at the top of the screen that never takes focus only
/// exists through XWayland.
pub fn prefer_xwayland() {
    if is_wayland() && std::env::var_os("DISPLAY").is_some() && std::env::var_os("GDK_BACKEND").is_none() {
        std::env::set_var("GDK_BACKEND", "x11");
    }
}

pub async fn register_app() {
    if let Ok(id) = ashpd::AppID::try_from("Transcriptor") {
        let _ = ashpd::register_host_app(id).await;
    }
}

pub struct Appearance {
    pub dark: Option<bool>,
    pub accent: Option<String>,
}

pub async fn appearance() -> Appearance {
    let read = async {
        let settings = Settings::new().await.ok()?;
        let dark = match settings.color_scheme().await.ok()? {
            ColorScheme::PreferDark => Some(true),
            ColorScheme::PreferLight => Some(false),
            ColorScheme::NoPreference => None,
        };
        let accent = settings.accent_color().await.ok().map(|c| {
            let byte = |v: f64| (v.clamp(0.0, 1.0) * 255.0).round() as u8;
            format!("#{:02x}{:02x}{:02x}", byte(c.red()), byte(c.green()), byte(c.blue()))
        });
        Some(Appearance { dark, accent })
    };
    tokio::time::timeout(Duration::from_secs(2), read).await.ok().flatten().unwrap_or(Appearance { dark: None, accent: None })
}

/// "Control+Shift+Space" → "CTRL+SHIFT+space", the form the shortcuts portal takes.
pub fn portal_trigger(hotkey: &str) -> String {
    hotkey
        .split('+')
        .map(|part| match part.trim().to_lowercase().as_str() {
            "control" | "ctrl" => "CTRL".to_string(),
            "alt" | "option" => "ALT".to_string(),
            "shift" => "SHIFT".to_string(),
            "super" | "command" | "cmd" => "LOGO".to_string(),
            "escape" | "esc" => "Escape".to_string(),
            "return" | "enter" => "Return".to_string(),
            key if key.len() > 1 && key.starts_with('f') && key[1..].chars().all(|c| c.is_ascii_digit()) => key.to_uppercase(),
            key => key.to_string(),
        })
        .collect::<Vec<_>>()
        .join("+")
}

/// Binds the dictation toggle through the GlobalShortcuts portal. The desktop
/// asks the user once and owns the key from then on; the returned text is the
/// key it chose.
pub async fn portal_shortcut(hotkey: &str, on_toggle: impl Fn() + Send + 'static) -> Result<String, String> {
    let bind = async {
        let portal = GlobalShortcuts::new().await.map_err(|e| e.to_string())?;
        let session = portal.create_session(Default::default()).await.map_err(|e| e.to_string())?;
        let trigger = portal_trigger(hotkey);
        let shortcut = NewShortcut::new("toggle", "Start or stop dictation").preferred_trigger(trigger.as_str());
        let bound = portal
            .bind_shortcuts(&session, &[shortcut], None, Default::default())
            .await
            .and_then(|request| request.response())
            .map_err(|e| e.to_string())?;
        let description = bound.shortcuts().first().map(|s| s.trigger_description().to_string()).unwrap_or_default();
        let activated = portal.receive_activated().await.map_err(|e| e.to_string())?;
        Ok::<_, String>((portal, session, activated, description))
    };
    let (portal, session, mut activated, description) =
        tokio::time::timeout(Duration::from_secs(120), bind).await.map_err(|_| "The desktop did not answer".to_string())??;
    tauri::async_runtime::spawn(async move {
        let _alive = (portal, session);
        while let Some(event) = activated.next().await {
            if event.shortcut_id() == "toggle" {
                on_toggle();
            }
        }
    });
    Ok(description)
}

struct Typist {
    portal: RemoteDesktop,
    session: Session<RemoteDesktop>,
}

static TYPIST: tokio::sync::Mutex<Option<Typist>> = tokio::sync::Mutex::const_new(None);
static TOKEN_FILE: OnceLock<PathBuf> = OnceLock::new();

pub fn set_data_dir(dir: &std::path::Path) {
    let _ = TOKEN_FILE.set(dir.join("portal-token"));
}

/// The desktop asks once whether Transcriptor may type; the restore token keeps
/// that answer for later launches.
async fn open_typist() -> Option<Typist> {
    let token = TOKEN_FILE.get().and_then(|f| std::fs::read_to_string(f).ok());
    let portal = RemoteDesktop::new().await.ok()?;
    let session = portal.create_session(Default::default()).await.ok()?;
    let options = SelectDevicesOptions::default()
        .set_devices(DeviceType::KEYBOARD)
        .set_persist_mode(PersistMode::ExplicitlyRevoked)
        .set_restore_token(token.as_deref().map(str::trim));
    portal.select_devices(&session, options).await.ok()?.response().ok()?;
    let started = portal.start(&session, None, Default::default()).await.ok()?.response().ok()?;
    if !started.devices().contains(DeviceType::KEYBOARD) {
        return None;
    }
    if let (Some(token), Some(file)) = (started.restore_token(), TOKEN_FILE.get()) {
        let _ = std::fs::write(file, token);
    }
    Some(Typist { portal, session })
}

async fn portal_paste() -> bool {
    const CONTROL_L: i32 = 0xffe3;
    const V: i32 = 0x76;
    let mut typist = TYPIST.lock().await;
    if typist.is_none() {
        *typist = tokio::time::timeout(Duration::from_secs(60), open_typist()).await.ok().flatten();
        // The permission dialog had the keyboard; give it back to the app before typing.
        tokio::time::sleep(Duration::from_millis(300)).await;
    }
    let Some(Typist { portal, session }) = typist.as_ref() else { return false };
    let strokes = [(CONTROL_L, KeyState::Pressed), (V, KeyState::Pressed), (V, KeyState::Released), (CONTROL_L, KeyState::Released)];
    for (keysym, state) in strokes {
        let sent = tokio::time::timeout(
            Duration::from_secs(2),
            portal.notify_keyboard_keysym(session, keysym, state, Default::default()),
        )
        .await;
        if !matches!(sent, Ok(Ok(()))) {
            *typist = None;
            return false;
        }
    }
    true
}

async fn tool_paste(program: &str, args: &[&str]) -> bool {
    tokio::process::Command::new(program)
        .args(args)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .await
        .is_ok_and(|status| status.success())
}

/// Ctrl+V on Wayland: the RemoteDesktop portal (GNOME, KDE), then wtype
/// (wlroots compositors), then ydotool. False means the text is on the clipboard only.
pub async fn wayland_paste() -> bool {
    portal_paste().await
        || tool_paste("wtype", &["-M", "ctrl", "v", "-m", "ctrl"]).await
        || tool_paste("ydotool", &["key", "29:1", "47:1", "47:0", "29:0"]).await
}

/// The pill must never take the keyboard from the app being dictated into.
/// Realizing it here gives it the GDK window that click-through needs.
pub fn keep_unfocused(window: &tauri::WebviewWindow) {
    use gtk::prelude::{GtkWindowExt, WidgetExt};
    if let Ok(window) = window.gtk_window() {
        window.set_accept_focus(false);
        window.set_focus_on_map(false);
        window.set_skip_pager_hint(true);
        window.realize();
    }
}

#[cfg(test)]
mod tests {
    use super::portal_trigger;

    #[test]
    fn hotkeys_translate_to_portal_triggers() {
        assert_eq!(portal_trigger("Control+Shift+Space"), "CTRL+SHIFT+space");
        assert_eq!(portal_trigger("Alt+F5"), "ALT+F5");
        assert_eq!(portal_trigger("Super+K"), "LOGO+k");
    }
}
