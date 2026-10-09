import Foundation
import Testing

@testable import Ryokuon

struct AudioLibraryTests {
    @Test func searchFindsRenamedSessionsAndTreatsWhitespaceAsEmpty() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(rootDirectory: root)
        var (session, directory) = try store.createSession(language: "ja-JP", targetBundleID: nil, targetDisplayName: "test")
        session.displayName = "Quarterly Review"
        try store.save(session, in: directory)
        try Data([1]).write(to: directory.appendingPathComponent("call.wav"))
        let snapshot = AudioLibraryScanner.scan(root: root)
        let results = AudioLibrarySearch.filter(snapshot.nodes, sessions: snapshot.sessions, query: "  REVIEW  ")
        #expect(results.count == 1)
        #expect(results.first?.children.first?.name == "call.wav")
        #expect(AudioLibrarySearch.filter(snapshot.nodes, sessions: snapshot.sessions, query: "   ").count == snapshot.nodes.count)
        #expect(AudioLibrarySearch.filter(snapshot.nodes, sessions: snapshot.sessions, query: "no match").isEmpty)
    }

    @Test func nestedSessionsAndAudioMatchTheDisk() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(rootDirectory: root)
        let (session, original) = try store.createSession(language: "ja-JP", targetBundleID: nil,
                                                          targetDisplayName: "test")
        let project = root.appendingPathComponent("Project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let moved = project.appendingPathComponent(session.id, isDirectory: true)
        try FileManager.default.moveItem(at: original, to: moved)
        try Data([1]).write(to: moved.appendingPathComponent("call.FLAC"))
        try Data([2]).write(to: project.appendingPathComponent("memo.MP3"))
        try Data([3]).write(to: project.appendingPathComponent("notes.md"))

        let snapshot = AudioLibraryScanner.scan(root: root)
        #expect(snapshot.error == nil)
        #expect(snapshot.sessions.count == 1)
        #expect(snapshot.sessions[0].relativePath == "Project/\(session.id)")
        #expect(snapshot.audioNode(at: "Project/\(session.id)/call.FLAC") != nil)
        #expect(snapshot.audioNode(at: "Project/memo.MP3") != nil)
        #expect(snapshot.audioNode(at: "Project/notes.md") == nil)
        #expect(store.directory(for: snapshot.sessions[0]) == moved)
        let json = try String(contentsOf: moved.appendingPathComponent("session.json"), encoding: .utf8)
        #expect(!json.contains("relativePath"))
    }

    @Test func sameSessionFolderNameInDifferentParentsKeepsBothLocations() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(rootDirectory: root)
        let (session, original) = try store.createSession(language: "ja-JP", targetBundleID: nil,
                                                          targetDisplayName: "test")
        for folder in ["A", "B"] {
            let parent = root.appendingPathComponent(folder, isDirectory: true)
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: original, to: parent.appendingPathComponent(session.id))
        }
        try FileManager.default.removeItem(at: original)
        #expect(Set(store.listSessions().map(\.relativePath)) == ["A/\(session.id)", "B/\(session.id)"])
    }

    @Test func symlinkedFoldersAreNotFollowed() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data([1]).write(to: outside.appendingPathComponent("outside.mp3"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("alias"), withDestinationURL: outside)
        let snapshot = AudioLibraryScanner.scan(root: root)
        #expect(snapshot.nodes.isEmpty)
        #expect(snapshot.audioNode(at: "alias/outside.mp3") == nil)
    }

    @Test func nestedFilesystemChangeTriggersWatcher() async throws {
        actor EventCount {
            var count = 0
            func increment() { count += 1 }
            func hasEvent() -> Bool { count > 0 }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = root.appendingPathComponent("A/B", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let count = EventCount()
        let watcher = AudioLibraryWatcher {
            Task { await count.increment() }
        }
        watcher.start(root: root)
        try await Task.sleep(for: .milliseconds(300))
        try Data([1]).write(to: nested.appendingPathComponent("new.wav"))
        var received = false
        for _ in 0 ..< 40 {
            if await count.hasEvent() { received = true; break }
            try await Task.sleep(for: .milliseconds(100))
        }
        watcher.stop()
        #expect(received)
    }
}
