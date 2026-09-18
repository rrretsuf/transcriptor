// AVFAudio is not yet concurrency-annotated; the tap and the converter input
// block run on the realtime audio thread by design.
@preconcurrency import AVFoundation
import Foundation

// Raw microphone capture. Voice processing (echo cancellation) is deliberately
// off: its duplex unit ducks other apps' audio and wedges the shared device on
// macOS 26, and dictation has nothing to echo-cancel. Soniox handles noise.
final class MicCapture {
    typealias Chunk = (pcm: Data, rms: Float)

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    // Guarded by lock: the tap callback runs on a realtime audio thread while
    // start/stop run on the main actor.
    private var chunker = PCMChunker()
    private var continuation: AsyncStream<Chunk>.Continuation?
    // Only touched on the audio thread: rebuilt whenever the tap's format changes.
    private var converter: AVAudioConverter?
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: 16000, channels: 1, interleaved: false)!

    /// Starts the engine and returns the chunk stream.
    func start() throws -> AsyncStream<Chunk> {
        let (stream, continuation) = AsyncStream.makeStream(of: Chunk.self)
        lock.withLock {
            chunker = PCMChunker()
            self.continuation = continuation
        }
        // No explicit format: the tap delivers whatever the node produces once
        // running, and handle() converts from that.
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buffer, _ in
            self?.handle(buffer)
        }
        try engine.start()
        return stream
    }

    /// Emits the partial chunk as the stream's final element, then finishes it.
    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        lock.withLock {
            if let tail = chunker.flush() { continuation?.yield(tail) }
            continuation?.finish()
            continuation = nil
        }
    }

    private func handle(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0, let channels = buffer.floatChannelData else { return }
        // The input can hand out a many-channel bus; the voice is channel 0.
        // AVAudioConverter cannot downmix that layout (it yields silence), so
        // take the channel by hand and let the converter do only the resample.
        guard let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: buffer.format.sampleRate,
                                             channels: 1, interleaved: false),
              let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: buffer.frameLength) else { return }
        mono.frameLength = buffer.frameLength
        mono.floatChannelData![0].update(from: channels[0], count: Int(buffer.frameLength))
        if converter?.inputFormat != monoFormat {
            converter = AVAudioConverter(from: monoFormat, to: targetFormat)
        }
        guard let converter else { return }
        let target = targetFormat
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * target.sampleRate / buffer.format.sampleRate) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        // convert() invokes the block synchronously on this thread; the
        // nonisolated(unsafe) captures are safe by that contract.
        nonisolated(unsafe) let input = mono
        nonisolated(unsafe) var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return input
        }
        guard error == nil, output.frameLength > 0 else { return }
        let channel = UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength))
        lock.withLock {
            for chunk in chunker.feed(channel) { continuation?.yield(chunk) }
        }
    }
}
