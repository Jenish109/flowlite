import Foundation
import Testing
@testable import FlowLiteCore

@Suite struct AudioTests {
    @Test func rmsOfSquareWave() {
        #expect(abs(AudioMath.rms([0.5, -0.5, 0.5, -0.5]) - 0.5) < 0.0001)
    }

    @Test func rmsOfEmptyIsZero() {
        #expect(AudioMath.rms([]) == 0)
    }

    @Test func meterLevelMapsDecibelsToUnitRange() {
        #expect(AudioMath.meterLevel(rms: 0) == 0)
        #expect(AudioMath.meterLevel(rms: 0.001) == 0)          // -60 dBFS clamps to 0
        #expect(AudioMath.meterLevel(rms: 1) == 1)              // 0 dBFS clamps to 1
        #expect(abs(AudioMath.meterLevel(rms: 0.01) - 0.25) < 0.01) // -40 dBFS
    }

    @Test func durationIsDerivedFromSampleCount() {
        #expect(RecordedAudio(samples: Array(repeating: 0, count: 8_000)).durationMs == 500)
    }

    @Test func wavEncodingHasHeaderAndLittleEndianSamples() {
        let data = WAVEncoder.encode([0, 1, -1])
        #expect(data.count == 44 + 6)
        #expect(String(decoding: data[0..<4], as: UTF8.self) == "RIFF")
        #expect(String(decoding: data[8..<12], as: UTF8.self) == "WAVE")
        #expect(String(decoding: data[36..<40], as: UTF8.self) == "data")
        #expect(data[44] == 0x00 && data[45] == 0x00)   // 0
        #expect(data[46] == 0xFF && data[47] == 0x7F)   // +32767
        #expect(data[48] == 0x01 && data[49] == 0x80)   // -32767
    }

    @Test func archiveKeepsNewestFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let archive = RecordingArchive(directory: dir, keep: 5)
        for i in 1...7 { try archive.save([0.1, 0.2], name: "clip-\(i)") }
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        #expect(names == ["clip-3.wav", "clip-4.wav", "clip-5.wav", "clip-6.wav", "clip-7.wav"])
    }
}
