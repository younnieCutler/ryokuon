import Testing

@testable import Ryokuon

/// Q18: pure logic, no audio hardware needed to verify it.
struct SilenceWatchdogTests {
    @Test func firesWhenMicNeverHadSignal() {
        let watchdog = SilenceWatchdog(threshold: 30, silenceFloorDB: -75)
        var fired: (me: Bool, remote: Bool)?
        watchdog.onWarning = { fired = ($0, $1) }

        for _ in 0 ..< 30 {
            // me stays at digital silence (-inf), remote has real signal.
            watchdog.tick(meDB: -.infinity, remoteDB: -20, deltaTime: 1)
        }

        #expect(fired?.me == true)
        #expect(fired?.remote == false)
    }

    @Test func doesNotFireBeforeThreshold() {
        let watchdog = SilenceWatchdog(threshold: 30, silenceFloorDB: -75)
        var fired = false
        watchdog.onWarning = { _, _ in fired = true }

        for _ in 0 ..< 25 {
            watchdog.tick(meDB: -.infinity, remoteDB: -.infinity, deltaTime: 1)
        }
        #expect(fired == false)
    }

    @Test func doesNotFireWhenBothTracksHaveSignal() {
        let watchdog = SilenceWatchdog(threshold: 30, silenceFloorDB: -75)
        var fired = false
        watchdog.onWarning = { _, _ in fired = true }

        for _ in 0 ..< 40 {
            watchdog.tick(meDB: -30, remoteDB: -20, deltaTime: 1)
        }
        #expect(fired == false)
    }

    @Test func doesNotFireForSignalThatGoesQuietAfterStarting() {
        // A track that HAD signal and later falls silent (normal conversation
        // pause) must not trip the warning — only "never had signal" counts.
        let watchdog = SilenceWatchdog(threshold: 30, silenceFloorDB: -75)
        var fired = false
        watchdog.onWarning = { _, _ in fired = true }

        for _ in 0 ..< 5 { watchdog.tick(meDB: -30, remoteDB: -20, deltaTime: 1) }
        for _ in 0 ..< 40 { watchdog.tick(meDB: -.infinity, remoteDB: -.infinity, deltaTime: 1) }
        #expect(fired == false)
    }

    @Test func firesOnlyOnce() {
        let watchdog = SilenceWatchdog(threshold: 10, silenceFloorDB: -75)
        var fireCount = 0
        watchdog.onWarning = { _, _ in fireCount += 1 }

        for _ in 0 ..< 60 {
            watchdog.tick(meDB: -.infinity, remoteDB: -.infinity, deltaTime: 1)
        }
        #expect(fireCount == 1)
    }
}
