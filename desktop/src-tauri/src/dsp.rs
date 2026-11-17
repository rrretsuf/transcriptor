use std::collections::VecDeque;
use std::f32::consts::PI;

pub const SAMPLE_RATE: u32 = 16000;

pub struct Chunk {
    pub pcm: Vec<u8>,
    pub rms: f32,
}

/// 640 samples = 40 ms of s16le mono at 16 kHz.
pub struct Chunker {
    buffer: Vec<i16>,
    energy: f64,
}

impl Chunker {
    pub const SIZE: usize = 640;

    pub fn new() -> Self {
        Self { buffer: Vec::with_capacity(Self::SIZE), energy: 0.0 }
    }

    pub fn feed(&mut self, samples: &[f32], mut emit: impl FnMut(Chunk)) {
        for &sample in samples {
            let s = sample.clamp(-1.0, 1.0);
            self.energy += f64::from(s * s);
            self.buffer.push(if s < 0.0 { s * 32768.0 } else { s * 32767.0 } as i16);
            if self.buffer.len() == Self::SIZE {
                emit(self.emit());
            }
        }
    }

    pub fn flush(&mut self) -> Option<Chunk> {
        (!self.buffer.is_empty()).then(|| self.emit())
    }

    fn emit(&mut self) -> Chunk {
        let rms = (self.energy / self.buffer.len() as f64).sqrt() as f32;
        let pcm = self.buffer.iter().flat_map(|s| s.to_le_bytes()).collect();
        self.buffer.clear();
        self.energy = 0.0;
        Chunk { pcm, rms }
    }
}

/// `now` is a monotonic timestamp in milliseconds.
pub struct SilenceDetector {
    threshold_ms: f64,
    heard_speech: bool,
    silence_start: f64,
}

impl SilenceDetector {
    const SPEECH_RMS: f64 = 0.02;
    const SILENCE_RMS: f64 = 0.012;

    pub fn new(threshold_ms: f64) -> Self {
        Self { threshold_ms, heard_speech: false, silence_start: 0.0 }
    }

    /// True once when continuous silence outlasts the threshold after speech was
    /// heard. Levels between silence and speech reset the timer.
    pub fn feed(&mut self, rms: f64, now: f64) -> bool {
        if self.threshold_ms <= 0.0 {
            return false;
        }
        if rms > Self::SPEECH_RMS {
            self.heard_speech = true;
            self.silence_start = 0.0;
            return false;
        }
        if rms > Self::SILENCE_RMS {
            self.silence_start = 0.0;
            return false;
        }
        if !self.heard_speech {
            return false;
        }
        if self.silence_start == 0.0 {
            self.silence_start = now;
            return false;
        }
        if now - self.silence_start <= self.threshold_ms {
            return false;
        }
        self.silence_start = 0.0;
        true
    }

    #[cfg(test)]
    fn reset(&mut self) {
        self.heard_speech = false;
        self.silence_start = 0.0;
    }
}

/// Streaming windowed-sinc resampler to 16 kHz. Devices hand out 44.1, 48 or
/// 96 kHz; the low-pass keeps what is above 8 kHz from folding into the speech.
pub struct Resampler {
    step: f64,
    cutoff: f32,
    half: usize,
    history: VecDeque<f32>,
    position: f64,
}

impl Resampler {
    const ZERO_CROSSINGS: f32 = 8.0;

    pub fn new(input_rate: u32) -> Self {
        let step = f64::from(input_rate) / f64::from(SAMPLE_RATE);
        let cutoff = (1.0 / step).min(1.0) as f32;
        let half = (Self::ZERO_CROSSINGS / cutoff).ceil() as usize;
        Self { step, cutoff, half, history: std::iter::repeat_n(0.0, half).collect(), position: 0.0 }
    }

    pub fn process(&mut self, input: &[f32], output: &mut Vec<f32>) {
        self.history.extend(input);
        let half = self.half as f64;
        // history[0] is input sample -half; `position` is the next output's place in input samples.
        while self.position + half + 1.0 < (self.history.len() - self.half) as f64 {
            let center = self.position + half;
            let first = (center - half).ceil() as usize;
            let last = (center + half).floor() as usize;
            let mut sum = 0.0;
            for i in first..=last {
                sum += self.history[i] * self.kernel(i as f32 - center as f32);
            }
            output.push(sum);
            self.position += self.step;
        }
        let drop = (self.position.floor() as usize).min(self.history.len().saturating_sub(2 * self.half));
        self.history.drain(..drop);
        self.position -= drop as f64;
    }

