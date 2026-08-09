import Foundation
import Testing

@testable import Ryokuon

/// Q11: a crash mid-recording must not lose what was already on disk. The
/// writer leaves a 0-byte-data header until `finish()` patches it — these
/// tests simulate the crash by skipping `finish()` and check that
/// `repairHeader` recovers the real size from the file alone.
struct WAVWriterTests {
    @Test func normalFinishProducesCorrectHeader() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = try WAVWriter(url: url)
        let samples: [Int16] = (0 ..< 16000).map { Int16($0 % 100) }
        try writer.append(samples)
        try writer.finish()

        let data = try Data(contentsOf: url)
        #expect(data.count == 44 + samples.count * 2)
        #expect(readUInt32LE(data, at: 40) == UInt32(samples.count * 2))
    }

    @Test func crashedRecordingIsRecoveredByRepairHeader() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = try WAVWriter(url: url)
        let samples: [Int16] = (0 ..< 48000).map { Int16($0 % 100) } // 3s @ 16kHz
        try writer.append(samples)
        // Simulate a crash: no finish(), header still claims 0 data bytes.

        let beforeRepair = try Data(contentsOf: url)
        #expect(readUInt32LE(beforeRepair, at: 40) == 0, "header should still be unpatched")
        #expect(beforeRepair.count == 44 + samples.count * 2, "PCM data is on disk despite the crash")

        try WAVWriter.repairHeader(at: url)

        let afterRepair = try Data(contentsOf: url)
        #expect(readUInt32LE(afterRepair, at: 40) == UInt32(samples.count * 2))

        let info = try wavInfo(url)
        #expect(info.frameCount == samples.count)
        #expect(info.sampleRate == 16000)
    }

    @Test func repairOnEmptyFileDoesNothing() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        FileManager.default.createFile(atPath: url.path, contents: Data())

        // Must not crash on a file with no header at all (e.g. crash before
        // the very first write completed).
        try WAVWriter.repairHeader(at: url)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }
}

private func readUInt32LE(_ data: Data, at offset: Int) -> UInt32 {
    let bytes = data[data.startIndex + offset ..< data.startIndex + offset + 4]
    return bytes.withUnsafeBytes { $0.load(as: UInt32.self) }
}

private func wavInfo(_ url: URL) throws -> (frameCount: Int, sampleRate: UInt32) {
    let data = try Data(contentsOf: url)
    let sampleRate = readUInt32LE(data, at: 24)
    let dataBytes = readUInt32LE(data, at: 40)
    return (Int(dataBytes) / 2, sampleRate)
}
