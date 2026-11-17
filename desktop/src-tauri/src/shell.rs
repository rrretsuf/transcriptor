use crate::app::{App, Phase};
use crate::meeting;
use serde_json::{json, Value};
use std::sync::{Arc, OnceLock};
use tauri::image::Image;
use tauri::menu::{Menu, MenuItem, PredefinedMenuItem};
use tauri::tray::{MouseButton, MouseButtonState, TrayIcon, TrayIconBuilder, TrayIconEvent};
use tauri::{AppHandle, Emitter, Manager, PhysicalPosition, WebviewUrl, WebviewWindowBuilder, WindowEvent};

// Everything the user sees outside the web views: the main window, the pill
// overlay, the tray icon and its menu.

const PILL_WIDTH: f64 = 520.0;
const PILL_HEIGHT: f64 = 84.0;

static PLATFORM: OnceLock<Value> = OnceLock::new();

/// What the web views need to look native: the system, its accent colour and
/// whether Mica is behind the window.
pub fn platform() -> Value {
    PLATFORM.get().cloned().unwrap_or(json!({ "os": std::env::consts::OS }))
}

pub async fn detect_platform() {
    #[cfg(target_os = "windows")]
    let platform = json!({ "os": "windows", "mica": has_mica(), "accent": windows_accent() });
    #[cfg(target_os = "linux")]
    let platform = {
        let appearance = crate::linux::appearance().await;
        json!({ "os": "linux", "wayland": crate::linux::is_wayland(), "dark": appearance.dark, "accent": appearance.accent })
    };
    #[cfg(target_os = "macos")]
    let platform = json!({ "os": "macos" });
    let _ = PLATFORM.set(platform);
}

#[cfg(target_os = "windows")]
fn has_mica() -> bool {
    windows_version::OsVersion::current().build >= 22000
}

#[cfg(target_os = "windows")]
fn windows_accent() -> Option<String> {
    use windows::UI::ViewManagement::{UIColorType, UISettings};
    let color = UISettings::new().ok()?.GetColorValue(UIColorType::Accent).ok()?;
    Some(format!("#{:02x}{:02x}{:02x}", color.R, color.G, color.B))
}

/* --------------------------------- windows -------------------------------- */

pub fn create_windows(handle: &AppHandle) -> tauri::Result<()> {
    let main = WebviewWindowBuilder::new(handle, "main", WebviewUrl::App("index.html".into()))
        .title("Transcriptor")
        .inner_size(900.0, 660.0)
        .min_inner_size(720.0, 540.0)
        .visible(false)
        .center();
    #[cfg(target_os = "windows")]
    let main = if has_mica() {
        main.transparent(true).effects(tauri::window::EffectsBuilder::new().effect(tauri::window::Effect::Mica).build())
    } else {
        main
    };
    let main = main.build()?;
    // The app lives in the tray: closing the window keeps the hotkey working.
    let window = main.clone();
    main.on_window_event(move |event| {
        if let WindowEvent::CloseRequested { api, .. } = event {
            api.prevent_close();
            let _ = window.hide();
        }
    });

    let pill = WebviewWindowBuilder::new(handle, "pill", WebviewUrl::App("pill.html".into()))
        .title("Transcriptor")
        .inner_size(PILL_WIDTH, PILL_HEIGHT)
        .decorations(false)
        .resizable(false)
        .shadow(false)
        .always_on_top(true)
        .skip_taskbar(true)
        .focused(false)
        .focusable(false)
        .visible_on_all_workspaces(true)
        .visible(false);
    #[cfg(not(target_os = "macos"))]
    let pill = pill.transparent(true);
    let pill = pill.build()?;
    #[cfg(target_os = "linux")]
    crate::linux::keep_unfocused(&pill);
    let _ = pill.set_ignore_cursor_events(true);
    Ok(())
}

pub fn show_main(app: &Arc<App>, view: &str) {
    let Some(window) = app.handle.get_webview_window("main") else { return };
    if !view.is_empty() {
        // A page that is still loading misses the event and asks for the view in its first snapshot.
        *app.view.lock().unwrap() = view.to_string();
        let _ = window.emit("navigate", view);
    }
    let _ = window.unminimize();
    let _ = window.show();
    let _ = window.set_focus();
}

