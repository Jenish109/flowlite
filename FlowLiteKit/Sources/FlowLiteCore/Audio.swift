import Foundation

public enum AudioMath {
    public static let sampleRate: Double = 16_000

    public static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in samples { sum += sample * sample }
        return (sum / Float(samples.count)).squareRoot()
    }

    /// Maps RMS to 0...1 for a level meter: -50 dBFS → 0, -10 dBFS → 1.
    public static func meterLevel(rms: Float) -> Float {
        guard rms > 0 else { return 0 }
        let decibels = 20 * log10(rms)
        return min(1, max(0, (decibels + 50) / 40))
    }
}

/// Mono Float32 audio at `AudioMath.sampleRate`.
public struct RecordedAudio: Sendable, Equatable {
    public var samples: [Float]

    public init(samples: [Float]) {
        self.samples = samples
    }

    public var durationMs: Int { Int(Double(samples.count) / AudioMath.sampleRate * 1000) }
    public var rms: Float { AudioMath.rms(samples) }
}

public enum WAVEncoder {
    /// 16-bit PCM mono WAV at `AudioMath.sampleRate`.
    public static func encode(_ samples: [Float]) -> Data {
        let rate = UInt32(AudioMath.sampleRate)
        let dataBytes = UInt32(samples.count * 2)
        var data = Data()
        func u32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }

        data.append(contentsOf: Array("RIFF".utf8)); u32(36 + dataBytes)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); u32(16)
        u16(1)              // PCM
        u16(1)              // mono
        u32(rate)
        u32(rate * 2)       // byte rate
        u16(2)              // block align
        u16(16)             // bits per sample
        data.append(contentsOf: Array("data".utf8)); u32(dataBytes)
        for sample in samples {
            let clamped = max(-1, min(1, sample))
            u16(UInt16(bitPattern: Int16(clamped * Float(Int16.max))))
        }
        return data
    }
}

/// Keeps the newest `keep` recordings as WAV files, for debugging and the golden set.
public struct RecordingArchive: Sendable {
    public let directory: URL
    public let keep: Int

    public init(directory: URL, keep: Int = 5) {
        self.directory = directory
        self.keep = keep
    }

    /// `name` must sort chronologically (e.g. `yyyyMMdd-HHmmss-SSS`).
    @discardableResult
    public func save(_ samples: [Float], name: String) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name + ".wav")
        try WAVEncoder.encode(samples).write(to: url)
        let wavs = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "wav" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for old in wavs.dropLast(keep) { try? fm.removeItem(at: old) }
        return url
    }
}
