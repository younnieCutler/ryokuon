import Foundation
import Testing
@testable import Ryokuon

struct ProcessLeaseTests {
    @Test func rejectsASecondWriterAndReleasesOnExit() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var first: ProcessLease? = try ProcessLease(directory: root)
        #expect(first != nil)
        #expect(throws: (any Error).self) { _ = try ProcessLease(directory: root) }
        first = nil
        let next = try ProcessLease(directory: root)
        withExtendedLifetime(next) {}
    }
}