/// Top centre of the screen the pointer is on, without taking the keyboard
/// from the app that is being dictated into.
pub fn show_pill(handle: &AppHandle) {
    let Some(pill) = handle.get_webview_window("pill") else { return };
    let monitor = handle
        .cursor_position()
        .ok()
        .and_then(|cursor| handle.monitor_from_point(cursor.x, cursor.y).ok().flatten())
        .or_else(|| handle.primary_monitor().ok().flatten());
    if let Some(monitor) = monitor {
        let area = monitor.work_area();
        let scale = monitor.scale_factor();
        let x = area.position.x + ((f64::from(area.size.width) - PILL_WIDTH * scale) / 2.0).round() as i32;
        let y = area.position.y + (8.0 * scale).round() as i32;
        let _ = pill.set_position(PhysicalPosition::new(x, y));
    }
    #[cfg(target_os = "windows")]
    if let Ok(hwnd) = pill.hwnd() {
        use windows::Win32::Foundation::HWND;
        use windows::Win32::UI::WindowsAndMessaging::{ShowWindow, SW_SHOWNOACTIVATE};
        unsafe {
            let _ = ShowWindow(HWND(hwnd.0 as _), SW_SHOWNOACTIVATE);
        }
        return;
    }
    let _ = pill.show();
}

pub fn hide_pill(handle: &AppHandle) {
    if let Some(pill) = handle.get_webview_window("pill") {
        let _ = pill.hide();
    }
}

/* ---------------------------------- tray ---------------------------------- */

pub struct Tray {
    icon: TrayIcon,
    toggle: MenuItem<tauri::Wry>,
    copy_last: MenuItem<tauri::Wry>,
    meeting: MenuItem<tauri::Wry>,
}

/// The app icon's five bars on a rounded tile, drawn here so it is crisp at
/// tray size and readable on light and dark panels. Red while recording.
fn tray_image(active: bool) -> Image<'static> {
    const SIZE: usize = 32;
    let tile: [u8; 3] = if active { [229, 72, 77] } else { [38, 38, 42] };
    let heights: [f32; 5] = if active { [10.0, 18.0, 24.0, 18.0, 10.0] } else { [6.0, 12.0, 18.0, 12.0, 6.0] };
    let (bar, gap) = (3.0_f32, 2.0_f32);
    let left = (SIZE as f32 - (5.0 * bar + 4.0 * gap)) / 2.0;
    let rounded = |x: f32, y: f32, x0: f32, y0: f32, x1: f32, y1: f32, r: f32| -> f32 {
        let dx = (x0 + r - x).max(x - (x1 - r)).max(0.0);
        let dy = (y0 + r - y).max(y - (y1 - r)).max(0.0);
        (r + 0.5 - (dx * dx + dy * dy).sqrt()).clamp(0.0, 1.0)
    };
    let mut rgba = Vec::with_capacity(SIZE * SIZE * 4);
    for py in 0..SIZE {
        for px in 0..SIZE {
            let (x, y) = (px as f32 + 0.5, py as f32 + 0.5);
            let tile_alpha = rounded(x, y, 0.0, 0.0, SIZE as f32, SIZE as f32, 7.5);
            let bars = heights
                .iter()
                .enumerate()
                .map(|(i, h)| {
                    let x0 = left + i as f32 * (bar + gap);
                    let y0 = (SIZE as f32 - h) / 2.0;
                    rounded(x, y, x0, y0, x0 + bar, y0 + h, bar / 2.0)
                })
                .fold(0.0_f32, f32::max);
            let mix = |c: u8| (f32::from(c) * (1.0 - bars) + 255.0 * bars).round() as u8;
            rgba.extend([mix(tile[0]), mix(tile[1]), mix(tile[2]), (tile_alpha * 255.0).round() as u8]);
        }
    }
    Image::new_owned(rgba, SIZE as u32, SIZE as u32)
}

