@preconcurrency import AVFoundation
import CoreAudio
import Foundation

// Everything the Mac plays — the other side of a call — through a Core Audio
// process tap, resampled to 16 kHz mono and mixed into the microphone.
// Mixing (not a second stream) means on speakers the mic's echo of the call
// reads as room reverb, not as every word twice. Without the System Audio
// Recording permission the tap only delivers silence: the meeting still runs
// on the microphone alone.
final class SystemAudio: @unchecked Sendable {
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

    func start() {
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

    func stop() {
        if let proc {
            AudioDeviceStop(device, proc)
            AudioDeviceDestroyIOProcID(device, proc)
        }
        proc = nil
        if device != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(device) }
        if tap != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tap) }
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
        let samples = UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength))
        lock.withLock {
            pending.append(contentsOf: samples)
            if pending.count > Self.maxPending { pending.removeFirst(pending.count - Self.maxPending) }
        }
    }
}
