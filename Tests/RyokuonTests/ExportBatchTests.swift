import Foundation
import Testing
@testable import Ryokuon

struct ExportBatchTests {
    @Test func failedSecondPublicationRestoresBothOriginals() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let outputs = [root.appendingPathComponent("meeting.mp3"), root.appendingPathComponent("meeting.md")]
        for output in outputs { try Data("old".utf8).write(to: output) }
        var batch = try ExportBatch(destinations: outputs, allowOverwrite: true)
        defer { batch.cleanup() }
        for output in outputs { try Data("new".utf8).write(to: batch.stagedURL(for: output)) }
        let failingSource = try batch.stagedURL(for: outputs[1])
        #expect(throws: (any Error).self) {
            try batch.commit { source, destination in
                if source == failingSource { throw CocoaError(.fileWriteNoPermission) }
                try FileManager.default.moveItem(at: source, to: destination)
            }
        }
        for output in outputs { #expect(try Data(contentsOf: output) == Data("old".utf8)) }
    }

    @Test func failedRollbackRetainsBackupAndRecoveryMap() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("meeting.mp3")
        try Data("old".utf8).write(to: output)
        var batch = try ExportBatch(destinations: [output], allowOverwrite: true)
        try Data("new".utf8).write(to: batch.stagedURL(for: output))
        #expect(throws: ExportBatchError.self) {
            try batch.commit { source, destination in
                if destination == output { throw CocoaError(.fileWriteNoPermission) }
                try FileManager.default.moveItem(at: source, to: destination)
            }
        }
        batch.cleanup()
        #expect(try Data(contentsOf: batch.stagingDirectory.appendingPathComponent("0.previous")) == Data("old".utf8))
        let mapping = try JSONDecoder().decode([String: String].self,
            from: Data(contentsOf: batch.stagingDirectory.appendingPathComponent("recovery.json")))
        #expect(mapping["0.previous"] == "meeting.mp3")
    }

    @Test func lateCollisionDoesNotOverwriteOrPublishOtherOutput() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let outputs = [root.appendingPathComponent("meeting.mp3"), root.appendingPathComponent("meeting.md")]
        var batch = try ExportBatch(destinations: outputs, allowOverwrite: false)
        defer { batch.cleanup() }
        for output in outputs { try Data("new".utf8).write(to: batch.stagedURL(for: output)) }
        try Data("someone else's export".utf8).write(to: outputs[1])
        #expect(throws: ExportBatchError.self) { try batch.commit() }
        #expect(!FileManager.default.fileExists(atPath: outputs[0].path))
        #expect(try Data(contentsOf: outputs[1]) == Data("someone else's export".utf8))
    }

    @Test func successfulBatchReplacesAllOutputs() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let outputs = [root.appendingPathComponent("meeting.mp3"), root.appendingPathComponent("meeting.md")]
        var batch = try ExportBatch(destinations: outputs, allowOverwrite: true)
        for output in outputs { try Data("new".utf8).write(to: batch.stagedURL(for: output)) }
        try batch.commit()
        batch.cleanup()
        #expect(!FileManager.default.fileExists(atPath: batch.stagingDirectory.path))
        for output in outputs { #expect(try Data(contentsOf: output) == Data("new".utf8)) }
    }
}
