use crate::config::{Config, DEFAULT_HOTKEY};
use crate::history::Kind;
use crate::paste::{self, Outcome};
use crate::soniox::{run_session, Control, Event};
use crate::store::{NewEntry, Store};
use crate::{audio, hotkey, keystore, meeting::Meeting, meeting_detect::MeetingTracker, shell};
use serde_json::json;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tauri::async_runtime::{spawn, spawn_blocking};
use tauri::{AppHandle, Emitter};
use tauri_plugin_global_shortcut::{GlobalShortcutExt, ShortcutState};
use tokio::sync::mpsc::{unbounded_channel, UnboundedSender};

#[derive(Clone, Copy, PartialEq)]
pub enum Phase {
    Idle,
    Recording,
    Finishing,
}

struct Dictation {
    phase: Phase,
    control: Option<UnboundedSender<Control>>,
    /// The app being dictated into, kept with the entry.
    target: Option<String>,
    generation: u64,
}

pub struct FileJob {
    pub status: serde_json::Value,
    pub task: Option<tauri::async_runtime::JoinHandle<()>>,
}

pub struct App {
    pub handle: AppHandle,
    pub dir: PathBuf,
    /// Files that exist but could not be parsed; they are kept and never overwritten.
    pub unreadable: Vec<&'static str>,
    pub store: Mutex<Store>,
    pub meeting: Mutex<Meeting>,
    pub meeting_detect: Mutex<MeetingTracker>,
    pub file: Mutex<FileJob>,
    /// Why the hotkey does not work, for Settings and onboarding to show.
    pub hotkey_problem: Mutex<Option<String>>,
    /// On Wayland the desktop owns the key; this is the one it bound.
    pub portal_hotkey: Mutex<Option<String>>,
    /// The view the window was last asked to show.
    pub view: Mutex<String>,
    key: Mutex<Option<String>>,
    dictation: Mutex<Dictation>,
    pill: AtomicU64,
}

impl App {
    pub fn new(handle: AppHandle, dir: PathBuf, store: Store, unreadable: Vec<&'static str>) -> Arc<Self> {
        Arc::new(Self {
            handle,
            dir,
            unreadable,
            store: Mutex::new(store),
            meeting: Mutex::new(Meeting::default()),
            meeting_detect: Mutex::new(MeetingTracker::default()),
            file: Mutex::new(FileJob { status: json!({ "status": "idle" }), task: None }),
            hotkey_problem: Mutex::new(None),
            portal_hotkey: Mutex::new(None),
            view: Mutex::new(String::new()),
            key: Mutex::new(None),
            dictation: Mutex::new(Dictation { phase: Phase::Idle, control: None, target: None, generation: 0 }),
            pill: AtomicU64::new(0),
        })
    }

    pub fn config(&self) -> Config {
        self.store.lock().unwrap().config.clone()
    }

    pub fn phase(&self) -> Phase {
        self.dictation.lock().unwrap().phase
    }

    /* ---------------------------------- key ---------------------------------- */

    /// Read from the credential store once, then kept in memory. A locked
    /// keyring asks the user for its password first, so this can take as long
    /// as they do; the read finishes and is remembered even if the caller gave up waiting.
    pub async fn api_key(self: &Arc<Self>) -> Option<String> {
        if let Some(key) = self.key.lock().unwrap().clone() {
            return Some(key);
        }
        let app = self.clone();
        let read = spawn_blocking(move || {
            let key = keystore::get(&app.dir, keystore::SONIOX);
            if key.is_some() {
                app.key.lock().unwrap().clone_from(&key);
            }
            key
        });
        read.await.ok().flatten()
    }

    pub async fn set_api_key(&self, key: &str) -> Result<(), String> {
        let (dir, value) = (self.dir.clone(), key.to_string());
        spawn_blocking(move || keystore::set(&dir, keystore::SONIOX, &value)).await.map_err(|e| e.to_string())??;
        *self.key.lock().unwrap() = (!key.is_empty()).then(|| key.to_string());
        Ok(())
    }

    /// For the self-test only: a key that never touches the credential store.
    pub fn use_key(&self, key: String) {
        *self.key.lock().unwrap() = Some(key);
    }

    /* -------------------------------- hotkeys -------------------------------- */

    pub fn hotkey(&self) -> String {
        let hotkey = self.config().hotkey;
        if hotkey::usable(&hotkey) { hotkey } else { DEFAULT_HOTKEY.into() }
    }

