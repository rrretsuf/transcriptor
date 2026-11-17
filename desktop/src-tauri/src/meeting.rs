use crate::app::App;
use crate::audio;
use crate::history::Kind;
use crate::soniox::{collapse, run_session, Control, Event};
use crate::store::{now_ms, NewEntry};
use serde_json::{json, Value};
use std::sync::Arc;
use tauri::async_runtime::{spawn, spawn_blocking};
use tauri::Emitter;
use tokio::sync::mpsc::{unbounded_channel, UnboundedSender};

// A live meeting: the microphone plus everything the computer plays, transcribed
// until End. Each stretch between Pause and Continue is its own Soniox session,
// so a pause sends no audio at all and the socket never idles out. The finished
// transcript lands in history under its name, with start and end time.

#[derive(Clone, Copy, PartialEq, Default)]
pub enum Status {
    #[default]
    Idle,
    Recording,
    Paused,
    Finishing,
    Done,
}

#[derive(Default)]
pub struct Meeting {
    status: Status,
    title: String,
    started_at: Option<f64>,
    ended_at: Option<f64>,
    saved_id: Option<String>,
    problem: Option<String>,
    /// Closed segments.
    text: String,
    /// The open segment, partial words included.
    live: String,
    /// Milliseconds recorded in closed segments.
    elapsed_before: f64,
    segment_start: Option<f64>,
    /// The segment that is listening now. A segment that was stopped may still be
    /// waiting for its last words; it is no longer current.
    current: Option<u64>,
    control: Option<UnboundedSender<Control>>,
    last_id: u64,
    /// Segments still waiting for their final words.
    open: u32,
}

impl Meeting {
    pub fn is_active(&self) -> bool {
        matches!(self.status, Status::Recording | Status::Paused | Status::Finishing)
    }

    fn transcript(&self) -> String {
        join(&self.text, &self.live)
    }

    fn display_title(&self) -> String {
        let name = self.title.trim();
        if name.is_empty() { "Untitled meeting".into() } else { name.into() }
    }

    fn close_segment(&mut self) {
        if let Some(start) = self.segment_start.take() {
            self.elapsed_before += now_ms() - start;
        }
        match self.control.take() {
            Some(control) => drop(control.send(Control::Stop)),
            None => self.last_id += 1, // the microphone was still opening: abandon that start
        }
    }

    pub fn snapshot(&self) -> Value {
        let transcript = self.transcript();
        // The live view shows the recent stretch; the finished transcript shows everything.
        let shown = if self.status != Status::Done && transcript.chars().count() > 3000 {
            let tail: String = transcript.chars().skip(transcript.chars().count() - 3000).collect();
            format!("…{}", tail.find(' ').map(|i| &tail[i..]).unwrap_or(&tail))
        } else {
            transcript
        };
        json!({
            "status": match self.status {
                Status::Idle => "idle",
                Status::Recording => "recording",
                Status::Paused => "paused",
                Status::Finishing => "finishing",
                Status::Done => "done",
            },
            "title": self.title,
            "startedAt": self.started_at,
            "endedAt": self.ended_at,
            "problem": self.problem,
            "transcript": shown,
            "elapsedMs": self.elapsed_before,
            "runningSince": self.segment_start,
        })
    }
}

/// Every segment opens with its own "Speaker N:", so each starts a paragraph.
fn join(a: &str, b: &str) -> String {
    match (a.is_empty(), b.is_empty()) {
        (true, _) => b.to_string(),
        (_, true) => a.to_string(),
        _ => format!("{a}\n\n{b}"),
    }
}

fn changed(app: &Arc<App>) {
    let snapshot = app.meeting.lock().unwrap().snapshot();
    let _ = app.handle.emit("meeting", snapshot);
    crate::shell::state_changed(app);
}

pub fn start(app: &Arc<App>) {
    {
        let mut meeting = app.meeting.lock().unwrap();
        if meeting.is_active() {
            return;
        }
        let title = std::mem::take(&mut meeting.title);
        let last_id = meeting.last_id;
        *meeting = Meeting { title, last_id, started_at: Some(now_ms()), ..Meeting::default() };
    }
    begin(app);
}

pub fn toggle_pause(app: &Arc<App>) {
    let status = app.meeting.lock().unwrap().status;
    match status {
        Status::Recording => {
            let mut meeting = app.meeting.lock().unwrap();
            meeting.close_segment();
            meeting.status = Status::Paused;
        }
        Status::Paused => return begin(app),
        _ => return,
    }
    changed(app);
}

pub fn end(app: &Arc<App>) {
    let finished = {
        let mut meeting = app.meeting.lock().unwrap();
        if !matches!(meeting.status, Status::Recording | Status::Paused) {
            return;
        }
        meeting.close_segment();
        meeting.status = Status::Finishing;
        meeting.open == 0
    };
    if finished {
        complete(app);
    }
    changed(app);
}

pub fn reset(app: &Arc<App>) {
    {
        let mut meeting = app.meeting.lock().unwrap();
        if meeting.is_active() {
            return;
        }
        let last_id = meeting.last_id;
        *meeting = Meeting { last_id, ..Meeting::default() };
    }
    changed(app);
}

