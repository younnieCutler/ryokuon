import Foundation
import Testing
@testable import Ryokuon

struct SessionExportPlanTests {
    private var session: Session {
        Session(id: "test", displayName: "../Meeting: review", language: "en-US", targetBundleID: nil,
                targetDisplayName: "test", createdAt: Date(), state: .finished, durationSeconds: 10, gains: .init())
    }

    @Test func fractionalRangesHaveDifferentNamesAndStayInsideTheDestination() throws {
        let directory = URL(fileURLWithPath: "/tmp/ryokuon-export-test", isDirectory: true)
        let a = try SessionExportPlan(session: session, range: 1.1...2.1, directory: directory, mp3: true, markdown: false)
        let b = try SessionExportPlan(session: session, range: 1.2...2.2, directory: directory, mp3: true, markdown: false)
        #expect(a.mp3URL != b.mp3URL)
        #expect(a.mp3URL?.deletingLastPathComponent() == directory)
        #expect(a.markdownURL == nil)
    }

    @Test func detectsOnlySelectedExistingFormats() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let plan = try SessionExportPlan(session: session, range: 0...10, directory: root, mp3: true, markdown: true)
        let mp3 = try #require(plan.mp3URL)
        try Data([1]).write(to: mp3)
        #expect(plan.existingURLs == [mp3])
        let markdownOnly = try SessionExportPlan(session: session, range: 0...10, directory: root, mp3: false, markdown: true)
        #expect(markdownOnly.existingURLs.isEmpty)
    }

    @Test func rejectsOutOfBoundsAndEmptyRanges() {
        for range in [-1.0...1.0, 0.0...11.0, 2.0...2.0] {
            #expect(throws: (any Error).self) {
                try SessionExportPlan(session: session, range: range, directory: URL(fileURLWithPath: "/tmp"), mp3: true, markdown: false)
            }
        }
    }
}
