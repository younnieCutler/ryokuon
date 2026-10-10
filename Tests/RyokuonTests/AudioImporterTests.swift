import AVFoundation
import Foundation
import Testing

@testable import Ryokuon

struct AudioImporterTests {
    /// 1s stereo 44.1kHz AAC sine — the shape of a typical iPhone/Mac m4a.
    private func makeM4A(at url: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44100,
                                       AVNumberOfChannelsKey: 2]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44100)!
        buffer.frameLength = 44100
        for channel in 0 ..< 2 {
            for i in 0 ..< 44100 { buffer.floatChannelData![channel][i] = 0.3 * sinf(Float(i) * 2 * .pi * 440 / 44100) }
        }
        try file.write(from: buffer)
    }

    @Test func cancelledImportPreservesInputAndCreatesNoSession() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("memo.m4a")
        try makeM4A(at: source)
        let original = try Data(contentsOf: source)
        let store = SessionStore(rootDirectory: root.appendingPathComponent("sessions"))
        let sessionRoot = store.rootDirectory
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try AudioImporter.importFile(source, store: SessionStore(rootDirectory: sessionRoot), language: "en-US")
        }
        do {
            _ = try await task.value
            Issue.record("Cancelled import unexpectedly succeeded")
        } catch is CancellationError { }
        #expect(try Data(contentsOf: source) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: store.rootDirectory.path).isEmpty)
    }

    @Test func importsM4AAs16kMonoSession() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("memo.m4a")
        try makeM4A(at: source)

        let store = SessionStore(rootDirectory: root.appendingPathComponent("sessions"))
        let session = try AudioImporter.importFile(source, store: store, language: "ko-KR")

        let wav = try AVAudioFile(forReading: store.directory(for: session).appendingPathComponent("call.wav"))
        #expect(wav.fileFormat.sampleRate == 16000)
        #expect(wav.fileFormat.channelCount == 1)
        #expect(abs(session.durationSeconds - 1.0) < 0.1)
        #expect(session.displayName == "memo")
        #expect(session.state == .finished)
        #expect(try store.load(from: store.directory(for: session)).channels == 1)
    }
    @Test func emptyImportLeavesNoSession() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("empty.wav")
        try WAVWriter(url: source).finish()
        let store = SessionStore(rootDirectory: root.appendingPathComponent("sessions"))
        #expect(throws: (any Error).self) { try AudioImporter.importFile(source, store: store, language: "ja-JP") }
        #expect(store.listSessions().isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: store.rootDirectory.path).isEmpty)
    }

}
