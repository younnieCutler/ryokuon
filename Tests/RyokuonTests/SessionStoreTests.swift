import Foundation
import Testing

@testable import Ryokuon

struct SessionStoreTests {
    private func tempRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    @Test func createSessionWritesReadableJSON() throws {
        let store = SessionStore(rootDirectory: tempRoot())
        let (session, directory) = try store.createSession(language: "ja-JP", targetBundleID: "com.example.app", targetDisplayName: "app")

        #expect(session.state == .recording)
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("session.json").path))

        let reloaded = try store.load(from: directory)
        #expect(reloaded.id == session.id)
        #expect(reloaded.language == "ja-JP")
    }

    @Test func secondSessionInSameMinuteGetsSuffixedID() throws {
        let store = SessionStore(rootDirectory: tempRoot())
        let (first, _) = try store.createSession(language: "ja-JP", targetBundleID: "com.example.app", targetDisplayName: "app")
        let (second, _) = try store.createSession(language: "ja-JP", targetBundleID: "com.example.app", targetDisplayName: "app")
        #expect(first.id != second.id)
    }

    /// Q11 end to end at the SessionStore level: a session left in
    /// `.recording` state (simulating a crash) with real PCM on disk but an
    /// unpatched header gets its header repaired and its state flipped. One
    /// stereo call.wav (Q: user decided 2026-08-09 on a single file, L=me
    /// R=remote, instead of two mono files) — repair must know it's 2ch or
    /// the recomputed duration comes out double.
    @Test func recoverCrashedSessionsRepairsHeaderAndUpdatesState() throws {
        let store = SessionStore(rootDirectory: tempRoot())
        let (session, directory) = try store.createSession(language: "ja-JP", targetBundleID: "com.example.app", targetDisplayName: "app")
        #expect(session.state == .recording)

        let callURL = directory.appendingPathComponent(AudioCapture.fileName)
        let writer = try WAVWriter(url: callURL, channels: 2)
        try writer.append([Int16](repeating: 0, count: 16000 * 2)) // 1s stereo, no finish() -> simulated crash
        // session.json still says .recording — never updated, as if the
        // process died right here.

        let recovered = store.recoverCrashedSessions()
        #expect(recovered.count == 1)
        #expect(recovered[0].state == .recovered)
        #expect(recovered[0].durationSeconds == 1.0)

        let reloaded = try store.load(from: directory)
        #expect(reloaded.state == .recovered)

        let callData = try Data(contentsOf: callURL)
        #expect(callData.count == 44 + 16000 * 2 * 2)
    }

    @Test func recoverCrashedSessionsIgnoresFinishedSessions() throws {
        let store = SessionStore(rootDirectory: tempRoot())
        let (session, directory) = try store.createSession(language: "ja-JP", targetBundleID: "com.example.app", targetDisplayName: "app")
        var finished = session
        finished.state = .finished
        try store.save(finished, in: directory)

        let recovered = store.recoverCrashedSessions()
        #expect(recovered.isEmpty)
    }

    @Test func listSessionsSortsNewestFirst() throws {
        let store = SessionStore(rootDirectory: tempRoot())
        let (first, dir1) = try store.createSession(language: "ja-JP", targetBundleID: "com.example.app", targetDisplayName: "app")
        var older = first
        older.displayName = "older"
        try store.save(older, in: dir1)

        Thread.sleep(forTimeInterval: 0.01)
        let (_, dir2) = try store.createSession(language: "ja-JP", targetBundleID: "com.example.app", targetDisplayName: "app")
        var newerSession = try store.load(from: dir2)
        newerSession.displayName = "newer"
        try store.save(newerSession, in: dir2)

        let sessions = store.listSessions()
        #expect(sessions.first?.displayName == "newer")
    }
}
