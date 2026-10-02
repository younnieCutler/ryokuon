import AVFoundation
import Foundation
import Testing

@testable import Ryokuon

struct MP3ExporterTests {
    @Test(.enabled(if: MP3Exporter.lameURL != nil, "lame not installed"))
    func exportsOnlyTheSelectedRange() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let wav = dir.appendingPathComponent("call.wav")
        let writer = try WAVWriter(url: wav, channels: 2)
        try writer.append((0 ..< 32000 * 2).map { Int16(truncatingIfNeeded: ($0 * 37) % 8000) }) // 2s stereo
        try writer.finish()

        let mp3 = dir.appendingPathComponent("out.mp3")
        try MP3Exporter.export(from: wav, range: 0.5 ... 1.5, gains: .init(me: 2, remote: 0.5),
                               bitrate: 64, mono: true, to: mp3)

        let decoded = try AVAudioFile(forReading: mp3)
        #expect(decoded.fileFormat.channelCount == 1)
        #expect(abs(Double(decoded.length) / decoded.fileFormat.sampleRate - 1.0) < 0.1)
    }
}
