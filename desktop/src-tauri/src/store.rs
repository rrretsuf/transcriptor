use crate::config::Config;
use crate::history::{Entry, Kind, HISTORY_LIMIT};
use serde::{de::DeserializeOwned, Serialize};
use std::io::ErrorKind;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

/// Windows: %APPDATA%\Transcriptor. Linux: $XDG_DATA_HOME/Transcriptor.
/// On macOS this build is for development only and must never reach the Mac
/// app's real database, so it goes to the temp folder.
pub fn data_dir() -> PathBuf {
    if let Some(dir) = std::env::var_os("TRANSCRIPTOR_DATA_DIR") {
        return dir.into();
    }
    #[cfg(target_os = "windows")]
    let base = dirs::config_dir();
    #[cfg(target_os = "linux")]
    let base = dirs::data_dir();
    #[cfg(target_os = "macos")]
    let base = Some(std::env::temp_dir().join("transcriptor-dev"));
    base.unwrap_or_else(std::env::temp_dir).join("Transcriptor")
}

pub fn now_ms() -> f64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs_f64() * 1000.0).unwrap_or(0.0)
}

pub struct Store {
    dir: PathBuf,
    pub config: Config,
    pub history: Vec<Entry>,
    pub last_transcript: String,
    config_readable: bool,
    history_readable: bool,
}

pub struct NewEntry<'a> {
    pub text: &'a str,
    pub duration_ms: Option<f64>,
    pub title: Option<String>,
    pub started_at: Option<f64>,
    pub kind: Kind,
    pub app: Option<String>,
}

impl Store {
    pub fn new(dir: PathBuf) -> Self {
        Self {
            dir,
            config: Config::default(),
            history: Vec::new(),
            last_transcript: String::new(),
            config_readable: true,
            history_readable: true,
        }
    }

    /// Returns the names of files that exist but could not be parsed. Those files
    /// are kept intact and never overwritten.
    pub fn load(&mut self) -> Vec<&'static str> {
        let _ = std::fs::create_dir_all(&self.dir);
        let mut unreadable = Vec::new();
        match read::<Config>(&self.dir.join("config.json")) {
            Ok(Some(config)) => self.config = config,
            Ok(None) => {}
            Err(_) => {
                self.config_readable = false;
                unreadable.push("config");
            }
        }
        match read::<Vec<Entry>>(&self.dir.join("history.json")) {
            Ok(Some(history)) => {
                self.last_transcript = history.first().map(|e| e.text.clone()).unwrap_or_default();
                self.history = history;
            }
            Ok(None) => {}
            Err(_) => {
                self.history_readable = false;
                unreadable.push("history");
            }
        }
        unreadable
    }

    pub fn save_config(&mut self, next: Config) -> Result<(), String> {
        if !self.config_readable {
            return Err("Settings file could not be read. It has not been overwritten.".into());
        }
        write(&self.dir.join("config.json"), &next)?;
        self.config = next;
        Ok(())
    }

    pub fn save_history(&mut self, next: Vec<Entry>) -> Result<(), String> {
        if !self.history_readable {
            return Err("History file could not be read. It has not been overwritten.".into());
        }
        write(&self.dir.join("history.json"), &next)?;
        self.history = next;
        Ok(())
    }

    /// Returns the new entry's id, or None when history is off.
    pub fn record(&mut self, new: NewEntry) -> Result<Option<String>, String> {
        self.last_transcript = new.text.to_string();
        if !self.config.save_history {
            return Ok(None);
        }
        let entry = Entry {
            app: new.app,
            at: now_ms(),
            duration_ms: new.duration_ms,
            id: uuid::Uuid::new_v4().to_string(),
            kind: new.kind,
            started_at: new.started_at,
            text: new.text.to_string(),
            title: new.title,
            words: Some(new.text.split_whitespace().count() as u64),
        };
        let id = entry.id.clone();
        let mut dictations = 0;
        let next = std::iter::once(entry)
            .chain(self.history.iter().cloned())
            .filter(|e| {
                if e.kind != Kind::Dictation {
                    return true;
                }
                dictations += 1;
                dictations <= HISTORY_LIMIT
            })
            .collect();
        self.save_history(next)?;
        Ok(Some(id))
    }

    pub fn retitle(&mut self, id: &str, title: &str) {
        let Some(index) = self.history.iter().position(|e| e.id == id) else { return };
        if self.history[index].title.as_deref() == Some(title) {
            return;
        }
        let mut next = self.history.clone();
        next[index].title = Some(title.to_string());
        let _ = self.save_history(next);
    }

    pub fn delete(&mut self, id: &str) -> Result<(), String> {
        let removed = self.history.iter().find(|e| e.id == id).map(|e| e.text.clone());
        self.save_history(self.history.iter().filter(|e| e.id != id).cloned().collect())?;
        if removed.as_deref() == Some(self.last_transcript.as_str()) {
            self.last_transcript.clear();
        }
        Ok(())
    }
}

fn read<T: DeserializeOwned>(path: &Path) -> Result<Option<T>, String> {
    match std::fs::read(path) {
        Ok(bytes) => serde_json::from_slice(&bytes).map(Some).map_err(|e| e.to_string()),
        Err(e) if e.kind() == ErrorKind::NotFound => Ok(None),
        Err(e) => Err(e.to_string()),
    }
}

