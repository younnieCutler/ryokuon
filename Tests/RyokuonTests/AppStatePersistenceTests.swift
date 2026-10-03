import Foundation
import Testing

@testable import Ryokuon

@MainActor
struct AppStatePersistenceTests {
    @Test func staleEditsPreserveOtherMetadata() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(rootDirectory: root)
        var (session, directory) = try store.createSession(language: "ja-JP", targetBundleID: nil, targetDisplayName: "test")
        session.state = .finished
        try store.save(session, in: directory)
        let app = AppState(sessionStore: store)
        app.rename(session, to: "Renamed")
        app.setGains(for: session, me: 2, remote: 0.5)
        app.setLanguage(for: session, to: "ko-KR")
        let saved = try store.load(from: directory)
        #expect(saved.displayName == "Renamed")
        #expect(saved.gains.me == 2)
        #expect(saved.language == "ko-KR")
    }

    @Test func failedSaveDoesNotPublishAnUnsavedRename() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(rootDirectory: root)
        var (session, directory) = try store.createSession(language: "ja-JP", targetBundleID: nil, targetDisplayName: "test")
        session.state = .finished
        try store.save(session, in: directory)
        let app = AppState(sessionStore: store)
        try FileManager.default.removeItem(at: directory)
        app.rename(session, to: "Not saved")
        #expect(app.sessions.first?.displayName == session.displayName)
        #expect(app.lastError != nil)
    }
}
