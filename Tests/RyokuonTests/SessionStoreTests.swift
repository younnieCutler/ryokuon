import Foundation
import Testing

@testable import Ryokuon

struct SessionStoreTests {
    private func tempRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    private func fakeProcess(pid: pid_t = 999, bundleID: String = "com.example.app") -> AudioProcess {
        AudioProcess(objectID: 1, pid: pid, bundleID: bundleID, isPlaying: true)
    }

    @Test func createSessionWritesReadableJSON() throws {
        let store = SessionStore(rootDirectory: tempRoot())
        let (session, directory) = try store.createSession(language: "ja-JP", target: fakeProcess())

        #expect(session.state == .recording)
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("session.json").path))

        let reloaded = try store.load(from: directory)
        #expect(reloaded.id == session.id)
        #expect(reloaded.language == "ja-JP")
    }

    @Test func secondSessionInSameMinuteGetsSuffixedID() throws {
        let store = SessionStore(rootDirectory: tempRoot())
        let (first, _) = try store.createSession(language: "ja-JP", target: fakeProcess())
        let (second, _) = try store.createSession(language: "ja-JP", target: fakeProcess())
        #expect(first.id != second.id)
    }

    /// Q11 end to end at the SessionStore level: a session left in
    /// `.recording` state (simulating a crash) with real PCM on disk but an
    /// unpatched header gets its header repaired and its state flipped.
    @Test func recoverCrashedSessionsRepairsHeaderAndUpdatesState() throws {
        let store = SessionStore(rootDirectory: tempRoot())
        let (session, directory) = try store.createSession(language: "ja-JP", target: fakeProcess())
        #expect(session.state == .recording)

        let meURL = directory.appendingPathComponent("me.wav")
        let remoteURL = directory.appendingPathComponent("remote.wav")
        let writer1 = try WAVWriter(url: meURL)
        try writer1.append([Int16](repeating: 0, count: 16000)) // 1s, no finish() -> simulated crash
        let writer2 = try WAVWriter(url: remoteURL)
        try writer2.append([Int16](repeating: 0, count: 16000))
        // session.json still says .recording — never updated, as if the
        // process died right here.

        let recovered = store.recoverCrashedSessions()
        #expect(recovered.count == 1)
        #expect(recovered[0].state == .recovered)
        #expect(recovered[0].durationSeconds == 1.0)

        let reloaded = try store.load(from: directory)
        #expect(reloaded.state == .recovered)

        let meData = try Data(contentsOf: meURL)
        #expect(meData.count == 44 + 16000 * 2)
    }

    @Test func recoverCrashedSessionsIgnoresFinishedSessions() throws {
        let store = SessionStore(rootDirectory: tempRoot())
        let (session, directory) = try store.createSession(language: "ja-JP", target: fakeProcess())
        var finished = session
        finished.state = .finished
        try store.save(finished, in: directory)

        let recovered = store.recoverCrashedSessions()
        #expect(recovered.isEmpty)
    }

    @Test func listSessionsSortsNewestFirst() throws {
        let store = SessionStore(rootDirectory: tempRoot())
        let (first, dir1) = try store.createSession(language: "ja-JP", target: fakeProcess())
        var older = first
        older.displayName = "older"
        try store.save(older, in: dir1)

        Thread.sleep(forTimeInterval: 0.01)
        let (_, dir2) = try store.createSession(language: "ja-JP", target: fakeProcess())
        var newerSession = try store.load(from: dir2)
        newerSession.displayName = "newer"
        try store.save(newerSession, in: dir2)

        let sessions = store.listSessions()
        #expect(sessions.first?.displayName == "newer")
    }
}
