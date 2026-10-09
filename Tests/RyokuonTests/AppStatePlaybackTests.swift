import Foundation
import Testing
@testable import Ryokuon

@MainActor
struct AppStatePlaybackTests {
    @Test(.enabled(if: !listOutputDevices().isEmpty, "An audio output device is required"))
    func pauseSeekAndResumePreserveTheSelectedRecording() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(rootDirectory: root)
        var (session, directory) = try store.createSession(language: "ja-JP", targetBundleID: nil,
                                                          targetDisplayName: "test", channels: 1)
        let writer = try WAVWriter(url: directory.appendingPathComponent("call.wav"))
        try writer.append([Int16](repeating: 0, count: 16000 * 6))
        try writer.finish()
        session.state = .finished
        session.durationSeconds = 6
        try store.save(session, in: directory)
        let app = AppState(sessionStore: store)
        defer { app.stopPlayback() }
        app.play(session, from: 1)
        try await Task.sleep(for: .milliseconds(300))
        app.pausePlayback()
        #expect(app.isPlaybackPaused)
        #expect(!app.player.isPlaying)
        #expect(app.playbackTime >= 1)
        #expect(app.playingAudioPath == session.relativePath + "/call.wav")
        app.seekPlayback(session, toSeconds: 3)
        #expect(app.playbackTime == 3)
        #expect(!app.player.isPlaying)
        app.togglePlayback(session)
        try await Task.sleep(for: .milliseconds(400))
        #expect(!app.isPlaybackPaused)
        #expect(app.player.currentTime > 3.1)
        app.seekPlayback(session, toSeconds: 6)
        #expect(app.lastError == nil, "Seeking to the end must not produce an invalid-position alert")
    }
}
