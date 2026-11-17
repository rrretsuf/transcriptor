use crate::audio::Capture;
use crate::config::Config;
use crate::dsp::{Chunk, SilenceDetector};
use futures_util::{SinkExt, Stream, StreamExt};
use serde::{Deserialize, Deserializer, Serialize};
use std::collections::VecDeque;
use std::time::{Duration, Instant};
use tokio::sync::mpsc::UnboundedReceiver;
use tokio_tungstenite::tungstenite::Message;

const URL: &str = "wss://stt-rt.soniox.com/transcribe-websocket";
const API: &str = "https://api.soniox.com/v1/";
const CHUNK_BYTES: usize = 1280;
const MAX_BUFFER_BYTES: usize = 16000 * 2 * 15;

/* -------------------------------- protocol -------------------------------- */

#[derive(Serialize)]
pub struct ConfigMessage {
    api_key: String,
    model: String,
    audio_format: &'static str,
    sample_rate: u32,
    num_channels: u32,
    enable_endpoint_detection: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    enable_speaker_diarization: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    language_hints: Option<Vec<String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    context: Option<Context>,
    #[serde(skip_serializing_if = "Option::is_none")]
    translation: Option<Translation>,
}

#[derive(Serialize)]
pub struct Context {
    terms: Vec<String>,
}

impl Context {
    /// None when there is nothing to tell Soniox.
    pub fn new(terms: Vec<String>) -> Option<Self> {
        (!terms.is_empty()).then_some(Self { terms })
    }
}

#[derive(Serialize)]
struct Translation {
    r#type: &'static str,
    target_language: String,
}

