import Foundation
import Testing
@testable import Ryokuon

@MainActor
struct TranscriptionCancellationTests {
    @Test func cancellingActiveWorkPreservesTranscriptAndContinuesQueue() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(rootDirectory: root)
        var (first, directory) = try store.createSession(language: "en-US", targetBundleID: nil, targetDisplayName: "first")
        first.state = .finished
        try store.save(first, in: directory)
        var (second, secondDirectory) = try store.createSession(language: "en-US", targetBundleID: nil, targetDisplayName: "second")
        second.state = .finished
        try store.save(second, in: secondDirectory)
        let original = Data("previous successful transcript".utf8)
        try original.write(to: directory.appendingPathComponent("transcript.txt"))
        let firstDirectory = directory
        let probe = CancellationProbe()
        let app = AppState(sessionStore: store, transcribeOperation: { url, _, _, _, _ in
            await probe.started(url)
            if url == firstDirectory { try await Task.sleep(for: .seconds(60)) }
            return []
        })
        app.transcribeSession(first)
        app.transcribeSession(second)
        for _ in 0..<200 {
            if await probe.count > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await probe.count == 1)
        app.cancelTranscription(first)
        #expect(app.isCancellingTranscription)
        #expect(!app.canDelete(first))
        for _ in 0..<200 {
            if app.transcribingSessionID == nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(app.transcribingSessionID == nil)
        #expect(!app.hasActiveWork)
        #expect(app.lastError == nil)
        #expect(await probe.count == 2)
        #expect(try Data(contentsOf: directory.appendingPathComponent("transcript.txt")) == original)
        #expect(FileManager.default.fileExists(atPath: secondDirectory.appendingPathComponent("transcript.txt").path))
    }

    @Test func cancellingImportBatchBeforeStartClearsQueueAndAllowsAnotherBatch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = AppState(sessionStore: SessionStore(rootDirectory: root))
        let missing = root.appendingPathComponent("missing.wav")
        app.importAudio([missing, missing])
        #expect(app.pendingImportCount == 2)
        app.cancelImports()
        #expect(app.pendingImportCount == 0)
        #expect(app.hasActiveWork)
        for _ in 0..<200 {
            if app.importingFileName == nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!app.hasActiveWork)
        #expect(app.lastError == nil)
        app.importAudio([missing])
        #expect(app.importingFileName != nil)
        app.cancelImports()
        for _ in 0..<200 {
            if app.importingFileName == nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!app.hasActiveWork)
    }

    @Test func cancellingBeforeTaskStartsDoesNotInvokeRecognition() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(rootDirectory: root)
        var (session, directory) = try store.createSession(language: "en-US", targetBundleID: nil, targetDisplayName: "test")
        session.state = .finished
        try store.save(session, in: directory)
        let probe = CancellationProbe()
        let app = AppState(sessionStore: store, transcribeOperation: { url, _, _, _, _ in
            await probe.started(url)
            return []
        })
        app.transcribeSession(session)
        app.cancelTranscription(session)
        for _ in 0..<200 {
            if app.transcribingSessionID == nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await probe.count == 0)
        #expect(!app.hasActiveWork)
        #expect(app.lastError == nil)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("transcript.txt").path))
    }
}

private actor CancellationProbe {
    private(set) var count = 0
    func started(_ url: URL) { count += 1 }
}
