import AVFoundation
import Foundation
import Testing
@testable import Ryokuon

struct TranscriptionAudioReaderTests {
    @Test func chunkedStereoChannelAndGainPreserveEveryFrame() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try WAVWriter(url: url, channels: 2)
        let frames = 16000 * 5 + 137
        try writer.append((0..<frames).flatMap { _ in [Int16(8000), Int16(-12000)] })
        try writer.finish()
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false))
        let reader = try TranscriptionAudioReader(url: url, channel: 1, gain: 0.5, targetFormat: format)
        var total = 0
        while let chunk = try reader.next() {
            #expect(chunk.frameLength <= 32000)
            let samples = try #require(chunk.floatChannelData?[0])
            #expect(abs(samples[0] - Float(-12000.0 / 32768.0 * 0.5)) < 0.001)
            total += Int(chunk.frameLength)
        }
        #expect(total == frames)
        #expect(try reader.next() == nil)
    }

    @Test func resamplingAcrossChunksPreservesDuration() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let frames = 16000 * 5 + 137
        let writer = try WAVWriter(url: url)
        try writer.append([Int16](repeating: 4000, count: frames))
        try writer.finish()
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 32000, channels: 1, interleaved: false))
        let reader = try TranscriptionAudioReader(url: url, channel: 0, gain: 1, targetFormat: format)
        var total = 0
        while let chunk = try reader.next() { total += Int(chunk.frameLength) }
        #expect(abs(total - frames * 2) <= 64)
    }
}
