#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod app;
mod audio;
mod config;
mod dsp;
mod files;
mod history;
mod hotkey;
mod keystore;
#[cfg(target_os = "linux")]
mod linux;
mod meeting;
mod paste;
mod selftest;
mod shell;
mod soniox;
mod store;

use app::{App, Phase};
use config::Config;
use serde_json::{json, Value};
use std::sync::Arc;
use store::{NewEntry, Store};
use tauri::{Emitter, Manager, RunEvent, State};
use tauri_plugin_autostart::ManagerExt;

type AppState<'a> = State<'a, Arc<App>>;

/* -------------------------------- commands -------------------------------- */

#[tauri::command]
async fn snapshot(app: AppState<'_>) -> Result<Value, String> {
    let has_key = app.api_key().await.is_some();
    let app = app.inner().clone();
    // Asking the audio server what exists can take a moment; keep it off the UI thread.
    let system_audio = tauri::async_runtime::spawn_blocking(audio::system_audio_available).await.unwrap_or(false);
    Ok(json!({
        "version": env!("CARGO_PKG_VERSION"),
        "platform": shell::platform(),
        "config": app.config(),
        "hotkeyLabel": app.hotkey_label(),
        "hotkeyProblem": *app.hotkey_problem.lock().unwrap(),
        "desktopOwnsHotkey": app.portal_hotkey.lock().unwrap().is_some(),
        "toggleCommand": format!("{} --toggle", std::env::current_exe().map(|p| p.display().to_string()).unwrap_or("transcriptor".into())),
        "view": *app.view.lock().unwrap(),
        "hasKey": has_key,
        "unreadable": app.unreadable,
        "systemAudio": system_audio,
        "phase": match app.phase() { Phase::Idle => "idle", Phase::Recording => "recording", Phase::Finishing => "finishing" },
    }))
}

#[tauri::command]
fn history(app: AppState) -> Vec<history::Entry> {
    app.store.lock().unwrap().history.clone()
}

/// Saves the settings. A hotkey another app already holds is refused and the
/// previous one stays registered.
#[tauri::command]
fn save_config(app: AppState, config: Config) -> Result<(), String> {
    let previous = app.config();
    if config.hotkey != previous.hotkey && !hotkey::usable(&config.hotkey) {
        return Err("Use at least one modifier key, like Ctrl or Alt.".into());
    }
    app.store.lock().unwrap().save_config(config.clone())?;
    if config.hotkey != previous.hotkey {
        app.register_hotkey();
        if let Some(problem) = app.hotkey_problem.lock().unwrap().take() {
            let _ = app.store.lock().unwrap().save_config(Config { hotkey: previous.hotkey, ..config });
            app.register_hotkey();
            return Err(problem);
        }
        shell::state_changed(&app);
    }
    if config.launch_at_login != previous.launch_at_login {
        apply_launch_at_login(&app);
    }
    Ok(())
}

/// Checks the key with Soniox before it is stored, so a typo never gets saved.
#[tauri::command]
async fn save_key(app: AppState<'_>, key: String) -> Result<(), String> {
    let key = key.trim();
    if key.is_empty() {
        return Err("Paste your Soniox API key.".into());
    }
    if !soniox::validate_key(key).await? {
        return Err("Soniox does not recognize this key. Copy it again from the console.".into());
    }
    app.set_api_key(key).await
}

#[tauri::command]
fn toggle(app: AppState) {
    app.toggle();
}

#[tauri::command]
fn copy(text: String) -> bool {
    paste::write_clipboard(&text)
}

#[tauri::command]
fn delete_entry(app: AppState, id: String) -> Result<(), String> {
    app.store.lock().unwrap().delete(&id)?;
    shell::state_changed(&app);
    Ok(())
}

#[tauri::command]
fn finish_onboarding(app: AppState) -> Result<(), String> {
    let config = Config { onboarded: true, ..app.config() };
    app.store.lock().unwrap().save_config(config)
}

#[tauri::command]
fn meeting_get(app: AppState) -> Value {
    app.meeting.lock().unwrap().snapshot()
}

#[tauri::command]
fn meeting_do(app: AppState, action: String, title: Option<String>) {
    match action.as_str() {
        "start" => meeting::start(&app),
        "pause" => meeting::toggle_pause(&app),
        "end" => meeting::end(&app),
        "reset" => meeting::reset(&app),
        "restart" => {
            meeting::reset(&app);
            meeting::start(&app);
        }
        "title" => meeting::set_title(&app, title.unwrap_or_default()),
        _ => {}
    }
}

#[tauri::command]
fn file_get(app: AppState) -> Value {
    app.file.lock().unwrap().status.clone()
}

fn set_file_status(app: &Arc<App>, status: Value) {
    app.file.lock().unwrap().status = status.clone();
    let _ = app.handle.emit("file", status);
}