/// Renaming after the end updates the saved entry too.
pub fn set_title(app: &Arc<App>, title: String) {
    let saved = {
        let mut meeting = app.meeting.lock().unwrap();
        meeting.title = title;
        meeting.saved_id.clone().map(|id| (id, meeting.display_title()))
    };
    if let Some((id, title)) = saved {
        app.store.lock().unwrap().retitle(&id, &title);
        let _ = app.handle.emit("history", ());
    }
}

fn pause_with(app: &Arc<App>, id: u64, problem: String) {
    {
        let mut meeting = app.meeting.lock().unwrap();
        if meeting.last_id != id {
            return;
        }
        meeting.problem = Some(problem);
        meeting.status = Status::Paused;
    }
    changed(app);
}

fn begin(app: &Arc<App>) {
    let id = {
        let mut meeting = app.meeting.lock().unwrap();
        meeting.last_id += 1;
        meeting.status = Status::Recording;
        meeting.problem = None;
        meeting.last_id
    };
    changed(app);
    let app = app.clone();
    spawn(async move {
        let Some(key) = app.api_key().await else {
            return pause_with(&app, id, "Add your Soniox key in Settings first.".into());
        };
        // A fresh capture per segment: the previous one may still be finishing,
        // and its teardown must not stop this one's microphone.
        let (capture, chunks) = match spawn_blocking(|| audio::start(true)).await {
            Ok(Ok(started)) => started,
            Ok(Err(problem)) => return pause_with(&app, id, problem),
            Err(_) => return pause_with(&app, id, "Microphone unavailable".into()),
        };
        let (control, commands) = unbounded_channel();
        {
            let mut meeting = app.meeting.lock().unwrap();
            if meeting.last_id != id || meeting.status != Status::Recording {
                return; // paused or ended while the microphone was opening
            }
            meeting.current = Some(id);
            meeting.control = Some(control);
            meeting.open += 1;
            meeting.segment_start = Some(now_ms());
        }
        changed(&app);
        let mut config = app.config();
        config.silence_stop_ms = 0.0; // meetings have long silences; only End stops them
        config.label_speakers = true;
        let events = app.clone();
        run_session(config, key, capture, chunks, commands, move |event| match event {
            Event::Transcript { final_text, partial } => {
                let mut meeting = events.meeting.lock().unwrap();
                if meeting.current == Some(id) {
                    meeting.live = collapse(&format!("{final_text} {partial}"));
                    let _ = events.handle.emit("meeting", meeting.snapshot());
                }
            }
            Event::Done { text, error, .. } => closed(&events, id, text, error),
            Event::Level(_) | Event::Stopping => {}
        })
        .await;
    });
}

fn closed(app: &Arc<App>, id: u64, segment: String, error: Option<String>) {
    let (finished, reconnect) = {
        let mut meeting = app.meeting.lock().unwrap();
        meeting.open = meeting.open.saturating_sub(1);
        meeting.text = join(&meeting.text, &segment);
        let current = meeting.current == Some(id);
        if current {
            meeting.current = None;
            meeting.control = None;
            meeting.live.clear();
        }
        let finished = meeting.status == Status::Finishing && meeting.open == 0;
        // A dropped connection mid-meeting reconnects on its own; a dead one waits for the user.
        let dropped = !finished && current && meeting.status == Status::Recording && error.is_some();
        if dropped {
            if let Some(start) = meeting.segment_start.take() {
                meeting.elapsed_before += now_ms() - start;
            }
            if segment.is_empty() {
                meeting.problem = error;
                meeting.status = Status::Paused;
            }
        }
        (finished, dropped && !segment.is_empty())
    };
    if finished {
        complete(app);
    }
    if reconnect {
        return begin(app);
    }
    changed(app);
}

fn complete(app: &Arc<App>) {
    let mut meeting = app.meeting.lock().unwrap();
    meeting.status = Status::Done;
    meeting.ended_at = Some(now_ms());
    let transcript = meeting.transcript();
    if transcript.is_empty() {
        return;
    }
    let entry = NewEntry {
        text: &transcript,
        duration_ms: Some(meeting.elapsed_before.round()),
        title: Some(meeting.display_title()),
        started_at: meeting.started_at,
        kind: Kind::Meeting,
        app: None,
    };
    meeting.saved_id = app.store.lock().unwrap().record(entry).ok().flatten();
    drop(meeting);
    let _ = app.handle.emit("history", ());
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn segments_join_as_paragraphs() {
        assert_eq!(join("", "b"), "b");
        assert_eq!(join("a", ""), "a");
        assert_eq!(join("a", "b"), "a\n\nb");
    }

    #[test]
    fn live_view_shows_the_recent_stretch_only() {
        let mut meeting = Meeting { status: Status::Recording, text: "word ".repeat(2000), ..Meeting::default() };
        let live = meeting.snapshot()["transcript"].as_str().unwrap().to_string();
        assert!(live.starts_with('…') && live.chars().count() <= 3001);
        meeting.status = Status::Done;
        assert_eq!(meeting.snapshot()["transcript"].as_str().unwrap().len(), 10000);
    }
}