    /// Empty when this desktop gives the app no global key: the user binds
    /// `transcriptor --toggle` to one of their own.
    pub fn hotkey_label(&self) -> String {
        if self.hotkey_problem.lock().unwrap().as_deref() == Some("wayland") {
            return String::new();
        }
        self.portal_hotkey.lock().unwrap().clone().filter(|label| !label.is_empty()).unwrap_or_else(|| hotkey::display(&self.hotkey()))
    }

    /// Handlers only hand the work on: they run on the thread that delivers
    /// hotkeys, and registering Escape from there would wait on itself.
    pub fn register_hotkey(self: &Arc<Self>) {
        #[cfg(target_os = "linux")]
        if crate::linux::is_wayland() {
            return;
        }
        let shortcuts = self.handle.global_shortcut();
        let _ = shortcuts.unregister_all();
        if self.phase() != Phase::Idle {
            self.set_cancel_key(true);
        }
        let hotkey = self.hotkey();
        let app = self.clone();
        let registered = shortcuts.on_shortcut(hotkey.as_str(), move |_, _, event| {
            if event.state() == ShortcutState::Pressed {
                let app = app.clone();
                spawn_blocking(move || app.toggle());
            }
        });
        *self.hotkey_problem.lock().unwrap() =
            registered.is_err().then(|| format!("{} is already used by another app. Choose another one.", hotkey::display(&hotkey)));
    }

    /// Escape cancels while a dictation is on screen, and is left alone otherwise.
    fn set_cancel_key(self: &Arc<Self>, on: bool) {
        let shortcuts = self.handle.global_shortcut();
        if !on {
            let _ = shortcuts.unregister("Escape");
            return;
        }
        let app = self.clone();
        let _ = shortcuts.on_shortcut("Escape", move |_, _, event| {
            if event.state() == ShortcutState::Pressed {
                let app = app.clone();
                spawn_blocking(move || app.cancel());
            }
        });
    }

    /* -------------------------------- sessions ------------------------------- */

    pub fn toggle(self: &Arc<Self>) {
        match self.phase() {
            Phase::Recording => self.stop(),
            Phase::Idle => self.begin(),
            Phase::Finishing => {}
        }
    }

    fn begin(self: &Arc<Self>) {
        let generation = {
            let mut dictation = self.dictation.lock().unwrap();
            if dictation.phase != Phase::Idle {
                return;
            }
            dictation.phase = Phase::Recording;
            dictation.generation += 1;
            dictation.control = None;
            dictation.target = shell::foreground_app();
            dictation.generation
        };
        // The pill opens at once; microphone and socket catch up behind it.
        self.show_pill(json!({ "state": "recording" }));
        self.set_cancel_key(true);
        shell::state_changed(self);

        let app = self.clone();
        spawn(async move {
            let Some(key) = app.api_key().await else {
                app.fail(generation, "Add your Soniox key first");
                shell::show_main(&app, "settings");
                return;
            };
            let Ok(Ok((capture, chunks))) = spawn_blocking(|| audio::start(false)).await else {
                return app.fail(generation, "Microphone unavailable");
            };
            let (control, commands) = unbounded_channel();
            {
                let mut dictation = app.dictation.lock().unwrap();
                if dictation.generation != generation || dictation.phase != Phase::Recording {
                    return; // cancelled while the microphone was opening
                }
                dictation.control = Some(control);
            }
            let events = app.clone();
            run_session(app.config(), key, capture, chunks, commands, move |event| events.on_event(generation, event)).await;
        });
    }

    pub fn stop(self: &Arc<Self>) {
        let control = {
            let mut dictation = self.dictation.lock().unwrap();
            if dictation.phase != Phase::Recording {
                return;
            }
            if dictation.control.is_some() {
                dictation.phase = Phase::Finishing;
            }
            dictation.control.clone()
        };
        match control {
            Some(control) => {
                let _ = control.send(Control::Stop);
                self.update_pill(json!({ "state": "finishing" }));
                shell::state_changed(self);
            }
            None => self.cancel(), // stopped before the microphone was up
        }
    }

