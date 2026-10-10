import AVFoundation
import Foundation
import Testing
@testable import Ryokuon

struct AudioChannelExtractorTests {
    @Test func extractsTheRequestedChannelWithoutChangingDuration() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.wav")
        let output = root.appendingPathComponent("channel.flac")
        let writer = try WAVWriter(url: source, channels: 2)
        // More than one extraction chunk: verifies continuity at the boundary.
        try writer.append((0..<192000).flatMap { _ in [Int16(0), Int16(8192)] })
        try writer.finish()
        try AudioChannelExtractor.write(from: source, channel: 1, gain: 2, to: output)
        let file = try AVAudioFile(forReading: output)
        #expect(file.length == 192000)
        #expect(file.processingFormat.channelCount == 1)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16))
        try file.read(into: buffer, frameCount: 16)
        #expect(abs(try #require(buffer.floatChannelData?[0][0]) - 0.5) < 0.002)
    }
}