pub fn create_tray(app: &Arc<App>) -> tauri::Result<()> {
    let handle = &app.handle;
    let item = |id: &str, text: &str| MenuItem::with_id(handle, id, text, true, None::<&str>);
    let open = item("open", "Open Transcriptor")?;
    let toggle = item("toggle", "Start Dictation")?;
    let copy_last = item("copy-last", "Copy Last Transcription")?;
    let file = item("file", "Transcribe File…")?;
    let meeting = item("meeting", "Start Meeting Transcription")?;
    let history = item("history", "All Transcriptions…")?;
    let settings = item("settings", "Settings…")?;
    let quit = item("quit", "Quit Transcriptor")?;
    let separator = || PredefinedMenuItem::separator(handle);
    let menu = Menu::with_items(
        handle,
        &[&open, &separator()?, &toggle, &copy_last, &separator()?, &file, &meeting, &separator()?, &history, &settings, &separator()?, &quit],
    )?;

    let on_menu = app.clone();
    let on_click = app.clone();
    let icon = TrayIconBuilder::with_id("main")
        .icon(tray_image(false))
        .tooltip("Transcriptor")
        .menu(&menu)
        .show_menu_on_left_click(false)
        .on_menu_event(move |handle, event| {
            let app = &on_menu;
            match event.id.as_ref() {
                "open" => show_main(app, ""),
                "toggle" => app.toggle(),
                "copy-last" => {
                    let last = app.store.lock().unwrap().last_transcript.clone();
                    crate::paste::write_clipboard(&last);
                }
                "file" => show_main(app, "file"),
                "meeting" => {
                    if !app.meeting.lock().unwrap().is_active() {
                        meeting::reset(app);
                        meeting::start(app);
                    }
                    show_main(app, "meeting");
                }
                "history" => show_main(app, "history"),
                "settings" => show_main(app, "settings"),
                "quit" => handle.exit(0),
                _ => {}
            }
        })
        .on_tray_icon_event(move |_, event| {
            if let TrayIconEvent::Click { button: MouseButton::Left, button_state: MouseButtonState::Up, .. } = event {
                show_main(&on_click, "");
            }
        })
        .build(handle)?;
    handle.manage(Tray { icon, toggle, copy_last, meeting });
    state_changed(app);
    Ok(())
}

/// Tray and web views follow the dictation and the meeting.
pub fn state_changed(app: &Arc<App>) {
    let phase = app.phase();
    let meeting_active = app.meeting.lock().unwrap().is_active();
    let has_last = !app.store.lock().unwrap().last_transcript.is_empty();
    if let Some(tray) = app.handle.try_state::<Tray>() {
        let label = match phase {
            Phase::Recording => "Stop Dictation",
            Phase::Finishing => "Finishing…",
            Phase::Idle => "Start Dictation",
        };
        let _ = tray.toggle.set_text(format!("{label}    {}", app.hotkey_label()));
        let _ = tray.toggle.set_enabled(phase != Phase::Finishing);
        let _ = tray.copy_last.set_enabled(has_last);
        let _ = tray.meeting.set_text(if meeting_active { "Show Meeting" } else { "Start Meeting Transcription" });
        let _ = tray.icon.set_icon(Some(tray_image(phase != Phase::Idle || meeting_active)));
    }
    let phase = match phase {
        Phase::Idle => "idle",
        Phase::Recording => "recording",
        Phase::Finishing => "finishing",
    };
    let _ = app.handle.emit("state", json!({ "phase": phase }));
}

/* ------------------------------ foreground app ---------------------------- */

/// The app the user is dictating into, for the history entry.
#[cfg(target_os = "windows")]
pub fn foreground_app() -> Option<String> {
    use windows::core::PWSTR;
    use windows::Win32::Foundation::CloseHandle;
    use windows::Win32::System::Threading::{OpenProcess, QueryFullProcessImageNameW, PROCESS_NAME_WIN32, PROCESS_QUERY_LIMITED_INFORMATION};
    use windows::Win32::UI::WindowsAndMessaging::{GetForegroundWindow, GetWindowThreadProcessId};
    unsafe {
        let mut pid = 0;
        GetWindowThreadProcessId(GetForegroundWindow(), Some(&mut pid));
        let process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid).ok()?;
        let mut buffer = [0u16; 1024];
        let mut length = buffer.len() as u32;
        let read = QueryFullProcessImageNameW(process, PROCESS_NAME_WIN32, PWSTR(buffer.as_mut_ptr()), &mut length);
        let _ = CloseHandle(process);
        read.ok()?;
        let path = String::from_utf16_lossy(&buffer[..length as usize]);
        std::path::Path::new(&path).file_stem().map(|name| name.to_string_lossy().into_owned())
    }
}

#[cfg(not(target_os = "windows"))]
pub fn foreground_app() -> Option<String> {
    None
}
