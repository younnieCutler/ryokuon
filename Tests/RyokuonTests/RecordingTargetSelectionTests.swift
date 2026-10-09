import Testing
@testable import Ryokuon

struct RecordingTargetSelectionTests {
    private let first = AudioProcess(objectID: 1, pid: 100001, bundleID: "same.app", isPlaying: true)
    private let second = AudioProcess(objectID: 2, pid: 100002, bundleID: "same.app", isPlaying: true)
    private let unbundled = AudioProcess(objectID: 3, pid: 100003, bundleID: nil, isPlaying: true)

    @Test func explicitChoiceDistinguishesProcessesWithTheSameBundle() {
        #expect(RecordingTargetSelection.choose(from: [first, second], selectedPID: second.pid, lastBundleID: "same.app")?.pid == second.pid)
    }
    @Test func aProcessWithoutABundleCanBeSelected() {
        #expect(RecordingTargetSelection.choose(from: [first, unbundled], selectedPID: unbundled.pid, lastBundleID: nil)?.pid == unbundled.pid)
    }
    @Test func disappearingChoiceDoesNotRecordAnUnrelatedApp() {
        #expect(RecordingTargetSelection.choose(from: [first], selectedPID: second.pid, lastBundleID: first.bundleID) == nil)
    }
}
