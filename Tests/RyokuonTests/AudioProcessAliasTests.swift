import Testing

@testable import Ryokuon

/// Real bundle IDs seen from this machine's actual CoreAudio process list
/// (`ryokuon list`) — helper subprocesses, not the main app bundle ID,
/// which is exactly why `displayName` needed this table (a real session
/// once showed "com.google.Chrome.helper" as the recording target).
struct AudioProcessAliasTests {
    @Test func matchesChromeHelperVariants() throws {
        #expect(AudioProcess.friendlyName(forBundleID: "com.google.Chrome.helper") == "Chrome")
        #expect(AudioProcess.friendlyName(forBundleID: "com.google.Chrome.helper.Renderer") == "Chrome")
        #expect(AudioProcess.friendlyName(forBundleID: "com.google.Chrome") == "Chrome")
    }

    @Test func matchesTeamsHelperAndModulehost() throws {
        #expect(AudioProcess.friendlyName(forBundleID: "com.microsoft.teams2.helper") == "Teams")
        #expect(AudioProcess.friendlyName(forBundleID: "com.microsoft.teams2.modulehost") == "Teams")
    }

    @Test func matchesZoomSlackDiscord() throws {
        #expect(AudioProcess.friendlyName(forBundleID: "us.zoom.xos") == "Zoom")
        #expect(AudioProcess.friendlyName(forBundleID: "com.tinyspeck.slackmacgap") == "Slack")
        #expect(AudioProcess.friendlyName(forBundleID: "com.hnc.Discord") == "Discord")
    }

    @Test func unknownBundleIDReturnsNil() throws {
        #expect(AudioProcess.friendlyName(forBundleID: "com.apple.mediaremoted") == nil)
    }

    @Test func caseInsensitive() throws {
        #expect(AudioProcess.friendlyName(forBundleID: "US.ZOOM.XOS") == "Zoom")
    }
}
