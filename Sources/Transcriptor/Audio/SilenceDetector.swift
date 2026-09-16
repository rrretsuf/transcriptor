import Foundation

// Port of the silence logic in pill.js onAudioChunk: `now` is a monotonic
// timestamp in milliseconds (systemUptime * 1000), matching performance.now().
struct SilenceDetector {
    static let speechRMS = 0.02
    static let silenceRMS = 0.012

    let thresholdMs: Double
    private var heardSpeech = false
    private var silenceStart = 0.0

    init(thresholdMs: Double) { self.thresholdMs = thresholdMs }

    /// Returns true once when continuous silence outlasts thresholdMs after
    /// speech was heard. Levels between silence and speech reset the timer —
    /// silence must be continuous, not accumulated across quieter speech.
    mutating func feed(rms: Double, now: Double) -> Bool {
        guard thresholdMs > 0 else { return false }
        if rms > Self.speechRMS { heardSpeech = true; silenceStart = 0; return false }
        if rms > Self.silenceRMS { silenceStart = 0; return false }
        guard heardSpeech else { return false }
        if silenceStart == 0 {
            silenceStart = now
            return false
        }
        guard now - silenceStart > thresholdMs else { return false }
        silenceStart = 0
        return true
    }

    mutating func reset() {
        heardSpeech = false
        silenceStart = 0
    }
}