fn write(path: &Path, value: &impl Serialize) -> Result<(), String> {
    let tmp = path.with_extension("json.tmp");
    let json = serde_json::to_vec_pretty(value).map_err(|e| e.to_string())?;
    std::fs::write(&tmp, json).map_err(|e| e.to_string())?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o600));
    }
    std::fs::rename(&tmp, path).map_err(|e| e.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_store() -> (Store, PathBuf) {
        let dir = std::env::temp_dir().join(format!("transcriptor-test-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        (Store::new(dir.clone()), dir)
    }

    fn entry<'a>(text: &'a str, title: Option<&str>, kind: Kind) -> NewEntry<'a> {
        NewEntry { text, duration_ms: Some(10.0), title: title.map(String::from), started_at: None, kind, app: None }
    }

    #[test]
    fn corrupt_files_are_kept_intact_and_never_overwritten() {
        let (mut store, dir) = temp_store();
        std::fs::write(dir.join("config.json"), "not json").unwrap();
        std::fs::write(dir.join("history.json"), r#"[{"at":1}]"#).unwrap();
        assert_eq!(store.load(), ["config", "history"]);
        assert!(store.save_config(Config::default()).is_err());
        assert!(store.record(entry("new", None, Kind::Dictation)).is_err());
        assert_eq!(std::fs::read_to_string(dir.join("config.json")).unwrap(), "not json");
        assert_eq!(std::fs::read_to_string(dir.join("history.json")).unwrap(), r#"[{"at":1}]"#);
    }

    #[test]
    fn missing_files_are_readable() {
        let (mut store, _) = temp_store();
        assert!(store.load().is_empty());
        assert_eq!(store.config, Config::default());
    }

    #[test]
    fn meeting_keeps_name_and_span_across_reload_and_rename() {
        let (mut store, dir) = temp_store();
        store.load();
        let start = now_ms() - 3_600_000.0;
        let id = store
            .record(NewEntry { started_at: Some(start), ..entry("hello team", Some("Standup"), Kind::Meeting) })
            .unwrap()
            .unwrap();
        store.record(entry("plain dictation", None, Kind::Dictation)).unwrap();
        store.retitle(&id, "Weekly standup");

        let mut reloaded = Store::new(dir);
        reloaded.load();
        let meeting = reloaded.history.iter().find(|e| e.id == id).unwrap();
        assert_eq!(meeting.title.as_deref(), Some("Weekly standup"));
        assert_eq!(meeting.started_at, Some(start));
        assert_eq!(reloaded.history.iter().filter(|e| e.kind == Kind::Meeting).count(), 1);
        assert_eq!(reloaded.last_transcript, "plain dictation");
    }

    #[test]
    fn cap_drops_only_the_oldest_dictations() {
        let (mut store, _) = temp_store();
        store.load();
        let mut history: Vec<Entry> = (0..HISTORY_LIMIT)
            .map(|i| serde_json::from_value(serde_json::json!({"id": i.to_string(), "text": "entry", "at": i})).unwrap())
            .collect();
        history.push(serde_json::from_str(r#"{"id":"m","text":"old meeting","at":0,"title":"Kickoff"}"#).unwrap());
        history.push(serde_json::from_str(r#"{"id":"f","text":"old file","at":0,"title":"call.m4a","kind":"file"}"#).unwrap());
        store.save_history(history).unwrap();
        store.record(NewEntry { app: Some("Slack".into()), ..entry("new", None, Kind::Dictation) }).unwrap();
        assert_eq!(store.history.iter().filter(|e| e.kind == Kind::Dictation).count(), HISTORY_LIMIT);
        assert_eq!(store.history[0].text, "new");
        assert_eq!(store.history[0].app.as_deref(), Some("Slack"));
        assert!(!store.history.iter().any(|e| e.id == (HISTORY_LIMIT - 1).to_string()));
        let tail: Vec<&str> = store.history.iter().rev().take(2).map(|e| e.id.as_str()).collect();
        assert_eq!(tail, ["f", "m"]);
    }

    #[test]
    fn last_transcript_updates_when_history_is_off() {
        let (mut store, dir) = temp_store();
        store.load();
        store.save_config(Config { save_history: false, ..Config::default() }).unwrap();
        assert_eq!(store.record(entry("kept", None, Kind::Dictation)).unwrap(), None);
        assert_eq!(store.last_transcript, "kept");
        assert!(!dir.join("history.json").exists());
    }

    #[test]
    fn writes_are_atomic_pretty_and_sorted() {
        let (mut store, dir) = temp_store();
        store.load();
        store.save_config(Config { hotkey: "Control+K".into(), ..Config::default() }).unwrap();
        let raw = std::fs::read_to_string(dir.join("config.json")).unwrap();
        assert!(raw.contains('\n'));
        let keys: Vec<&str> = raw.lines().filter_map(|l| l.trim().strip_prefix('"')?.split_once("\":").map(|(key, _)| key)).collect();
        let mut sorted = keys.clone();
        sorted.sort();
        assert_eq!(keys, sorted);
        assert_eq!(serde_json::from_str::<Config>(&raw).unwrap().hotkey, "Control+K");
        assert!(!dir.join("config.json.tmp").exists());
    }

    #[test]
    fn deleting_the_last_transcript_clears_it() {
        let (mut store, _) = temp_store();
        store.load();
        let id = store.record(entry("gone", None, Kind::Dictation)).unwrap().unwrap();
        store.delete(&id).unwrap();
        assert!(store.history.is_empty());
        assert_eq!(store.last_transcript, "");
    }
}
