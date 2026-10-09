import Foundation
import Testing

@testable import Ryokuon

@MainActor
struct AppStatePersistenceTests {
    @Test func deletingNestedSessionDoesNotDeleteItsSameNamedSibling() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(rootDirectory: root)
        var (session, original) = try store.createSession(language: "ja-JP", targetBundleID: nil, targetDisplayName: "test")
        session.state = .finished
        try store.save(session, in: original)
        for name in ["A", "B"] {
            let parent = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: original, to: parent.appendingPathComponent(session.id))
        }
        try FileManager.default.removeItem(at: original)
        // Inject a temporary-store deletion: tests never write to the user's Trash.
        let app = AppState(sessionStore: store, trashSession: { try store.delete($0) })
        #expect(app.delete(["A/\(session.id)"]))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("A/\(session.id)").path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("B/\(session.id)").path))
        #expect(app.sessions.map(\.relativePath) == ["B/\(session.id)"])
    }

    @Test func failedTrashKeepsTheSessionVisibleAndReportsFailure() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(rootDirectory: root)
        var (session, directory) = try store.createSession(language: "ja-JP", targetBundleID: nil, targetDisplayName: "test")
        session.state = .finished
        try store.save(session, in: directory)
        let app = AppState(sessionStore: store, trashSession: { _ in throw CocoaError(.fileWriteNoPermission) })
        #expect(!app.delete([session.relativePath]))
        #expect(app.sessions.count == 1)
        #expect(app.lastError != nil)
        #expect(FileManager.default.fileExists(atPath: directory.path))
    }

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
