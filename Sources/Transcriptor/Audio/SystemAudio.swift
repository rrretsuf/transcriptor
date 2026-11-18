@preconcurrency import AVFoundation
import CoreAudio
import Foundation
import ScreenCaptureKit

// Everything the Mac plays — the other side of a call — through a Core Audio
// process tap, resampled to 16 kHz mono and mixed into the microphone.
// Mixing (not a second stream) means on speakers the mic's echo of the call
// reads as room reverb, not as every word twice. Without the System Audio
// Recording permission the tap only delivers silence: the meeting still runs
// on the microphone alone. Before macOS 14.2 there is no process tap, so
// ScreenCaptureKit captures the same audio, behind Screen Recording.
final class SystemAudio: NSObject, SCStreamOutput, @unchecked Sendable {
    private var tap = AudioObjectID(kAudioObjectUnknown)
    private var device = AudioObjectID(kAudioObjectUnknown)
    private var proc: AudioDeviceIOProcID?
    // Only touched on the tap's IO thread.
    private var converter: AVAudioConverter?
    private var output: AVAudioPCMBuffer?
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: 16000, channels: 1, interleaved: false)!
    private let lock = NSLock()
    private var pending: [Float] = [] // guarded by lock
    private static let maxPending = 8000 // 0.5 s: older audio is stale by the time the mic catches up
    // Guarded by lock, macOS 13 to 14.1 only. Starting is async, so a stop that
    // comes first clears `capturing` and the late stream stops itself.
    private var screen: SCStream?
    private var capturing = false

    func start() {
        guard #available(macOS 14.2, *) else { return startScreenCapture() }
        guard device == kAudioObjectUnknown else { return }
        let description = CATapDescription(monoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.muteBehavior = .unmuted
        description.isPrivate = true
        guard AudioHardwareCreateProcessTap(description, &tap) == noErr else { return stop() }
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Transcriptor Meeting",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString,
                                               kAudioSubTapDriftCompensationKey: true]],
        ]
        guard AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device) == noErr,
              var stream = tapFormat(),
              let format = AVAudioFormat(streamDescription: &stream) else { return stop() }
        converter = AVAudioConverter(from: format, to: targetFormat)
        let status = AudioDeviceCreateIOProcIDWithBlock(&proc, device, nil) { [weak self] _, input, _, _, _ in
            self?.receive(input, format: format)
        }
        guard status == noErr, AudioDeviceStart(device, proc) == noErr else { return stop() }
    }

    private func startScreenCapture() {
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = Int(targetFormat.sampleRate)
        config.channelCount = 1
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        lock.withLock { capturing = true }
        Task {
            guard let display = try? await SCShareableContent.current.displays.first else { return }
            let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []),
                                  configuration: config, delegate: nil)
            guard (try? stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: .global())) != nil,
                  (try? await stream.startCapture()) != nil else { return }
            let keep = lock.withLock {
                if capturing { screen = stream }
                return capturing
            }
            if !keep { try? await stream.stopCapture() }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        try? buffer.withAudioBufferList { list, _ in
            guard let audio = list.first, let data = audio.mData else { return }
            append(UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self),
                                       count: Int(audio.mDataByteSize) / MemoryLayout<Float>.size))
        }
    }

    func stop() {
        let screen = lock.withLock {
            defer { screen = nil; capturing = false }
            return screen
        }
        if let screen {
            Task { try? await screen.stopCapture() }
        }
        if let proc {
            AudioDeviceStop(device, proc)
            AudioDeviceDestroyIOProcID(device, proc)
        }
        proc = nil
        if device != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(device) }
        if #available(macOS 14.2, *), tap != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tap) }
        device = AudioObjectID(kAudioObjectUnknown)
        tap = AudioObjectID(kAudioObjectUnknown)
        lock.withLock { pending.removeAll() }
    }

    /// Adds whatever system audio has arrived onto the microphone samples.
    func mix(into samples: UnsafeMutableBufferPointer<Float>) {
        lock.withLock {
            let count = min(samples.count, pending.count)
            for i in 0..<count { samples[i] += pending[i] }
            pending.removeFirst(count)
        }
    }

    private func tapFormat() -> AudioStreamBasicDescription? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        return AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &format) == noErr ? format : nil
    }

    private func receive(_ list: UnsafePointer<AudioBufferList>, format: AVAudioFormat) {
        guard let converter,
              let input = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: list, deallocator: nil),
              input.frameLength > 0 else { return }
        let capacity = AVAudioFrameCount(Double(input.frameLength) * targetFormat.sampleRate / format.sampleRate) + 64
        if output == nil || output!.frameCapacity < capacity {
            output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity)
        }
        guard let output else { return }
        nonisolated(unsafe) let source = input
        nonisolated(unsafe) var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return source
        }
        guard error == nil, output.frameLength > 0 else { return }
        append(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
    }

    private func append(_ samples: UnsafeBufferPointer<Float>) {
        lock.withLock {
            pending.append(contentsOf: samples)
            if pending.count > Self.maxPending { pending.removeFirst(pending.count - Self.maxPending) }
        }
    }
}
