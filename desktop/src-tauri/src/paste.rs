use std::sync::{Mutex, OnceLock};
use std::time::Duration;

// The transcription goes to the clipboard, then a synthetic Ctrl+V puts it into
// the app that has the keyboard. Where the system refuses synthetic keys the
// text stays on the clipboard and the caller says so.

/// One long-lived handle: on X11 the clipboard's content lives in its owner.
fn clipboard() -> Option<std::sync::MutexGuard<'static, Option<arboard::Clipboard>>> {
    static CLIPBOARD: OnceLock<Mutex<Option<arboard::Clipboard>>> = OnceLock::new();
    let mut guard = CLIPBOARD.get_or_init(|| Mutex::new(None)).lock().ok()?;
    if guard.is_none() {
        *guard = arboard::Clipboard::new().ok();
    }
    guard.is_some().then_some(guard)
}

pub fn write_clipboard(text: &str) -> bool {
    clipboard().is_some_and(|mut c| c.as_mut().is_some_and(|c| c.set_text(text).is_ok()))
}

pub fn read_clipboard() -> Option<String> {
    clipboard()?.as_mut()?.get_text().ok()
}

#[derive(PartialEq)]
pub enum Outcome {
    Pasted,
    CopiedOnly,
}

pub async fn paste_at_cursor(text: &str, auto_paste: bool, restore_clipboard: bool) -> Outcome {
    let previous = (restore_clipboard && auto_paste).then(read_clipboard).flatten();
    if !write_clipboard(text) || !auto_paste {
        return Outcome::CopiedOnly;
    }
    // The clipboard owner must be in place before the target app asks for it.
    tokio::time::sleep(Duration::from_millis(40)).await;
    if !send_paste_keys().await {
        return Outcome::CopiedOnly;
    }
    if let Some(previous) = previous {
        let text = text.to_string();
        tauri::async_runtime::spawn(async move {
            tokio::time::sleep(Duration::from_millis(800)).await;
            // Someone copied something newer in the meantime: leave it alone.
            if read_clipboard().as_deref() == Some(text.as_str()) {
                write_clipboard(&previous);
            }
        });
    }
    Outcome::Pasted
}

#[cfg(target_os = "windows")]
async fn send_paste_keys() -> bool {
    use windows::Win32::UI::Input::KeyboardAndMouse::{
        GetAsyncKeyState, SendInput, INPUT, INPUT_0, INPUT_KEYBOARD, KEYBDINPUT, KEYBD_EVENT_FLAGS, KEYEVENTF_KEYUP, VIRTUAL_KEY,
        VK_CONTROL, VK_LWIN, VK_MENU, VK_RWIN, VK_SHIFT, VK_V,
    };
    // A modifier still held from the hotkey would turn Ctrl+V into another shortcut.
    let held = || [VK_CONTROL, VK_SHIFT, VK_MENU, VK_LWIN, VK_RWIN].iter().any(|key| unsafe { GetAsyncKeyState(i32::from(key.0)) } < 0);
    for _ in 0..40 {
        if !held() {
            break;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    let key = |vk: VIRTUAL_KEY, flags: KEYBD_EVENT_FLAGS| INPUT {
        r#type: INPUT_KEYBOARD,
        Anonymous: INPUT_0 { ki: KEYBDINPUT { wVk: vk, dwFlags: flags, ..Default::default() } },
    };
    let inputs = [
        key(VK_CONTROL, KEYBD_EVENT_FLAGS(0)),
        key(VK_V, KEYBD_EVENT_FLAGS(0)),
        key(VK_V, KEYEVENTF_KEYUP),
        key(VK_CONTROL, KEYEVENTF_KEYUP),
    ];
    let sent = unsafe { SendInput(&inputs, std::mem::size_of::<INPUT>() as i32) };
    sent as usize == inputs.len()
}

#[cfg(target_os = "linux")]
async fn send_paste_keys() -> bool {
    if crate::linux::is_wayland() {
        return crate::linux::wayland_paste().await;
    }
    tokio::task::spawn_blocking(x11_paste).await.unwrap_or(false)
}

#[cfg(target_os = "linux")]
pub fn x11_paste() -> bool {
    use enigo::{Direction, Enigo, Key, Keyboard, Settings};
    let Ok(mut enigo) = Enigo::new(&Settings::default()) else { return false };
    let pressed = enigo.key(Key::Control, Direction::Press).is_ok() && enigo.key(Key::Unicode('v'), Direction::Click).is_ok();
    enigo.key(Key::Control, Direction::Release).is_ok() && pressed
}

#[cfg(target_os = "macos")]
async fn send_paste_keys() -> bool {
    false
}
