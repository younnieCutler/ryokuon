import AVFoundation
import Foundation
import Testing

@testable import Ryokuon

struct FLACConverterTests {
    @Test func cancelledConversionPreservesSourceAndExistingDestination() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let wav = directory.appendingPathComponent("call.wav")
        let writer = try WAVWriter(url: wav)
        try writer.append([Int16](repeating: 1000, count: 16000))
        try writer.finish()
        let original = try Data(contentsOf: wav)
        let flac = directory.appendingPathComponent("call.flac")
        try Data("previous".utf8).write(to: flac)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try FLACConverter.convert(sessionDirectory: directory)
        }
        do {
            _ = try await task.value
            Issue.record("Cancelled conversion unexpectedly succeeded")
        } catch is CancellationError { }
        #expect(try Data(contentsOf: wav) == original)
        #expect(try Data(contentsOf: flac) == Data("previous".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == 2)
    }

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
