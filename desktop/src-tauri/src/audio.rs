use crate::dsp::{Chunk, Chunker, Resampler};
use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use cpal::{ErrorKind, FromSample, Sample, SampleFormat, SizedSample};
use std::collections::VecDeque;
use std::sync::mpsc::{channel, Sender};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::sync::mpsc::{unbounded_channel, UnboundedReceiver, UnboundedSender};

// Raw capture from the default device in shared mode. Nothing here asks for the
// communications role, echo cancellation or exclusive access, so other apps'
// audio keeps playing untouched. The streams exist only while recording.

/// 0.5 s: older system audio is stale by the time the microphone catches up.
const MAX_PENDING: usize = 8000;

/// Stops the capture when dropped. The partial chunk is the stream's last element.
pub struct Capture {
    stop: Option<Box<dyn FnOnce() + Send>>,
}

impl Capture {
    pub fn new(stop: impl FnOnce() + Send + 'static) -> Self {
        Self { stop: Some(Box::new(stop)) }
    }

    pub fn stop(&mut self) {
        if let Some(stop) = self.stop.take() {
            stop();
        }
    }
}

impl Drop for Capture {
    fn drop(&mut self) {
        self.stop();
    }
}

#[derive(Clone, Copy, PartialEq)]
enum Source {
    Microphone,
    System,
}

enum Command {
    Stop,
    Rebuild(Source),
}

struct Shared {
    chunker: Chunker,
    chunks: Option<UnboundedSender<Chunk>>,
    system: VecDeque<f32>,
}

/// Starts the microphone, and with `system_audio` everything the computer plays
/// mixed into it: on speakers the microphone's echo of a call then reads as room
/// reverb, not as every word twice.
pub fn start(system_audio: bool) -> Result<(Capture, UnboundedReceiver<Chunk>), String> {
    let (chunks_tx, chunks_rx) = unbounded_channel();
    let shared = Arc::new(Mutex::new(Shared { chunker: Chunker::new(), chunks: Some(chunks_tx), system: VecDeque::new() }));
    let (commands, inbox) = channel::<Command>();
    let (ready_tx, ready_rx) = channel::<Result<(), String>>();

    let worker_commands = commands.clone();
    std::thread::spawn(move || {
        let host = cpal::default_host();
        let mut microphone = match build(&host, Source::Microphone, &shared, &worker_commands) {
            Ok(stream) => Some(stream),
            Err(error) => {
                let _ = ready_tx.send(Err(error));
                return;
            }
        };
        let mut system = system_audio.then(|| build(&host, Source::System, &shared, &worker_commands).ok()).flatten();
        let _ = ready_tx.send(Ok(()));

        // Headphones in or out mid-recording invalidate the stream. Rebuild it on
        // the new default device once the route settles and keep the same session.
        while let Ok(Command::Rebuild(first)) = inbox.recv() {
            std::thread::sleep(Duration::from_millis(300));
            // Every error about the stream that is gone has queued up by now.
            let mut lost = vec![first];
            let mut stopped = false;
            for command in inbox.try_iter() {
                match command {
                    Command::Stop => stopped = true,
                    Command::Rebuild(source) => lost.push(source),
                }
            }
            if stopped {
                break;
            }
            let host = cpal::default_host();
            if lost.contains(&Source::Microphone) {
                drop(microphone.take()); // the old stream lets go of the device first
                microphone = build(&host, Source::Microphone, &shared, &worker_commands).ok();
                if microphone.is_none() {
                    break;
                }
            }
            if lost.contains(&Source::System) {
                drop(system.take());
                system = build(&host, Source::System, &shared, &worker_commands).ok();
            }
        }
        drop(microphone);
        drop(system);
        let mut shared = shared.lock().unwrap();
        let tail = shared.chunker.flush();
        if let (Some(tail), Some(chunks)) = (tail, shared.chunks.as_ref()) {
            let _ = chunks.send(tail);
        }
        shared.chunks = None;
    });

    match ready_rx.recv() {
        Ok(Ok(())) => Ok((Capture::new(move || drop(commands.send(Command::Stop))), chunks_rx)),
        Ok(Err(error)) => Err(error),
        Err(_) => Err("No microphone is available".into()),
    }
}

