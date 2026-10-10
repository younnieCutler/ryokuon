import Foundation
import Testing
@testable import Ryokuon

struct MeetingWorkspaceTests {
    @Test func searchRequiresEveryTermAndFoldsDiacritics() {
        #expect(MeetingSearch.matches("Café: release plan", query: "cafe plan"))
        #expect(!MeetingSearch.matches("release plan", query: "release budget"))
        #expect(!MeetingSearch.matches("release", query: "  "))
    }

    @Test func searchIncludesNotesAndTranscriptInNestedFolders() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(rootDirectory: root)
        var (session, directory) = try store.createSession(language: "ja-JP", targetBundleID: nil, targetDisplayName: "Zoom")
        session.notes = "Decision: ship on Friday"
        session.bookmarks = [.init(id: UUID(), seconds: 1, title: "budget discussion")]
        try store.save(session, in: directory)
        try "0|M|Customer renewal".write(to: directory.appendingPathComponent("transcript.txt"), atomically: true, encoding: .utf8)
        let project = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: false)
        let nested = project.appendingPathComponent(session.id)
        try FileManager.default.moveItem(at: directory, to: nested)
        let loaded = try store.load(from: nested)
        let index = MeetingSearch.index(sessions: [loaded], root: root)
        #expect(MeetingSearch.matches(index[loaded.relativePath] ?? "", query: "Friday renewal budget"))
    }

    @Test func markdownIncludesNotesAndOnlySelectedMarkers() {
        let markers: [Session.Bookmark] = [.init(id: UUID(), seconds: 2, title: "early"),
                                         .init(id: UUID(), seconds: 12, title: "decision")]
        let text = MeetingMarkdown.appendix(notes: "Action: follow up", bookmarks: markers, range: 10...20)
        #expect(text.contains("Action: follow up"))
        #expect(text.contains("decision"))
        #expect(!text.contains("early"))
    }
}

@MainActor
struct MeetingPersistenceTests {
    @Test func staleNoteEditsPreserveMarkersAndGains() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(rootDirectory: root)
        var (session, directory) = try store.createSession(language: "ja-JP", targetBundleID: nil, targetDisplayName: "test")
        session.state = .finished
        session.durationSeconds = 30
        try store.save(session, in: directory)
        let app = AppState(sessionStore: store)
        app.addBookmark(to: session, at: 12, title: "Decision")
        #expect(app.saveNotes(session, text: "Follow up"))
        app.setGains(for: session, me: 2, remote: 0.5)
        let saved = try store.load(from: directory)
        #expect(saved.bookmarks.count == 1)
        #expect(saved.notes == "Follow up")
        #expect(saved.gains.me == 2)
        #expect(saved.transcriptionState == .notStarted)
    }

    @Test func deleteUsesTheRelativePathRatherThanDuplicatedFolderNames() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(rootDirectory: root)
        var (session, directory) = try store.createSession(language: "ja-JP", targetBundleID: nil, targetDisplayName: "test")
        session.state = .finished
        try store.save(session, in: directory)
        let project = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: false)
        let duplicate = project.appendingPathComponent(session.id)
        try FileManager.default.copyItem(at: directory, to: duplicate)
        let app = AppState(sessionStore: store)
        app.delete(["project/" + session.id])
        #expect(FileManager.default.fileExists(atPath: directory.path))
        #expect(!FileManager.default.fileExists(atPath: duplicate.path))
    }
}
