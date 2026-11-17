use crate::app::App;
use crate::audio::Capture;
use crate::config::Config;
use crate::dsp::Chunk;
use crate::soniox::{run_session, validate_key, Event};
use crate::{audio, keystore, paste, shell};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tauri_plugin_global_shortcut::{GlobalShortcutExt, ShortcutState};
use tokio::sync::mpsc::unbounded_channel;

// What CI runs on real Windows and Linux machines, where no person is there to
// press the hotkey: `--selftest` checks every part that needs no microphone and
// no key, `--selftest-e2e` waits for a real hotkey press and pastes into
// whatever window has the keyboard.

pub enum Mode {
    Checks,
    EndToEnd,
}

/// Feeds 16 kHz mono PCM through a real Soniox session at twice real time.
async fn transcribe_pcm(pcm: Vec<u8>, api_key: String) -> (String, Option<String>) {
    let (chunks_tx, chunks_rx) = unbounded_channel();
    let (_control, commands) = unbounded_channel();
    tokio::spawn(async move {
        for bytes in pcm.chunks(1280) {
            let _ = chunks_tx.send(Chunk { pcm: bytes.to_vec(), rms: 0.1 });
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    });
    let done = Arc::new(Mutex::new((String::new(), None)));
    let result = done.clone();
    run_session(Config::default(), api_key, Capture::new(|| {}), chunks_rx, commands, move |event| {
        if let Event::Done { text, error, .. } = event {
            *result.lock().unwrap() = (text, error);
        }
    })
    .await;
    let outcome = done.lock().unwrap().clone();
    outcome
}

/// `--selftest-file speech.wav`: with SONIOX_API_KEY set the words must come
/// back; without it Soniox must refuse the key. Needs no window system.
pub fn file(path: &str) -> i32 {
    let Ok(wav) = std::fs::read(path) else {
        println!("cannot read {path}");
        return 2;
    };
    let pcm = wav.windows(4).position(|w| w == b"data").map(|at| wav[at + 8..].to_vec()).unwrap_or(wav);
    let key = std::env::var("SONIOX_API_KEY").ok().filter(|k| !k.is_empty());
    let runtime = tokio::runtime::Runtime::new().expect("runtime");
    let (text, error) = runtime.block_on(transcribe_pcm(pcm, key.clone().unwrap_or("invalid-key".into())));
    println!("transcript: {text:?}");
    println!("error: {error:?}");
    let Some(key) = key else { return i32::from(error.is_none()) };
    let uploaded = runtime.block_on(async {
        let result = crate::files::transcribe(std::path::Path::new(path), &key, &Config::default(), |_| {}).await;
        // The upload is deleted from Soniox in the background; let that finish.
        tokio::time::sleep(Duration::from_secs(3)).await;
        result
    });
    println!("file transcription: {uploaded:?}");
    i32::from(text.is_empty() || error.is_some() || !uploaded.is_ok_and(|(text, _)| !text.is_empty()))
}

struct Report {
    lines: Vec<String>,
    failed: bool,
}

impl Report {
    fn check(&mut self, name: &str, ok: bool, detail: impl std::fmt::Display) {
        self.failed |= !ok;
        self.lines.push(format!("{} {name}: {detail}", if ok { "ok  " } else { "FAIL" }));
    }

    fn note(&mut self, name: &str, detail: impl std::fmt::Display) {
        self.lines.push(format!("note {name}: {detail}"));
    }

    fn finish(self, app: &App) {
        let text = self.lines.join("\n");
        println!("{text}");
        let _ = std::fs::write(app.dir.join("selftest.txt"), &text);
        app.handle.exit(i32::from(self.failed));
    }
}

pub fn run(app: Arc<App>, mode: Mode) {
    tauri::async_runtime::spawn(async move {
        let mut report = Report { lines: Vec::new(), failed: false };
        match mode {
            Mode::Checks => checks(&app, &mut report).await,
            Mode::EndToEnd => end_to_end(&app, &mut report).await,
        }
        report.finish(&app);
    });
}

async fn checks(app: &Arc<App>, report: &mut Report) {
    let wayland = shell::platform()["wayland"] == true;
    let problem = app.hotkey_problem.lock().unwrap().clone();
    if wayland {
        report.note("hotkey", "Wayland session, the desktop owns global keys");
    } else {
        report.check("hotkey registered", problem.is_none(), problem.unwrap_or(app.hotkey_label()));
    }

    // Written back as it is: a self-test on a real installation changes no setting.
    let current = app.config();
    let saved = app.store.lock().unwrap().save_config(current.clone());
    let mut reloaded = crate::store::Store::new(app.dir.clone());
    reloaded.load();
    report.check("config round trip", saved.is_ok() && reloaded.config == current, app.dir.display());

    let devices = tauri::async_runtime::spawn_blocking(audio::devices).await.unwrap();
    report.note(
        "audio",
        format!("host={} input={:?} output={:?} system_audio={}", devices.host, devices.input, devices.output, devices.system_audio),
    );

    // "mic" or "system": the test bench is playing sound into that source and it must be heard.
    let expected = std::env::var("TRANSCRIPTOR_EXPECT_AUDIO").unwrap_or_default();
    for (name, system) in [("microphone capture", false), ("microphone + system audio capture", true)] {
        let Ok(Ok((capture, mut chunks))) = tauri::async_runtime::spawn_blocking(move || audio::start(system)).await else {
            report.check(name, expected.is_empty(), "no input device");
            continue;
        };
        let started = std::time::Instant::now();
        let (mut count, mut loudest, mut first, mut last, mut gap) = (0, 0.0_f32, 0, 0, 0);
        while let Ok(Some(chunk)) = tokio::time::timeout(Duration::from_millis(2000u64.saturating_sub(last)), chunks.recv()).await {
            let now = started.elapsed().as_millis() as u64;
            if count == 0 {
                first = now;
            }
            gap = gap.max(now - last);
            last = now;
            count += 1;
            loudest = loudest.max(chunk.rms);
        }
        drop(capture);
        let heard = loudest > 0.01;
        let required = (expected == "mic" && !system) || (expected == "system" && system);
        let silent = expected == "system" && !system;
        // Words can only appear as fast as the audio arrives: it must flow, not come in bursts.
        let flowing = count > 40 && first < 600 && gap < 400;
        let detail = format!("{count} chunks in 2 s, first after {first} ms, longest gap {gap} ms, loudest rms {loudest:.3}");
        report.check(name, flowing && (!required || heard) && !(silent && heard), detail);
    }

    let dir = app.dir.clone();
    let stored = tauri::async_runtime::spawn_blocking(move || {
        let written = keystore::set(&dir, "selftest", "secret-value");
        let read = keystore::get(&dir, "selftest");
        let _ = keystore::set(&dir, "selftest", "");
        (written, read, keystore::get(&dir, "selftest"))
    })
    .await
    .unwrap();
    report.check(
        "key store round trip",
        stored.0.is_ok() && stored.1.as_deref() == Some("secret-value") && stored.2.is_none(),
        format!("{:?}", stored.0),
    );

    shell::show_pill(&app.handle);
    tokio::time::sleep(Duration::from_millis(600)).await;
    let visible = tauri::Manager::get_webview_window(&app.handle, "pill").is_some_and(|w| w.is_visible().unwrap_or(false));
    shell::hide_pill(&app.handle);
    report.check("pill window", visible, "shown and hidden");

    if cfg!(target_os = "macos") {
        report.note("clipboard", "left alone on the development Mac");
    } else {
        let written = paste::write_clipboard("selftest");
        report.check("clipboard", written && paste::read_clipboard().as_deref() == Some("selftest"), "write and read back");
    }

    let rejected = validate_key("invalid-key").await;
    report.check("Soniox rejects a bad key over HTTPS", rejected == Ok(false), format!("{rejected:?}"));
    let (text, error) = transcribe_pcm(vec![0; 16000 * 2], "invalid-key".into()).await;
    report.check("Soniox rejects a bad key over the socket", text.is_empty() && error.is_some(), format!("{error:?}"));
}

/// With SONIOX_API_KEY: a real dictation, started and stopped by the hotkey.
/// Without: the hotkey pastes a fixed sentence. Either way the text must land
/// in the window that had the keyboard while the pill was on screen.
async fn end_to_end(app: &Arc<App>, report: &mut Report) {
    let key = std::env::var("SONIOX_API_KEY").ok().filter(|k| !k.is_empty());
    let pressed = Arc::new(tokio::sync::Notify::new());
    match &key {
        Some(key) => app.use_key(key.clone()),
        None => {
            let shortcuts = app.handle.global_shortcut();
            let _ = shortcuts.unregister_all();
            let notify = pressed.clone();
            let registered = shortcuts.on_shortcut(app.hotkey().as_str(), move |_, _, event| {
                if event.state() == ShortcutState::Pressed {
                    notify.notify_one();
                }
            });
            report.check("hotkey registered", registered.is_ok(), app.hotkey_label());
        }
    }
    let _ = std::fs::write(app.dir.join("selftest-ready"), "ready");

    if key.is_some() {
        let spoken = async {
            loop {
                tokio::time::sleep(Duration::from_millis(200)).await;
                if let Some(entry) = app.store.lock().unwrap().history.first() {
                    return entry.text.clone();
                }
            }
        };
        let text = tokio::time::timeout(Duration::from_secs(90), spoken).await.unwrap_or_default();
        report.check("dictation by hotkey", !text.is_empty(), format!("{text:?}"));
        tokio::time::sleep(Duration::from_millis(800)).await;
        meeting_from_system_audio(app, report).await;
        return;
    }
    let got = tokio::time::timeout(Duration::from_secs(60), pressed.notified()).await.is_ok();
    report.check("hotkey press arrived", got, "global shortcut");
    if !got {
        return;
    }
    shell::show_pill(&app.handle);
    tokio::time::sleep(Duration::from_millis(700)).await;
    let outcome = paste::paste_at_cursor("Hello from Transcriptor", true, false).await;
    report.check("paste keys sent", outcome == paste::Outcome::Pasted, "Ctrl+V");
    tokio::time::sleep(Duration::from_millis(500)).await;
    shell::hide_pill(&app.handle);
}

/// A meeting whose only sound is what the computer plays: the test bench plays
/// speech into the default output between the two marker files.
async fn meeting_from_system_audio(app: &Arc<App>, report: &mut Report) {
    let status = |app: &Arc<App>| app.meeting.lock().unwrap().snapshot();
    let until = |wanted: &'static str, seconds: u64| async move {
        let reached = async {
            while status(app)["status"] != wanted || (wanted == "recording" && status(app)["runningSince"].is_null()) {
                tokio::time::sleep(Duration::from_millis(100)).await;
            }
        };
        tokio::time::timeout(Duration::from_secs(seconds), reached).await.is_ok()
    };
    crate::meeting::start(app);
    if !until("recording", 15).await {
        return report.check("meeting started", false, status(app)["problem"].to_string());
    }
    let _ = std::fs::write(app.dir.join("selftest-meeting"), "recording");
    let played = app.dir.join("selftest-meeting-played");
    for _ in 0..600 {
        if played.exists() {
            break;
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    tokio::time::sleep(Duration::from_secs(1)).await;
    crate::meeting::end(app);
    let done = until("done", 30).await;
    let saved = app.store.lock().unwrap().history.first().cloned().filter(|e| e.kind == crate::history::Kind::Meeting);
    let ok = done && saved.as_ref().is_some_and(|e| !e.text.is_empty() && e.started_at.is_some());
    let detail = match saved {
        Some(entry) => format!("{:?}, {} ms", entry.text, entry.duration_ms.unwrap_or_default()),
        None => format!("nothing saved, meeting is {}", status(app)),
    };
    report.check("meeting from system audio, saved to history", ok, detail);
}