#[tauri::command]
fn file_start(app: AppState, path: String) {
    let app = app.inner().clone();
    let path = std::path::PathBuf::from(path);
    let name = path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
    if let Some(task) = app.file.lock().unwrap().task.take() {
        task.abort();
    }
    set_file_status(&app, json!({ "status": "working", "stage": "Uploading…", "name": name }));
    let job = app.clone();
    let task = tauri::async_runtime::spawn(async move {
        let app = job;
        let Some(key) = app.api_key().await else {
            return set_file_status(&app, json!({ "status": "failed", "message": "Add your Soniox key in Settings first." }));
        };
        let stage = |stage| {
            let label = match stage {
                files::Stage::Uploading => "Uploading…",
                files::Stage::Transcribing => "Transcribing…",
            };
            set_file_status(&app, json!({ "status": "working", "stage": label, "name": name }));
        };
        match files::transcribe(&path, &key, &app.config(), stage).await {
            Ok((text, _)) if text.is_empty() => {
                set_file_status(&app, json!({ "status": "failed", "message": "No speech found in this file." }))
            }
            Ok((text, duration_ms)) => {
                let entry =
                    NewEntry { text: &text, duration_ms, title: Some(name.clone()), started_at: None, kind: history::Kind::File, app: None };
                let _ = app.store.lock().unwrap().record(entry);
                let _ = app.handle.emit("history", ());
                shell::state_changed(&app);
                set_file_status(&app, json!({ "status": "done", "text": text, "name": name }));
            }
            Err(message) => set_file_status(&app, json!({ "status": "failed", "message": message })),
        }
    });
    app.file.lock().unwrap().task = Some(task);
}

#[tauri::command]
fn file_reset(app: AppState) {
    if let Some(task) = app.file.lock().unwrap().task.take() {
        task.abort();
    }
    set_file_status(&app, json!({ "status": "idle" }));
}

/* --------------------------------- startup -------------------------------- */

/// Reapplied on every launch: an update or reinstall can drop the login item.
fn apply_launch_at_login(app: &Arc<App>) {
    if cfg!(debug_assertions) {
        return;
    }
    let autostart = app.handle.autolaunch();
    let (wanted, enabled) = (app.config().launch_at_login, autostart.is_enabled().unwrap_or(false));
    if wanted && !enabled {
        let _ = autostart.enable();
    } else if !wanted && enabled {
        let _ = autostart.disable();
    }
}

/// On Wayland the desktop owns global keys: ask it for one through the portal.
#[cfg(target_os = "linux")]
fn bind_desktop_hotkey(app: &Arc<App>) {
    if !linux::is_wayland() {
        return;
    }
    let app = app.clone();
    tauri::async_runtime::spawn(async move {
        linux::register_app().await;
        let on_toggle = app.clone();
        match linux::portal_shortcut(&app.hotkey(), move || on_toggle.toggle()).await {
            Ok(bound) => *app.portal_hotkey.lock().unwrap() = Some(bound),
            Err(_) => *app.hotkey_problem.lock().unwrap() = Some("wayland".into()),
        }
        shell::state_changed(&app);
        let _ = app.handle.emit("hotkey", ());
    });
}

/// `--show settings` opens the window on that view.
fn view_argument(args: &[String]) -> String {
    args.iter().position(|a| a == "--show").and_then(|at| args.get(at + 1)).cloned().unwrap_or_default()
}

fn main() {
    let _ = rustls::crypto::ring::default_provider().install_default();
    let args: Vec<String> = std::env::args().skip(1).collect();
    let has = |flag: &str| args.iter().any(|a| a == flag);
    if let Some(index) = args.iter().position(|a| a == "--selftest-file") {
        std::process::exit(selftest::file(args.get(index + 1).map(String::as_str).unwrap_or_default()));
    }
    #[cfg(target_os = "linux")]
    linux::prefer_xwayland();

    let selftest = has("--selftest").then(|| selftest::Mode::Checks).or(has("--selftest-e2e").then(|| selftest::Mode::EndToEnd));
    let (hidden, toggle_on_launch, view) = (has("--hidden"), has("--toggle"), view_argument(&args));

    let builder = tauri::Builder::default()
        .plugin(tauri_plugin_single_instance::init(|handle, args, _| {
            let app = handle.state::<Arc<App>>().inner().clone();
            if args.iter().any(|a| a == "--toggle") {
                app.toggle();
            } else {
                shell::show_main(&app, &view_argument(&args));
            }
        }))
        .plugin(tauri_plugin_global_shortcut::Builder::new().build())
        .plugin(tauri_plugin_autostart::init(tauri_plugin_autostart::MacosLauncher::LaunchAgent, Some(vec!["--hidden"])))
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_opener::init())
        .invoke_handler(tauri::generate_handler![
            snapshot,
            history,
            save_config,
            save_key,
            toggle,
            copy,
            delete_entry,
            finish_onboarding,
            meeting_get,
            meeting_do,
            file_get,
            file_start,
            file_reset
        ])
        .setup(move |setup| {
            let dir = store::data_dir();
            let mut store = Store::new(dir.clone());
            let unreadable = store.load();
            #[cfg(target_os = "linux")]
            linux::set_data_dir(&dir);
            let app = App::new(setup.handle().clone(), dir, store, unreadable);
            setup.manage(app.clone());

            tauri::async_runtime::block_on(shell::detect_platform());
            shell::create_windows(&app.handle)?;
            shell::create_tray(&app)?;
            // The hotkey is the product; register it before anything that can wait.
            app.register_hotkey();
            #[cfg(target_os = "linux")]
            bind_desktop_hotkey(&app);

            if let Some(mode) = selftest {
                selftest::run(app, mode);
                return Ok(());
            }
            apply_launch_at_login(&app);
            let warm = app.clone();
            tauri::async_runtime::spawn(async move { drop(warm.api_key().await) });
            if toggle_on_launch {
                app.toggle();
            } else if !hidden || !app.config().onboarded {
                shell::show_main(&app, &view);
            }
            Ok(())
        });

    let running = builder.build(tauri::generate_context!()).expect("Transcriptor could not start");
    running.run(|_, event| {
        // Closing the last window hides it; only Quit from the tray ends the app.
        if let RunEvent::ExitRequested { api, code: None, .. } = event {
            api.prevent_exit();
        }
    });
}
