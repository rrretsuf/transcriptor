use serde::{Deserialize, Serialize};

/// Dictations beyond this many fall off; meetings and files are kept for good.
pub const HISTORY_LIMIT: usize = 5000;

#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Kind {
    Dictation,
    Meeting,
    File,
}

// Same entries as the Mac app's history.json. Fields stay in alphabetical order
// so the file is written with sorted keys.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(from = "Stored", rename_all = "camelCase")]
pub struct Entry {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub app: Option<String>,
    pub at: f64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub duration_ms: Option<f64>,
    pub id: String,
    pub kind: Kind,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub started_at: Option<f64>,
    pub text: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub words: Option<u64>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Stored {
    app: Option<String>,
    at: f64,
    duration_ms: Option<f64>,
    #[serde(default)]
    id: String,
    kind: Option<Kind>,
    started_at: Option<f64>,
    text: String,
    title: Option<String>,
    words: Option<u64>,
}

impl From<Stored> for Entry {
    fn from(s: Stored) -> Self {
        // Entries saved before `kind` existed: a title meant a meeting.
        let kind = s.kind.unwrap_or(if s.title.is_some() { Kind::Meeting } else { Kind::Dictation });
        Self {
            app: s.app,
            at: s.at,
            duration_ms: s.duration_ms,
            id: s.id,
            kind,
            started_at: s.started_at,
            text: s.text,
            title: s.title,
            words: s.words,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn old_entries_take_their_kind_from_the_title() {
        let entries: Vec<Entry> = serde_json::from_str(
            r#"[{"text":"hi","at":1},{"text":"notes","at":2,"title":"Standup","startedAt":1},
                {"id":"f","text":"x","at":3,"title":"call.m4a","kind":"file","durationMs":1200.5,"words":1}]"#,
        )
        .unwrap();
        assert_eq!(entries[0].kind, Kind::Dictation);
        assert_eq!(entries[0].id, "");
        assert_eq!(entries[1].kind, Kind::Meeting);
        assert_eq!(entries[2].kind, Kind::File);
        assert_eq!(entries[2].duration_ms, Some(1200.5));
    }

    #[test]
    fn text_and_time_are_required() {
        assert!(serde_json::from_str::<Vec<Entry>>(r#"[{"at":1}]"#).is_err());
        assert!(serde_json::from_str::<Vec<Entry>>(r#"[{"text":"x"}]"#).is_err());
    }

    #[test]
    fn times_written_by_the_mac_app_survive_to_the_last_digit() {
        let entry: Entry = serde_json::from_str(r#"{"text":"hi","at":1794943465812.0667,"startedAt":1763385600123.4568}"#).unwrap();
        let written = serde_json::to_string(&entry).unwrap();
        assert!(written.contains("1794943465812.0667") && written.contains("1763385600123.4568"), "{written}");
        assert_eq!(serde_json::from_str::<Entry>(&written).unwrap(), entry);
    }

    #[test]
    fn empty_optionals_are_not_written() {
        let entry: Entry = serde_json::from_str(r#"{"text":"hi","at":1}"#).unwrap();
        let value = serde_json::to_value(&entry).unwrap();
        assert!(value.get("title").is_none());
        assert!(value.get("app").is_none());
        assert_eq!(value["kind"], "dictation");
    }
}
