use crate::config::Config;
use crate::soniox::{collapse, endpoint, flexible, http, speaker_mark, Context};
use serde::{de::DeserializeOwned, Deserialize, Serialize};
use std::path::Path;
use std::time::Duration;

// Soniox async API: upload a file, wait for its transcript, delete both after.
// The file goes up as it is; Soniox reads the audio track of video itself.

const MODEL: &str = "stt-async-v6";

#[derive(Clone, Copy)]
pub enum Stage {
    Uploading,
    Transcribing,
}

#[derive(Deserialize, Default)]
#[serde(default)]
struct Job {
    id: String,
    status: Option<String>,
    error_message: Option<String>,
    message: Option<String>,
    audio_duration_ms: Option<f64>,
}

#[derive(Serialize)]
struct NewJob<'a> {
    model: &'static str,
    file_id: &'a str,
    #[serde(skip_serializing_if = "Option::is_none")]
    language_hints: Option<&'a [String]>,
    #[serde(skip_serializing_if = "Option::is_none")]
    context: Option<Context>,
    enable_speaker_diarization: bool,
}

#[derive(Deserialize)]
struct TranscriptToken {
    text: String,
    #[serde(default, deserialize_with = "flexible")]
    speaker: Option<String>,
}

#[derive(Deserialize)]
struct Transcript {
    text: String,
    #[serde(default)]
    tokens: Vec<TranscriptToken>,
}

impl Transcript {
    /// Speaker labels only once a second voice is heard.
    fn labeled(&self) -> String {
        let mut speakers: Vec<&str> = self.tokens.iter().filter_map(|t| t.speaker.as_deref()).collect();
        speakers.sort_unstable();
        speakers.dedup();
        if speakers.len() < 2 {
            return self.text.trim().to_string();
        }
        let mut out = String::new();
        let mut last = None;
        for token in &self.tokens {
            out += &speaker_mark(token.speaker.as_deref(), &mut last);
            out += &token.text;
        }
        collapse(&out)
    }
}

/// Soniox keeps files for 30 days unless told otherwise; nothing of the user's
/// should linger, also when the transcription is cancelled half-way.
struct Cleanup {
    api_key: String,
    file: Option<String>,
    job: Option<String>,
}

impl Drop for Cleanup {
    fn drop(&mut self) {
        let (api_key, file, job) = (self.api_key.clone(), self.file.take(), self.job.take());
        tauri::async_runtime::spawn(async move {
            let client = http();
            if let Some(job) = job {
                let _ = client.delete(endpoint(&format!("transcriptions/{job}"))).bearer_auth(&api_key).send().await;
            }
            if let Some(file) = file {
                let _ = client.delete(endpoint(&format!("files/{file}"))).bearer_auth(&api_key).send().await;
            }
        });
    }
}

async fn decode<T: DeserializeOwned>(response: reqwest::Result<reqwest::Response>) -> Result<T, String> {
    let response = response.map_err(|_| "Could not reach Soniox. Check your connection.".to_string())?;
    let code = response.status().as_u16();
    let body = response.bytes().await.map_err(|e| e.to_string())?;
    if !(200..300).contains(&code) {
        if code == 401 {
            return Err("Your Soniox key was rejected".into());
        }
        let message = serde_json::from_slice::<Job>(&body).ok().and_then(|job| job.message);
        return Err(message.unwrap_or(format!("Soniox error {code}")));
    }
    serde_json::from_slice(&body).map_err(|e| e.to_string())
}

pub async fn transcribe(
    path: &Path,
    api_key: &str,
    config: &Config,
    stage: impl Fn(Stage),
) -> Result<(String, Option<f64>), String> {
    let client = http();
    let mut cleanup = Cleanup { api_key: api_key.to_string(), file: None, job: None };

    stage(Stage::Uploading);
    let extension = path.extension().and_then(|e| e.to_str()).unwrap_or("bin");
    let part = reqwest::multipart::Part::file(path)
        .await
        .map_err(|_| "This file cannot be read".to_string())?
        .file_name(format!("audio.{extension}"));
    let form = reqwest::multipart::Form::new().part("file", part);
    let file: Job = decode(client.post(endpoint("files")).bearer_auth(api_key).multipart(form).send().await).await?;
    cleanup.file = Some(file.id.clone());

    stage(Stage::Transcribing);
    let new = NewJob {
        model: MODEL,
        file_id: &file.id,
        language_hints: (!config.language_hints.is_empty()).then_some(&config.language_hints[..]),
        context: Context::new(config.terms()),
        enable_speaker_diarization: true,
    };
    let job: Job = decode(client.post(endpoint("transcriptions")).bearer_auth(api_key).json(&new).send().await).await?;
    cleanup.job = Some(job.id.clone());

    let status = endpoint(&format!("transcriptions/{}", job.id));
    let finished = loop {
        tokio::time::sleep(Duration::from_secs(1)).await;
        let job: Job = decode(client.get(&status).bearer_auth(api_key).send().await).await?;
        match job.status.as_deref() {
            Some("completed") => break job,
            Some("error") => return Err(job.error_message.unwrap_or("Soniox could not transcribe this file".into())),
            _ => {}
        }
    };
    let transcript: Transcript = decode(client.get(format!("{status}/transcript")).bearer_auth(api_key).send().await).await?;
    Ok((transcript.labeled(), finished.audio_duration_ms))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn one_voice_gets_no_labels() {
        let transcript: Transcript =
            serde_json::from_str(r#"{"text":" hello there ","tokens":[{"text":"hello","speaker":"1"},{"text":" there","speaker":"1"}]}"#).unwrap();
        assert_eq!(transcript.labeled(), "hello there");
    }

    #[test]
    fn two_voices_get_a_paragraph_each() {
        let transcript: Transcript = serde_json::from_str(
            r#"{"text":"hi yo","tokens":[{"text":"hi","speaker":"1"},{"text":" yo","speaker":2},{"text":" ok"}]}"#,
        )
        .unwrap();
        assert_eq!(transcript.labeled(), "Speaker 1: hi\n\nSpeaker 2: yo ok");
    }

    #[test]
    fn error_bodies_are_read() {
        let job: Job = serde_json::from_str(r#"{"status_code":401,"message":"Incorrect API key provided."}"#).unwrap();
        assert_eq!(job.message.as_deref(), Some("Incorrect API key provided."));
        assert_eq!(job.id, "");
    }
}