pub fn config_message(api_key: &str, config: &Config) -> ConfigMessage {
    ConfigMessage {
        api_key: api_key.into(),
        model: config.model.clone(),
        audio_format: "s16le",
        sample_rate: 16000,
        num_channels: 1,
        enable_endpoint_detection: true,
        enable_speaker_diarization: config.label_speakers.then_some(true),
        language_hints: (!config.language_hints.is_empty()).then(|| config.language_hints.clone()),
        context: Context::new(config.terms()),
        translation: (!config.translate_to.is_empty())
            .then(|| Translation { r#type: "one_way", target_language: config.translate_to.clone() }),
    }
}

/// Soniox sends some values as a string or a number depending on the message.
pub fn flexible<'de, D: Deserializer<'de>>(deserializer: D) -> Result<Option<String>, D::Error> {
    Ok(match serde_json::Value::deserialize(deserializer)? {
        serde_json::Value::String(s) => Some(s),
        serde_json::Value::Number(n) => Some(n.to_string()),
        _ => None,
    })
}

#[derive(Deserialize, Default)]
#[serde(default)]
pub struct Token {
    pub text: String,
    pub is_final: bool,
    pub translation_status: Option<String>,
    #[serde(deserialize_with = "flexible")]
    pub speaker: Option<String>,
}

#[derive(Deserialize, Default)]
#[serde(default)]
pub struct Incoming {
    pub tokens: Option<Vec<Token>>,
    pub finished: Option<bool>,
    #[serde(deserialize_with = "flexible")]
    pub error_code: Option<String>,
    pub error_message: Option<String>,
}

/// A new paragraph with "Speaker N:" wherever the voice changes. Soniox only
/// sends speakers when diarization is on, so dictation never gets a label.
pub fn speaker_mark(speaker: Option<&str>, last: &mut Option<String>) -> String {
    match speaker {
        Some(speaker) if last.as_deref() != Some(speaker) => {
            *last = Some(speaker.to_string());
            format!("\n\nSpeaker {speaker}: ")
        }
        _ => String::new(),
    }
}

/// Drops "<end>"-style specials; when translating, only translated tokens are kept.
pub fn keep_token(token: &Token, translate_to: &str) -> bool {
    let text = &token.text;
    if text.chars().count() > 2 && text.starts_with('<') && text.ends_with('>') && !text[1..text.len() - 1].contains('>') {
        return false;
    }
    translate_to.is_empty() || token.translation_status.as_deref() == Some("translation")
}

/// Whitespace runs become one space; a run with a line break stays one blank
/// line, which is how speaker turns are kept apart.
pub fn collapse(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut run: Option<bool> = None;
    for c in text.chars() {
        if c.is_whitespace() {
            run = Some(run.unwrap_or(false) || c == '\n');
            continue;
        }
        if let Some(line_break) = run.take() {
            if !out.is_empty() {
                out.push_str(if line_break { "\n\n" } else { " " });
            }
        }
        out.push(c);
    }
    out
}

/* --------------------------------- session -------------------------------- */

pub enum Event {
    Transcript { final_text: String, partial: String },
    Level(f32),
    /// Silence ended the recording; the last words are still on their way.
    Stopping,
    /// `error` with a non-empty `text` means the connection dropped mid-way.
    Done { text: String, duration_ms: f64, error: Option<String> },
}

pub enum Control {
    Stop,
    Cancel,
}

async fn next_message<S: Stream + Unpin>(stream: &mut Option<S>) -> Option<S::Item> {
    match stream {
        Some(stream) => stream.next().await,
        None => std::future::pending().await,
    }
}

/// One stretch of speech: audio chunks go up as they are captured, tokens come
/// back, and it ends with exactly one `Done` (none after `Cancel`).
pub async fn run_session(
    config: Config,
    api_key: String,
    capture: Capture,
    chunks: UnboundedReceiver<Chunk>,
    control: UnboundedReceiver<Control>,
    emit: impl Fn(Event),
) {
    // The end-to-end tests point this at a local stand-in for Soniox.
    let url = std::env::var("TRANSCRIPTOR_SONIOX_URL").unwrap_or(URL.into());
    session(&url, config, api_key, capture, chunks, control, emit).await
}

async fn session(
    url: &str,
    config: Config,
    api_key: String,
    mut capture: Capture,
    mut chunks: UnboundedReceiver<Chunk>,
    mut control: UnboundedReceiver<Control>,
    emit: impl Fn(Event),
) {
    let started = Instant::now();
    let elapsed_ms = || (started.elapsed().as_secs_f64() * 1000.0).round();
    let mut captured_ms: Option<f64> = None;
    let mut detector = SilenceDetector::new(config.silence_stop_ms);
    let mut final_text = String::new();
    let mut partial = String::new();
    let mut last_speaker: Option<String> = None;
    let mut audio_chunks = 0usize;
    let mut audio_done = false;
    let mut queue: VecDeque<Vec<u8>> = VecDeque::new();
    let mut sink = None;
    let mut stream = None;
    let mut finish_deadline: Option<tokio::time::Instant> = None;
    let config_json = serde_json::to_string(&config_message(&api_key, &config)).unwrap_or_default();

    let connect = tokio::time::timeout(Duration::from_secs(10), tokio_tungstenite::connect_async(url));
    tokio::pin!(connect);
    let mut connecting = true;
    let mut listening = true;

    let outcome: Result<(), String> = loop {
        tokio::select! {
            command = control.recv(), if listening => match command {
                Some(Control::Stop) => {
                    if captured_ms.is_none() {
                        captured_ms = Some(elapsed_ms());
                        capture.stop();
                    }
                }
                Some(Control::Cancel) => return,
                // The owner let go. Before Stop that is a cancel; after Stop the
                // last words are still owed.
                None if captured_ms.is_none() => return,
                None => listening = false,
            },
            connected = &mut connect, if connecting => {
                connecting = false;
                let (mut tx, rx) = match connected {
                    Ok(Ok((socket, _))) => socket.split(),
                    Ok(Err(_)) => break Err("Soniox unreachable".into()),
                    Err(_) => break Err("Connection timed out".into()),
                };
                let mut sent = tx.send(Message::text(config_json.clone())).await;
                for pcm in queue.drain(..) {
                    if sent.is_ok() { sent = tx.send(Message::binary(pcm)).await; }
                }
                if sent.is_ok() && audio_done {
                    sent = tx.send(Message::text("")).await;
                    finish_deadline = Some(tokio::time::Instant::now() + Duration::from_secs(8));
                }
                if sent.is_err() { break Err("Soniox unreachable".into()); }
                sink = Some(tx);
                stream = Some(rx);
            },
            chunk = chunks.recv(), if !audio_done => match chunk {
                Some(chunk) => {
                    audio_chunks += 1;
                    emit(Event::Level(chunk.rms));
                    if captured_ms.is_none() && detector.feed(f64::from(chunk.rms), elapsed_ms()) {
                        captured_ms = Some(elapsed_ms());
                        capture.stop();
                        emit(Event::Stopping);
                    }
                    let waiting = (queue.len() + chunks.len()) * CHUNK_BYTES;
                    if waiting >= MAX_BUFFER_BYTES { break Err("Connection is too slow".into()); }
                    match sink.as_mut() {
                        Some(tx) => if tx.send(Message::binary(chunk.pcm)).await.is_err() {
                            break Err("Connection closed before transcription completed".into());
                        },
                        None => queue.push_back(chunk.pcm),
                    }
                }
                // The flushed tail was the last element: every chunk has reached the
                // socket, so the terminator can go out behind them.
                None => {
                    audio_done = true;
                    // Nothing captured (hotkey tapped twice, dead input): end quietly.
                    if audio_chunks == 0 { break Ok(()); }
                    if let Some(tx) = sink.as_mut() {
                        if tx.send(Message::text("")).await.is_err() {
                            break Err("Connection closed before transcription completed".into());
                        }
                        finish_deadline = Some(tokio::time::Instant::now() + Duration::from_secs(8));
                    }
                }
            },
            message = next_message(&mut stream) => {
                let text = match message {
                    Some(Ok(Message::Text(text))) => text,
                    Some(Ok(Message::Close(_))) | Some(Err(_)) | None =>
                        break Err("Connection closed before transcription completed".into()),
                    Some(Ok(_)) => continue,
                };
                let Ok(message) = serde_json::from_str::<Incoming>(text.as_str()) else { continue };
                if let Some(code) = message.error_code {
                    break Err(message.error_message.unwrap_or(format!("Soniox error {code}")));
                }
                if let Some(tokens) = message.tokens {
                    let mut speaker = last_speaker.clone();
                    partial.clear();
                    for token in tokens.iter().filter(|t| keep_token(t, &config.translate_to)) {
                        let mark = speaker_mark(token.speaker.as_deref(), &mut speaker);
                        if token.is_final {
                            final_text += &mark;
                            final_text += &token.text;
                            last_speaker = speaker.clone();
                        } else {
                            partial += &mark;
                            partial += &token.text;
                        }
                    }
                    emit(Event::Transcript { final_text: final_text.clone(), partial: partial.clone() });
                }
                if message.finished == Some(true) { break Ok(()); }
            },
            _ = tokio::time::sleep_until(finish_deadline.unwrap_or_else(tokio::time::Instant::now)), if finish_deadline.is_some() => {
                break Err("Final transcription timed out".into());
            },
        }
    };

    drop(capture);
    emit(Event::Done {
        text: collapse(&(final_text + &partial)),
        duration_ms: captured_ms.unwrap_or_else(elapsed_ms),
        error: outcome.err(),
    });
}

/* ----------------------------------- REST ---------------------------------- */

pub fn http() -> reqwest::Client {
    reqwest::Client::builder().connect_timeout(Duration::from_secs(10)).build().unwrap_or_default()
}

pub fn endpoint(path: &str) -> String {
    format!("{API}{path}")
}

/// Ok(true): the key works. Ok(false): Soniox rejected it. Err: Soniox could not be reached.
pub async fn validate_key(api_key: &str) -> Result<bool, String> {
    let response = http()
        .get(endpoint("models"))
        .bearer_auth(api_key)
        .timeout(Duration::from_secs(10))
        .send()
        .await
        .map_err(|_| "Could not reach Soniox. Check your connection.".to_string())?;
    match response.status().as_u16() {
        200..=299 => Ok(true),
        401 | 403 => Ok(false),
        code => Err(format!("Soniox error {code}")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::{json, Value};

    fn decode(json: &str) -> Incoming {
        serde_json::from_str(json).unwrap()
    }

    fn token(text: &str, status: Option<&str>) -> Token {
        Token { text: text.into(), is_final: true, translation_status: status.map(String::from), speaker: None }
    }

    fn message(config: &Config) -> Value {
        serde_json::to_value(config_message("k", config)).unwrap()
    }

    #[test]
    fn decodes_token_message() {
        let message = decode(r#"{"tokens":[{"text":"hello","is_final":true},{"text":" world","is_final":false}]}"#);
        let tokens = message.tokens.unwrap();
        assert_eq!(tokens.len(), 2);
        assert_eq!(tokens[0].text, "hello");
        assert!(tokens[0].is_final);
        assert!(!tokens[1].is_final);
        assert_eq!(message.finished, None);
    }

    #[test]
    fn decodes_error_message() {
        let string = decode(r#"{"error_code":"invalid_api_key","error_message":"bad key"}"#);
        assert_eq!(string.error_code.as_deref(), Some("invalid_api_key"));
        assert_eq!(string.error_message.as_deref(), Some("bad key"));
        assert_eq!(decode(r#"{"error_code":500}"#).error_code.as_deref(), Some("500"));
    }

    #[test]
    fn decodes_finished_and_speaker() {
        assert_eq!(decode(r#"{"finished":true}"#).finished, Some(true));
        let tokens = decode(r#"{"tokens":[{"text":"hi","is_final":true,"speaker":"2"},{"text":"yo","speaker":3}]}"#).tokens.unwrap();
        assert_eq!(tokens[0].speaker.as_deref(), Some("2"));
        assert_eq!(tokens[1].speaker.as_deref(), Some("3"));
    }

    #[test]
    fn keep_token_drops_specials() {
        assert!(!keep_token(&token("<end>", None), ""));
        assert!(!keep_token(&token("<end>", None), "en"));
        assert!(keep_token(&token("hi", None), ""));
        for kept in ["<>", "<a>b>", "a<b>", " <end>", "<č"] {
            assert!(keep_token(&token(kept, None), ""), "{kept}");
        }
    }

    #[test]
    fn translation_keeps_only_translated_tokens() {
        let original = token("izvirnik", Some("original"));
        let translated = token("translated", Some("translation"));
        assert!(!keep_token(&original, "en"));
        assert!(keep_token(&translated, "en"));
        assert!(keep_token(&original, ""));
    }

    #[test]
    fn config_message_carries_everything() {
        let config = Config { context: "Soniox, Filip Kustec\nENKI".into(), translate_to: "en".into(), ..Config::default() };
        let object = message(&config);
        assert_eq!(object["api_key"], "k");
        assert_eq!(object["model"], "stt-rt-v6");
        assert_eq!(object["audio_format"], "s16le");
        assert_eq!(object["sample_rate"], 16000);
        assert_eq!(object["num_channels"], 1);
        assert_eq!(object["enable_endpoint_detection"], true);
        assert_eq!(object["language_hints"], json!(["en"]));
        assert_eq!(object["context"]["terms"], json!(["Soniox", "Filip Kustec", "ENKI"]));
        assert_eq!(object["translation"], json!({"type": "one_way", "target_language": "en"}));
    }

    #[test]
    fn config_message_omits_empty_optionals() {
        let config = Config { language_hints: vec![], context: "  \n ".into(), ..Config::default() };
        let object = message(&config);
        for key in ["language_hints", "context", "translation", "enable_speaker_diarization"] {
            assert!(object.get(key).is_none(), "{key}");
        }
    }

    #[test]
    fn meetings_ask_for_speakers() {
        let config = Config { label_speakers: true, ..Config::default() };
        assert_eq!(message(&config)["enable_speaker_diarization"], true);
    }

    #[test]
    fn result_whitespace_normalization() {
        assert_eq!(collapse("  hello   world \n "), "hello world");
        assert_eq!(collapse("a\t\tb"), "a b");
        assert_eq!(collapse(""), "");
        assert_eq!(collapse("one. \n\nSpeaker 2:  two \n three"), "one.\n\nSpeaker 2: two\n\nthree");
    }

    /* A local socket that behaves like Soniox, to run whole sessions against. */

    struct Seen {
        config: Value,
        audio_bytes: usize,
        terminated: bool,
    }

    async fn soniox_stand_in(replies: &'static [&'static str]) -> (String, tokio::task::JoinHandle<Seen>) {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("ws://{}", listener.local_addr().unwrap());
        let served = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            let mut socket = tokio_tungstenite::accept_async(stream).await.unwrap();
            let config = serde_json::from_str(socket.next().await.unwrap().unwrap().to_text().unwrap()).unwrap();
            let mut seen = Seen { config, audio_bytes: 0, terminated: false };
            while let Some(Ok(message)) = socket.next().await {
                match message {
                    Message::Binary(audio) => seen.audio_bytes += audio.len(),
                    Message::Text(text) if text.is_empty() => {
                        seen.terminated = true;
                        for reply in replies {
                            socket.send(Message::text(*reply)).await.unwrap();
                        }
                    }
                    _ => {}
                }
            }
            seen
        });
        (url, served)
    }

    struct Run {
        chunks: Option<tokio::sync::mpsc::UnboundedSender<Chunk>>,
        control: Option<tokio::sync::mpsc::UnboundedSender<Control>>,
        done: tokio::task::JoinHandle<Vec<(String, Option<String>)>>,
    }

    /// Starts a session whose microphone is `chunks`; stopping the capture ends that stream.
    fn start(url: String, config: Config) -> Run {
        let (chunks, chunks_rx) = tokio::sync::mpsc::unbounded_channel();
        let (control, control_rx) = tokio::sync::mpsc::unbounded_channel();
        let microphone = std::sync::Arc::new(std::sync::Mutex::new(Some(chunks.clone())));
        let capture = Capture::new(move || drop(microphone.lock().unwrap().take()));
        let done = tokio::spawn(async move {
            let results = std::sync::Mutex::new(Vec::new());
            session(&url, config, "key".into(), capture, chunks_rx, control_rx, |event| {
                if let Event::Done { text, error, .. } = event {
                    results.lock().unwrap().push((text, error));
                }
            })
            .await;
            results.into_inner().unwrap()
        });
        Run { chunks: Some(chunks), control: Some(control), done }
    }

    fn audio(run: &Run, chunks: usize) {
        for _ in 0..chunks {
            run.chunks.as_ref().unwrap().send(Chunk { pcm: vec![0; CHUNK_BYTES], rms: 0.1 }).unwrap();
        }
    }

    const WORDS: &[&str] = &[
        r#"{"tokens":[{"text":"Hello","is_final":true},{"text":" wor","is_final":false}]}"#,
        r#"{"tokens":[{"text":" world","is_final":true},{"text":"<end>","is_final":true}]}"#,
        r#"{"tokens":[],"finished":true}"#,
    ];

    #[tokio::test]
    async fn a_session_sends_config_then_audio_then_the_terminator() {
        let (url, served) = soniox_stand_in(WORDS).await;
        let mut run = start(url, Config { label_speakers: true, ..Config::default() });
        audio(&run, 5); // before the socket is open: queued, not lost
        run.control.as_ref().unwrap().send(Control::Stop).unwrap();
        run.chunks = None;
        assert_eq!(run.done.await.unwrap(), [("Hello world".to_string(), None)]);
        let seen = served.await.unwrap();
        assert_eq!(seen.config["api_key"], "key");
        assert_eq!(seen.config["enable_speaker_diarization"], true);
        assert_eq!(seen.audio_bytes, 5 * CHUNK_BYTES);
        assert!(seen.terminated);
    }

    #[tokio::test]
    async fn the_last_words_arrive_after_the_owner_lets_go() {
        // A paused meeting drops its handle on the segment right after Stop.
        let (url, _served) = soniox_stand_in(WORDS).await;
        let mut run = start(url, Config::default());
        audio(&run, 2);
        run.control.take().unwrap().send(Control::Stop).unwrap();
        run.chunks = None;
        assert_eq!(run.done.await.unwrap(), [("Hello world".to_string(), None)]);
    }

    #[tokio::test]
    async fn cancel_and_an_abandoned_session_report_nothing() {
        let (url, _served) = soniox_stand_in(WORDS).await;
        let run = start(url.clone(), Config::default());
        audio(&run, 2);
        run.control.as_ref().unwrap().send(Control::Cancel).unwrap();
        assert!(run.done.await.unwrap().is_empty());

        let (url, _served) = soniox_stand_in(WORDS).await;
        let mut run = start(url, Config::default());
        run.control = None;
        assert!(run.done.await.unwrap().is_empty());
    }

    #[tokio::test]
    async fn nothing_captured_ends_quietly() {
        let (url, _served) = soniox_stand_in(WORDS).await;
        let mut run = start(url, Config::default());
        run.control.as_ref().unwrap().send(Control::Stop).unwrap();
        run.chunks = None;
        assert_eq!(run.done.await.unwrap(), [(String::new(), None)]);
    }

    #[tokio::test]
    async fn a_soniox_error_keeps_what_was_transcribed() {
        let replies: &[&str] = &[
            r#"{"tokens":[{"text":"Hello","is_final":true}]}"#,
            r#"{"error_code":503,"error_message":"Service overloaded"}"#,
        ];
        let (url, _served) = soniox_stand_in(replies).await;
        let mut run = start(url, Config::default());
        audio(&run, 2);
        run.control.as_ref().unwrap().send(Control::Stop).unwrap();
        run.chunks = None;
        assert_eq!(run.done.await.unwrap(), [("Hello".to_string(), Some("Service overloaded".to_string()))]);
    }

    #[tokio::test]
    async fn an_unreachable_server_is_reported() {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("ws://{}", listener.local_addr().unwrap());
        drop(listener);
        let run = start(url, Config::default());
        audio(&run, 1);
        assert_eq!(run.done.await.unwrap(), [(String::new(), Some("Soniox unreachable".to_string()))]);
    }

    #[test]
    fn speaker_mark_only_on_change() {
        let mut last = None;
        let marks: Vec<String> =
            [Some("1"), Some("1"), None, Some("2"), Some("2"), Some("1")].iter().map(|s| speaker_mark(*s, &mut last)).collect();
        assert_eq!(marks, ["\n\nSpeaker 1: ", "", "", "\n\nSpeaker 2: ", "", "\n\nSpeaker 1: "]);
    }
}
