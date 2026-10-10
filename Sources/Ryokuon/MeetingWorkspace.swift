import Foundation
import SwiftUI

/// Search is rebuilt off the UI thread and never uploads meeting content.
/// It includes transcript, notes, markers, title and the recorded application.
enum MeetingSearch {
    static func index(sessions: [Session], root: URL) -> [String: String] {
        Dictionary(uniqueKeysWithValues: sessions.map { session in
            let transcript = root.appendingPathComponent(session.relativePath).appendingPathComponent("transcript.txt")
            let text = (try? String(contentsOf: transcript, encoding: .utf8)) ?? ""
            let fields = [session.displayName, session.targetDisplayName, session.notes,
                          session.bookmarks.map(\.title).joined(separator: "\n"), text]
            return (session.relativePath, fields.joined(separator: "\n"))
        })
    }

    static func matches(_ text: String, query: String) -> Bool {
        let terms = query.split(whereSeparator: \.isWhitespace)
        return !terms.isEmpty && terms.allSatisfy { text.localizedStandardContains(String($0)) }
    }
}

enum MeetingMarkdown {
    static func appendix(notes: String, bookmarks: [Session.Bookmark], range: ClosedRange<Double>? = nil) -> String {
        var sections: [String] = []
        if !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append("\n## Meeting notes\n\n" + notes + "\n")
        }
        let selected = bookmarks.filter { range?.contains($0.seconds) ?? true }
        if !selected.isEmpty {
            sections.append("\n## Bookmarks\n\n" + selected.map {
                "- [\(formattedDuration($0.seconds))] \($0.title.isEmpty ? "Bookmark" : $0.title.replacingOccurrences(of: "\n", with: " "))"
            }.joined(separator: "\n") + "\n")
        }
        return sections.joined()
    }
}

struct MeetingNotesSheet: View {
    let appState: AppState
    let session: Session
    @Environment(\.dismiss) private var dismiss
    @State private var draft: String

    init(appState: AppState, session: Session) {
        self.appState = appState
        self.session = session
        _draft = State(initialValue: session.notes)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(appState.t(.meetingNotes), systemImage: "note.text").font(.title2.bold())
            Text(appState.t(.meetingNotesHint)).foregroundStyle(.secondary)
            TextEditor(text: $draft)
                .font(.body)
                .accessibilityLabel(appState.t(.meetingNotes))
                .padding(8)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.3)))
            if let error = appState.lastError {
                Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
            }
            HStack {
                Button(appState.t(.cancelButton)) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(appState.t(.saveNotes)) {
                    if appState.saveNotes(session, text: draft) { dismiss() }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(minWidth: 420, idealWidth: 600, minHeight: 320, idealHeight: 480)
        .interactiveDismissDisabled(draft != session.notes)
    }
}

struct MeetingBookmarksView: View {
    let appState: AppState
    let session: Session
    @State private var title = ""

    private var position: Double {
        appState.playingAudioPath?.hasPrefix(session.relativePath + "/") == true ? appState.playbackTime : 0
    }

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    TextField(appState.t(.bookmarkTitle), text: $title)
                        .onSubmit { add() }
                    Button { add() } label: {
                        Label(appState.t(.addBookmark), systemImage: "bookmark.badge.plus")
                    }
                    .disabled(session.state == .recording)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(session.bookmarks) { bookmark in
                            HStack {
                                Button {
                                    appState.seekPlayback(session, toSeconds: bookmark.seconds)
                                } label: {
                                    Text("\(formattedDuration(bookmark.seconds))  \(bookmark.title.isEmpty ? appState.t(.bookmark) : bookmark.title)")
                                        .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .buttonStyle(.plain)
                                Button(role: .destructive) { appState.removeBookmark(bookmark, from: session) } label: {
                                    Image(systemName: "xmark.circle")
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(appState.t(.removeBookmark))
                            }
                        }
                    }
                }
                .frame(maxHeight: 120)
            }
            .padding(.top, 8)
        } label: {
            Label("\(appState.t(.bookmarks)) (\(session.bookmarks.count))", systemImage: "bookmark")
                .font(.caption)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func add() {
        appState.addBookmark(to: session, at: min(position, session.durationSeconds), title: title)
        title = ""
    }
}
