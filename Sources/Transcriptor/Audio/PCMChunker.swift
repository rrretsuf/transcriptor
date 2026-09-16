import Foundation

// 640 samples = 40 ms at 16 kHz, matching pcm-processor.js.
struct PCMChunker {
    static let size = 640

    private var buffer = [Int16](repeating: 0, count: size)
    private var count = 0
    private var energy = 0.0

    mutating func feed(_ samples: UnsafeBufferPointer<Float>) -> [(pcm: Data, rms: Float)] {
        var out: [(pcm: Data, rms: Float)] = []
        for sample in samples {
            let s = max(-1, min(1, sample))
            energy += Double(s * s)
            buffer[count] = Int16((s < 0 ? s * 0x8000 : s * 0x7fff).rounded(.towardZero))
            count += 1
            if count == Self.size {
                out.append(emit())
            }
        }
        return out
    }

    mutating func flush() -> (pcm: Data, rms: Float)? {
        guard count > 0 else { return nil }
        return emit()
    }

    private mutating func emit() -> (pcm: Data, rms: Float) {
        let pcm = buffer.withUnsafeBytes { Data($0.prefix(count * 2)) }
        let rms = Float((energy / Double(count)).squareRoot())
        count = 0
        energy = 0
        return (pcm, rms)
    }
}