fn build(host: &cpal::Host, source: Source, shared: &Arc<Mutex<Shared>>, commands: &Sender<Command>) -> Result<Arc<cpal::Stream>, String> {
    let (device, supported) = match source {
        Source::Microphone => {
            let device = host.default_input_device().ok_or("No microphone is available")?;
            let config = device.default_input_config().map_err(|e| e.to_string())?;
            (device, config)
        }
        Source::System => system_device(host).ok_or("System audio is not available")?,
    };
    let channels = usize::from(supported.channels());
    let mut resampler = Resampler::new(supported.sample_rate());
    let mut resampled: Vec<f32> = Vec::new();
    let shared = shared.clone();
    let on_frames = move |mono: &[f32]| {
        resampled.clear();
        resampler.process(mono, &mut resampled);
        let mut shared = shared.lock().unwrap();
        let shared = &mut *shared;
        match source {
            Source::System => {
                shared.system.extend(&resampled);
                let extra = shared.system.len().saturating_sub(MAX_PENDING);
                shared.system.drain(..extra);
            }
            Source::Microphone => {
                for sample in resampled.iter_mut() {
                    match shared.system.pop_front() {
                        Some(other) => *sample += other,
                        None => break,
                    }
                }
                if let Some(chunks) = shared.chunks.as_ref() {
                    shared.chunker.feed(&resampled, |chunk| drop(chunks.send(chunk)));
                }
            }
        }
    };
    let commands = Mutex::new(commands.clone());
    let on_error = move |error: cpal::Error| {
        if !matches!(error.kind(), ErrorKind::Xrun | ErrorKind::DeviceChanged) {
            let _ = commands.lock().unwrap().send(Command::Rebuild(source));
        }
    };
    let mut config = supported.config();
    // Left alone, PulseAudio hands a recording over two seconds at a time; the
    // words on screen can only be as live as the audio. Ask for 20 ms.
    if let (true, cpal::SupportedBufferSize::Range { min, max }) = (cfg!(target_os = "linux"), supported.buffer_size()) {
        config.buffer_size = cpal::BufferSize::Fixed((supported.sample_rate() / 50).clamp(*min, *max));
    }
    // The microphone is channel 0 (a many-channel interface carries the voice
    // there); what the computer plays is the average of its channels.
    let downmix = source == Source::System;
    let stream = match supported.sample_format() {
        SampleFormat::F32 => typed::<f32>(&device, config, channels, downmix, on_frames, on_error),
        SampleFormat::I16 => typed::<i16>(&device, config, channels, downmix, on_frames, on_error),
        SampleFormat::U16 => typed::<u16>(&device, config, channels, downmix, on_frames, on_error),
        SampleFormat::I32 => typed::<i32>(&device, config, channels, downmix, on_frames, on_error),
        SampleFormat::I24 => typed::<cpal::I24>(&device, config, channels, downmix, on_frames, on_error),
        SampleFormat::U8 => typed::<u8>(&device, config, channels, downmix, on_frames, on_error),
        other => Err(format!("Unsupported sample format {other}")),
    }?;
    // Audio flows as soon as the stream is uncorked, but PulseAudio's `play`
    // can wait up to two seconds for the server to confirm. Nothing here waits for it.
    let stream = Arc::new(stream);
    let starting = stream.clone();
    std::thread::spawn(move || drop(starting.play()));
    Ok(stream)
}

fn typed<T>(
    device: &cpal::Device,
    config: cpal::StreamConfig,
    channels: usize,
    downmix: bool,
    mut on_frames: impl FnMut(&[f32]) + Send + 'static,
    on_error: impl FnMut(cpal::Error) + Send + 'static,
) -> Result<cpal::Stream, String>
where
    T: SizedSample,
    f32: FromSample<T>,
{
    let mut mono: Vec<f32> = Vec::new();
    device
        .build_input_stream(
            config,
            move |data: &[T], _: &cpal::InputCallbackInfo| {
                mono.clear();
                mono.extend(data.chunks_exact(channels.max(1)).map(|frame| {
                    if downmix {
                        frame.iter().map(|s| f32::from_sample(*s)).sum::<f32>() / frame.len() as f32
                    } else {
                        f32::from_sample(frame[0])
                    }
                }));
                on_frames(&mono);
            },
            on_error,
            None,
        )
        .map_err(|e| e.to_string())
}

/// Windows: the default output device, opened for capture, is its loopback.
#[cfg(target_os = "windows")]
fn system_device(host: &cpal::Host) -> Option<(cpal::Device, cpal::SupportedStreamConfig)> {
    let device = host.default_output_device()?;
    let config = device.default_output_config().ok()?;
    Some((device, config))
}

/// PulseAudio and PipeWire expose what a sink plays as the source "<sink>.monitor".
#[cfg(target_os = "linux")]
fn system_device(host: &cpal::Host) -> Option<(cpal::Device, cpal::SupportedStreamConfig)> {
    let sink = host.default_output_device()?.id().ok()?;
    let monitor = format!("{}.monitor", sink.id());
    let device = host.devices().ok()?.find(|d| d.id().is_ok_and(|id| id.id() == monitor))?;
    let config = device.default_input_config().ok()?;
    Some((device, config))
}

#[cfg(target_os = "macos")]
fn system_device(_: &cpal::Host) -> Option<(cpal::Device, cpal::SupportedStreamConfig)> {
    None
}

/// Listens to what the computer plays, without a microphone, and returns the
/// loudest 40 ms it heard. For the self-test on machines that have no microphone.
pub fn probe_system_audio(listen: Duration) -> Result<f32, String> {
    let (chunks, mut heard) = unbounded_channel();
    let shared = Arc::new(Mutex::new(Shared { chunker: Chunker::new(), chunks: Some(chunks), system: VecDeque::new() }));
    let (commands, _inbox) = channel();
    let stream = build(&cpal::default_host(), Source::System, &shared, &commands)?;
    let mut loudest = 0.0_f32;
    let until = std::time::Instant::now() + listen;
    while std::time::Instant::now() < until {
        std::thread::sleep(Duration::from_millis(50));
        // No microphone drains the mix here: move what arrived through the chunker to measure it.
        let mut shared = shared.lock().unwrap();
        let shared = &mut *shared;
        let samples: Vec<f32> = shared.system.drain(..).collect();
        let chunks = shared.chunks.as_ref().unwrap();
        shared.chunker.feed(&samples, |chunk| drop(chunks.send(chunk)));
        while let Ok(chunk) = heard.try_recv() {
            loudest = loudest.max(chunk.rms);
        }
    }
    drop(stream);
    Ok(loudest)
}

/// Whether a meeting can record what the computer plays, for the UI to say so.
pub fn system_audio_available() -> bool {
    system_device(&cpal::default_host()).is_some()
}

pub struct Devices {
    pub host: String,
    pub input: Option<String>,
    pub output: Option<String>,
    pub system_audio: bool,
}

pub fn devices() -> Devices {
    let host = cpal::default_host();
    let name = |device: Option<cpal::Device>| device.and_then(|d| d.description().ok()).map(|d| d.name().to_string());
    Devices {
        host: host.id().to_string(),
        input: name(host.default_input_device()),
        output: name(host.default_output_device()),
        system_audio: system_device(&host).is_some(),
    }
}
