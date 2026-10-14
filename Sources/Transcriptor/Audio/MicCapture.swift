// AVFAudio is not yet concurrency-annotated; the tap and the converter input
// block run on the realtime audio thread by design.
@preconcurrency import AVFoundation
import Foundation
import ObjCTry

// Raw microphone capture. Voice processing (echo cancellation) is deliberately
// off: its duplex unit ducks other apps' audio and wedges the shared device on
// macOS 26, and dictation has nothing to echo-cancel. Soniox handles noise.
//
// start/stop and device restarts run on the main thread; the tap state is either
// lock-guarded or touched only on the audio thread.
final class MicCapture: @unchecked Sendable {
    typealias Chunk = (pcm: Data, rms: Float)

    struct Unavailable: LocalizedError {
        let errorDescription: String?
    }

    /// Mixed into the voice: the other side of a call.
    private let systemAudio: SystemAudio?
    private var engine: AVAudioEngine?
    private var observer: NSObjectProtocol?
    private let lock = NSLock()
    // Guarded by lock: the tap callback runs on a realtime audio thread while
    // start/stop run on the main actor.
    private var chunker = PCMChunker()
    private var continuation: AsyncStream<Chunk>.Continuation?
    // Only touched on the audio thread: rebuilt whenever the tap's format or size
    // changes, so the realtime callback allocates nothing in steady state.
    private var converter: AVAudioConverter?
    private var mono: AVAudioPCMBuffer?
    private var output: AVAudioPCMBuffer?
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: 16000, channels: 1, interleaved: false)!

    init(systemAudio: SystemAudio? = nil) { self.systemAudio = systemAudio }

    /// Starts the engine and returns the chunk stream.
    func start() throws -> AsyncStream<Chunk> {
        let (stream, continuation) = AsyncStream.makeStream(of: Chunk.self)
        lock.withLock {
            chunker = PCMChunker()
            self.continuation = continuation
        }
        do { try startEngine() } catch {
            stop()
            throw error
        }
        systemAudio?.start()
        return stream
    }

    /// Emits the partial chunk as the stream's final element, then finishes it.
    func stop() {
        stopEngine()
        systemAudio?.stop()
        lock.withLock {
            if let tail = chunker.flush() { continuation?.yield(tail) }
            continuation?.finish()
            continuation = nil
        }
    }

    // A fresh engine every time: one that outlived a device switch (headphones in
    // or out) still carries the old format, and AVAudioEngine answers that mismatch
    // with an Objective-C exception. Swift cannot catch those, and one that escapes
    // a main-actor task leaves the runtime corrupt until the app crashes later.
    private func startEngine() throws {
        let engine = AVAudioEngine()
        var failure: String?
        let exception = ObjCTry {
            let input = engine.inputNode
            let format = input.inputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                failure = "No microphone is available"
                return
            }
            // No explicit format: the tap delivers whatever the node produces once
            // running, and handle() converts from that.
            input.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buffer, _ in
                self?.handle(buffer)
            }
            do { try engine.start() } catch { failure = error.localizedDescription }
        }
        if let reason = failure ?? exception { throw Unavailable(errorDescription: reason) }
        self.engine = engine
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                                          object: engine, queue: .main) { [weak self] _ in
            self?.deviceChanged()
        }
    }

    private func stopEngine() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        guard let engine else { return }
        self.engine = nil
        _ = ObjCTry {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
    }

    /// Headphones in or out mid-recording: the engine has stopped itself. Rebuild it
    /// on the new device once the route settles, and keep the same stream going.
    private func deviceChanged() {
        guard engine != nil else { return }
        stopEngine()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.engine == nil, self.lock.withLock({ self.continuation != nil }) else { return }
            do { try self.startEngine() } catch { self.stop() }
        }
    }

    private func handle(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0, let channels = buffer.floatChannelData else { return }
        // The input can hand out a many-channel bus; the voice is channel 0.
        // AVAudioConverter cannot downmix that layout (it yields silence), so
        // take the channel by hand and let the converter do only the resample.
        let frames = buffer.frameLength
        let rate = buffer.format.sampleRate
        if mono?.format.sampleRate != rate || mono!.frameCapacity < frames {
            guard let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                                 channels: 1, interleaved: false),
                  let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: frames),
                  let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity:
                      AVAudioFrameCount(Double(frames) * targetFormat.sampleRate / rate) + 64) else { return }
            self.mono = mono
            self.output = output
            converter = AVAudioConverter(from: monoFormat, to: targetFormat)
        }
        guard let mono, let output, let converter else { return }
        mono.frameLength = frames
        mono.floatChannelData![0].update(from: channels[0], count: Int(frames))
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
        let channel = UnsafeMutableBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength))
        systemAudio?.mix(into: channel)
        lock.withLock {
            for chunk in chunker.feed(UnsafeBufferPointer(channel)) { continuation?.yield(chunk) }
        }
    }
}