    fn kernel(&self, x: f32) -> f32 {
        let half = self.half as f32;
        if x.abs() >= half {
            return 0.0;
        }
        let window = 0.5 + 0.5 * (PI * x / half).cos();
        let t = PI * x * self.cutoff;
        let sinc = if t.abs() < 1e-6 { 1.0 } else { t.sin() / t };
        self.cutoff * sinc * window
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn feed(chunker: &mut Chunker, samples: &[f32]) -> Vec<Chunk> {
        let mut out = Vec::new();
        chunker.feed(samples, |c| out.push(c));
        out
    }

    #[test]
    fn emits_fixed_chunks_and_flushes_the_remainder() {
        let mut chunker = Chunker::new();
        let chunks = feed(&mut chunker, &[0.5; 1000]);
        assert_eq!(chunks.len(), 1);
        assert_eq!(chunks[0].pcm.len(), 640 * 2);
        assert_eq!(chunker.flush().unwrap().pcm.len(), 360 * 2);
        assert!(chunker.flush().is_none());
    }

    #[test]
    fn rms_and_encoding() {
        let mut chunker = Chunker::new();
        let chunks = feed(&mut chunker, &[0.5; 640]);
        assert!((chunks[0].rms - 0.5).abs() < 0.0001);
        assert_eq!(i16::from_le_bytes([chunks[0].pcm[0], chunks[0].pcm[1]]), 16383);
    }

    #[test]
    fn clamps_out_of_range_samples() {
        let mut chunker = Chunker::new();
        let mut samples = vec![-2.0, 2.0];
        samples.resize(640, 0.0);
        let pcm = &feed(&mut chunker, &samples)[0].pcm;
        assert_eq!(i16::from_le_bytes([pcm[0], pcm[1]]), -32768);
        assert_eq!(i16::from_le_bytes([pcm[2], pcm[3]]), 32767);
    }

    #[test]
    fn silence_must_be_continuous_not_accumulated() {
        let mut detector = SilenceDetector::new(1500.0);
        let mut now = 1000.0;
        assert!(!detector.feed(0.1, now));
        assert!(!detector.feed(0.0, now));
        now += 1000.0;
        assert!(!detector.feed(0.015, now));
        now += 700.0;
        assert!(!detector.feed(0.0, now));
        now += 1600.0;
        assert!(detector.feed(0.0, now));
    }

    #[test]
    fn no_trigger_before_speech() {
        let mut detector = SilenceDetector::new(500.0);
        for i in 0..20 {
            assert!(!detector.feed(0.0, f64::from(i) * 1000.0));
        }
    }

    #[test]
    fn triggers_only_once_and_reset_restarts() {
        let mut detector = SilenceDetector::new(100.0);
        assert!(!detector.feed(0.1, 0.0));
        assert!(!detector.feed(0.0, 1.0));
        assert!(detector.feed(0.0, 200.0));
        assert!(!detector.feed(0.0, 1000.0));
        detector.reset();
        assert!(!detector.feed(0.0, 5000.0));
        assert!(!detector.feed(0.1, 5001.0));
        assert!(!detector.feed(0.0, 5002.0));
        assert!(detector.feed(0.0, 5200.0));
    }

    #[test]
    fn disabled_threshold_never_triggers() {
        let mut detector = SilenceDetector::new(0.0);
        assert!(!detector.feed(0.1, 0.0));
        assert!(!detector.feed(0.0, 99999.0));
    }

    fn resample(rate: u32, input: &[f32], block: usize) -> Vec<f32> {
        let mut resampler = Resampler::new(rate);
        let mut out = Vec::new();
        for part in input.chunks(block) {
            resampler.process(part, &mut out);
        }
        out
    }

    fn sine(rate: u32, hz: f32, seconds: f32) -> Vec<f32> {
        (0..(rate as f32 * seconds) as usize).map(|i| (2.0 * PI * hz * i as f32 / rate as f32).sin()).collect()
    }

    fn rms(samples: &[f32]) -> f32 {
        (samples.iter().map(|s| s * s).sum::<f32>() / samples.len() as f32).sqrt()
    }

    #[test]
    fn resampler_keeps_length_and_speech_band() {
        for rate in [16000, 44100, 48000, 96000] {
            let out = resample(rate, &sine(rate, 1000.0, 1.0), 441);
            assert!((out.len() as i64 - 16000).abs() < 64, "{rate}: {}", out.len());
            let level = rms(&out[2000..14000]);
            assert!((level - 0.707).abs() < 0.03, "{rate}: {level}");
        }
    }

    #[test]
    fn resampler_removes_what_would_alias() {
        let out = resample(48000, &sine(48000, 12000.0, 1.0), 480);
        assert!(rms(&out[2000..14000]) < 0.02);
    }

    #[test]
    fn resampler_output_does_not_depend_on_block_size() {
        let input = sine(48000, 440.0, 0.5);
        let a = resample(48000, &input, 480);
        let b = resample(48000, &input, 4096);
        let n = a.len().min(b.len());
        assert!(a.len().abs_diff(b.len()) < 64);
        assert!(a[..n].iter().zip(&b[..n]).all(|(x, y)| (x - y).abs() < 1e-4));
    }

    #[test]
    fn resampler_passes_dc_at_unity() {
        let out = resample(44100, &[0.25; 44100], 512);
        assert!(out[1000..15000].iter().all(|s| (s - 0.25).abs() < 0.005));
    }
}
