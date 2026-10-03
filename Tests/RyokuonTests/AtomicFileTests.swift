import Foundation
import Testing

@testable import Ryokuon

struct AtomicFileTests {
    @Test func completedStagingFileReplacesExistingExport() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let staged = root.appendingPathComponent("staged")
        let destination = root.appendingPathComponent("export")
        try Data("old".utf8).write(to: destination)
        try Data("complete".utf8).write(to: staged)
        try AtomicFile.publish(staged, to: destination)
        #expect(try Data(contentsOf: destination) == Data("complete".utf8))
        #expect(!FileManager.default.fileExists(atPath: staged.path))
    }
}
