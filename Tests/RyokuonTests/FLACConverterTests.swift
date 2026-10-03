import AVFoundation
import Foundation
import Testing

@testable import Ryokuon

struct FLACConverterTests {
    @Test func conversionPreservesEveryFrameBeforeRemovingWAV() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let wav = directory.appendingPathComponent("call.wav")
        let writer = try WAVWriter(url: wav, channels: 2)
        // Cross the converter's chunk boundary, including a partial last chunk.
        try writer.append([Int16](repeating: 1234, count: 2 * 160123))
        try writer.finish()
        let flac = try FLACConverter.convert(sessionDirectory: directory)
        let audio = try AVAudioFile(forReading: flac)
        #expect(audio.length == 160123)
        #expect(audio.processingFormat.channelCount == 2)
        #expect(!FileManager.default.fileExists(atPath: wav.path))
    }

    @Test func emptySourceDoesNotOverwriteExistingFLAC() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let wav = directory.appendingPathComponent("call.wav")
        try WAVWriter(url: wav).finish()
        let flac = directory.appendingPathComponent("call.flac")
        let original = Data("existing export".utf8)
        try original.write(to: flac)
        #expect(throws: FLACConverterError.self) { try FLACConverter.convert(sessionDirectory: directory) }
        #expect(try Data(contentsOf: flac) == original)
        #expect(FileManager.default.fileExists(atPath: wav.path))
    }
}