    pub fn cancel(self: &Arc<Self>) {
        {
            let mut dictation = self.dictation.lock().unwrap();
            if dictation.phase == Phase::Idle {
                return;
            }
            if let Some(control) = dictation.control.take() {
                let _ = control.send(Control::Cancel);
            }
            dictation.generation += 1;
            dictation.phase = Phase::Idle;
        }
        self.set_cancel_key(false);
        self.hide_pill(json!({ "state": "idle" }), Duration::from_millis(350));
        shell::state_changed(self);
    }

    fn fail(self: &Arc<Self>, generation: u64, message: &str) {
        {
            let mut dictation = self.dictation.lock().unwrap();
            if dictation.generation != generation || dictation.phase == Phase::Idle {
                return;
            }
            dictation.control = None;
            dictation.phase = Phase::Idle;
        }
        self.set_cancel_key(false);
        self.hide_pill(json!({ "state": "fail", "message": message }), Duration::from_millis(2600));
        shell::state_changed(self);
    }

    fn on_event(self: &Arc<Self>, generation: u64, event: Event) {
        if self.dictation.lock().unwrap().generation != generation {
            return;
        }
        match event {
            Event::Transcript { final_text, partial } => {
                self.update_pill(json!({ "state": "transcript", "final": final_text, "partial": partial }))
            }
            Event::Level(rms) => self.update_pill(json!({ "state": "level", "level": rms })),
            Event::Stopping => {
                self.dictation.lock().unwrap().phase = Phase::Finishing;
                self.update_pill(json!({ "state": "finishing" }));
                shell::state_changed(self);
            }
            Event::Done { text, duration_ms, error } => self.finish(generation, text, duration_ms, error),
        }
    }

    /// A network or Soniox failure does not lose what was already transcribed:
    /// it is pasted like a normal result and the pill says what happened.
    fn finish(self: &Arc<Self>, generation: u64, text: String, duration_ms: f64, error: Option<String>) {
        let text = text.trim().to_string();
        if text.is_empty() {
            let message = match error.as_deref() {
                Some(soniox) if soniox.contains("API key") => "Soniox rejected your key. Check it in Settings",
                Some(other) => other,
                None => "No speech detected",
            };
            return self.fail(generation, message);
        }
        let target = {
            let mut dictation = self.dictation.lock().unwrap();
            dictation.control = None;
            dictation.phase = Phase::Idle;
            dictation.target.take()
        };
        self.set_cancel_key(false);
        shell::state_changed(self);

        let app = self.clone();
        spawn(async move {
            let config = app.config();
            // Paste first: the history write is disk I/O the user should not wait on.
            let outcome = paste::paste_at_cursor(&text, config.auto_paste, config.restore_clipboard).await;
            let note = match (&error, outcome) {
                (Some(_), Outcome::Pasted) => Some("Connection lost. Partial text pasted"),
                (Some(_), Outcome::CopiedOnly) => Some("Connection lost. Partial text copied"),
                (None, Outcome::CopiedOnly) if config.auto_paste => Some("Copied. Press Ctrl+V to paste"),
                _ => None,
            };
            match note {
                Some(note) => app.hide_pill(json!({ "state": "fail", "message": note }), Duration::from_millis(2600)),
                None => app.hide_pill(json!({ "state": "idle" }), Duration::from_millis(350)),
            }
            let entry =
                NewEntry { text: &text, duration_ms: Some(duration_ms), title: None, started_at: None, kind: Kind::Dictation, app: target };
            let _ = app.store.lock().unwrap().record(entry);
            let _ = app.handle.emit("history", ());
            shell::state_changed(&app);
        });
    }

    /* ---------------------------------- pill --------------------------------- */

    fn show_pill(&self, payload: serde_json::Value) {
        self.pill.fetch_add(1, Ordering::SeqCst);
        shell::show_pill(&self.handle);
        self.update_pill(payload);
    }

    fn update_pill(&self, payload: serde_json::Value) {
        let _ = self.handle.emit_to("pill", "pill", payload);
    }

    /// Shows the closing state, then takes the window away unless a new
    /// dictation claimed it in the meantime.
    fn hide_pill(self: &Arc<Self>, payload: serde_json::Value, after: Duration) {
        let generation = self.pill.fetch_add(1, Ordering::SeqCst) + 1;
        self.update_pill(payload);
        let app = self.clone();
        spawn(async move {
            tokio::time::sleep(after).await;
            if app.pill.load(Ordering::SeqCst) == generation {
                app.update_pill(json!({ "state": "hidden" }));
                shell::hide_pill(&app.handle);
            }
        });
    }
}
