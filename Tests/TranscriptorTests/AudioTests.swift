import Foundation
import Testing
@testable import Transcriptor

struct FeedTests {
    @Test func splitsSentencesAtTerminalPunctuation() {
        #expect(NotchSurface.sentences("Hello there. How are you? Fine") == ["Hello there.", "How are you?", "Fine"])
        #expect(NotchSurface.sentences("Version 2.5 works") == ["Version 2.5 works"])
        #expect(NotchSurface.sentences("") == [])
    }
}

struct PCMChunkerTests {
    private func feed(_ chunker: inout PCMChunker, _ samples: [Float]) -> [(pcm: Data, rms: Float)] {
        samples.withUnsafeBufferPointer { chunker.feed($0) }
    }

    @Test func emitsFixedChunksAndFlushesRemainder() throws {
        var chunker = PCMChunker()
        let chunks = feed(&chunker, Array(repeating: 0.5, count: 1000))
        #expect(chunks.count == 1)
        #expect(chunks[0].pcm.count == 640 * 2)
        let tail = chunker.flush()
        #expect(tail?.pcm.count == 360 * 2)
        let empty = chunker.flush()
        #expect(empty == nil)
    }

    @Test func rmsAndEncoding() throws {
        var chunker = PCMChunker()
        let chunks = feed(&chunker, Array(repeating: 0.5, count: 640))
        let chunk = try #require(chunks.first)
        #expect(abs(chunk.rms - 0.5) < 0.0001)
        // 0.5 * 0x7fff truncated toward zero = 16383
        #expect(chunk.pcm.withUnsafeBytes { $0.load(as: Int16.self) } == 16383)
    }

    @Test func clampsOutOfRangeSamples() throws {
        var chunker = PCMChunker()
        let chunks = feed(&chunker, [-2.0, 2.0] + Array(repeating: Float(0), count: 638))
        let pcm = try #require(chunks.first).pcm
        let samples = pcm.withUnsafeBytes { [$0.load(as: Int16.self), $0.load(fromByteOffset: 2, as: Int16.self)] }
        #expect(samples == [-32768, 32767])
    }
}

struct SilenceDetectorTests {
    @Test func silenceMustBeContinuousNotAccumulated() {
        // Port of tests/session.cjs: quiet speech resets the silence timer.
        var detector = SilenceDetector(thresholdMs: 1500)
        var now = 1000.0
        #expect(detector.feed(rms: 0.1, now: now) == false)  // speech
        #expect(detector.feed(rms: 0, now: now) == false)    // silence begins
        now += 1000
        #expect(detector.feed(rms: 0.015, now: now) == false) // quiet speech resets
        now += 700
        #expect(detector.feed(rms: 0, now: now) == false)    // silence restarts
        now += 1600
        #expect(detector.feed(rms: 0, now: now) == true)     // 1600 > 1500
    }

    @Test func noTriggerBeforeSpeech() {
        var detector = SilenceDetector(thresholdMs: 500)
        for i in 0..<20 { #expect(detector.feed(rms: 0, now: Double(i * 1000)) == false) }
    }

    @Test func triggersOnlyOnceAndResetRestarts() {
        var detector = SilenceDetector(thresholdMs: 100)
        #expect(detector.feed(rms: 0.1, now: 0) == false)
        #expect(detector.feed(rms: 0, now: 1) == false)
        #expect(detector.feed(rms: 0, now: 200) == true)
        #expect(detector.feed(rms: 0, now: 1000) == false)
        detector.reset()
        #expect(detector.feed(rms: 0, now: 5000) == false) // no speech heard
        #expect(detector.feed(rms: 0.1, now: 5001) == false)
        #expect(detector.feed(rms: 0, now: 5002) == false)
        #expect(detector.feed(rms: 0, now: 5200) == true)
    }

    @Test func disabledThresholdNeverTriggers() {
        var detector = SilenceDetector(thresholdMs: 0)
        #expect(detector.feed(rms: 0.1, now: 0) == false)
        #expect(detector.feed(rms: 0, now: 99999) == false)
    }
}
