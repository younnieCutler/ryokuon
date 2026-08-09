import Foundation

/// Q18: catches "recorded an hour with the mic muted" — the most common
/// real-world recording accident. Pure logic, no CoreAudio dependency, so
/// it's fully unit-testable without real audio hardware.
///
/// Deliberately narrow: it only fires once, only for "never had a signal
/// since recording started." A track that had signal and then goes quiet
/// is NOT flagged — that's indistinguishable from normal silence in a call,
/// per the design doc's explicit call.
final class SilenceWatchdog {
    private let threshold: TimeInterval
    private let silenceFloorDB: Float
    private var meHasHadSignal = false
    private var remoteHasHadSignal = false
    private var elapsed: TimeInterval = 0
    private var warned = false

    /// Called at most once, when `threshold` has elapsed with one or both
    /// tracks never having exceeded the silence floor.
    var onWarning: ((_ meSilent: Bool, _ remoteSilent: Bool) -> Void)?

    init(threshold: TimeInterval = 30, silenceFloorDB: Float = -75) {
        self.threshold = threshold
        self.silenceFloorDB = silenceFloorDB
    }

    func tick(meDB: Float, remoteDB: Float, deltaTime: TimeInterval) {
        if meDB > silenceFloorDB { meHasHadSignal = true }
        if remoteDB > silenceFloorDB { remoteHasHadSignal = true }
        elapsed += deltaTime

        guard !warned, elapsed >= threshold else { return }
        guard !meHasHadSignal || !remoteHasHadSignal else { return }

        warned = true
        onWarning?(!meHasHadSignal, !remoteHasHadSignal)
    }
}
