import AVFoundation
import Foundation
import Testing

@testable import Ryokuon

@MainActor
struct PlayerTests {
    private func silentWAV(seconds: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        let writer = try WAVWriter(url: url)
        try writer.append([Int16](repeating: 0, count: 16000 * seconds))
        try writer.finish()
        return url
    }

    /// Regression: seeking used to let the previous segment's completion
    /// handler mark playback finished — the position bar froze mid-play.
    @Test func seekKeepsPositionAdvancing() async throws {
        let player = Player()
        var finished = 0
        player.onFinish = { finished += 1 }
        let url = try silentWAV(seconds: 6)

        try player.play(url: url, from: 0, meGain: 1, remoteGain: 1)
        try await Task.sleep(for: .milliseconds(300))
        try player.play(url: url, from: 3, meGain: 1, remoteGain: 1)
        try await Task.sleep(for: .milliseconds(600))

        #expect(player.isPlaying)
        #expect(finished == 0)
        #expect(player.currentTime > 3.2)
        player.stop()
    }

    @Test func finishingFiresOnFinishOnce() async throws {
        let player = Player()
        var finished = 0
        player.onFinish = { finished += 1 }
        try player.play(url: try silentWAV(seconds: 1), from: 0.5, meGain: 1, remoteGain: 1)
        try await Task.sleep(for: .milliseconds(1200))

        #expect(finished == 1)
        #expect(!player.isPlaying)
    }
    @Test func seekingPastEndDoesNotClaimPlaybackStarted() throws {
        let url = try silentWAV(seconds: 1)
        defer { try? FileManager.default.removeItem(at: url) }
        let player = Player()
        #expect(throws: (any Error).self) {
            try player.play(url: url, from: 2, meGain: 1, remoteGain: 1)
        }
        #expect(!player.isPlaying)
    }

}
