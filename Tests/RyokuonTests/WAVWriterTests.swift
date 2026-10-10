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

    /// The app writes one stereo file (L=me, R=remote) instead of two mono
    /// files — repair must use the right channel count or the recomputed
    /// frame count (and therefore duration) comes out 2x wrong.
    @Test func stereoRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = try WAVWriter(url: url, channels: 2)
        let interleaved: [Int16] = (0 ..< 32000).map { Int16($0 % 100) } // 16000 frames stereo
        try writer.append(interleaved)
        #expect(writer.framesWritten == 16000)
        try writer.finish()

        let data = try Data(contentsOf: url)
        #expect(readUInt16LE(data, at: 22) == 2, "channel count in header")
        #expect(readUInt32LE(data, at: 40) == UInt32(interleaved.count * 2))
    }

    @Test func stereoCrashRecoveryUsesCorrectChannelCount() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = try WAVWriter(url: url, channels: 2)
        try writer.append([Int16](repeating: 0, count: 32000)) // 16000 frames stereo, no finish()

        try WAVWriter.repairHeader(at: url, channels: 2)

        let data = try Data(contentsOf: url)
        #expect(readUInt32LE(data, at: 40) == 32000 * 2)
    }
}

private func readUInt32LE(_ data: Data, at offset: Int) -> UInt32 {
    let bytes = data[data.startIndex + offset ..< data.startIndex + offset + 4]
    return bytes.withUnsafeBytes { $0.load(as: UInt32.self) }
}

private func readUInt16LE(_ data: Data, at offset: Int) -> UInt16 {
    let bytes = data[data.startIndex + offset ..< data.startIndex + offset + 2]
    return bytes.withUnsafeBytes { $0.load(as: UInt16.self) }
}

private func wavInfo(_ url: URL) throws -> (frameCount: Int, sampleRate: UInt32) {
    let data = try Data(contentsOf: url)
    let sampleRate = readUInt32LE(data, at: 24)
    let dataBytes = readUInt32LE(data, at: 40)
    return (Int(dataBytes) / 2, sampleRate)
}

struct WAVWriterSafetyTests {
    @Test func existingAudioCannotBeOverwritten() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let original = Data("valuable audio".utf8)
        try original.write(to: url)
        #expect(throws: (any Error).self) { _ = try WAVWriter(url: url) }
        #expect(try Data(contentsOf: url) == original)
    }

    @Test func rejectsIncompleteStereoFramesAndClosedWrites() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try WAVWriter(url: url, channels: 2)
        #expect(throws: WAVWriterError.self) { try writer.append([1]) }
        try writer.append([1, 2])
        try writer.finish()
        try writer.finish()
        #expect(throws: WAVWriterError.self) { try writer.append([3, 4]) }
        #expect(try Data(contentsOf: url).count == 48)
    }

    @Test func recoveryDiscardsOnlyAnIncompleteTail() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        var original = WAVWriter.header(dataBytes: 0, channels: 2)
        original.append(contentsOf: [1, 0, 2, 0, 3])
        try original.write(to: url)
        try WAVWriter.repairHeader(at: url, channels: 2)
        let repaired = try Data(contentsOf: url)
        #expect(repaired.count == 48)
        #expect(Array(repaired.suffix(4)) == [1, 0, 2, 0])
        #expect(readUInt32LE(repaired, at: 40) == 4)
    }

    @Test func recoveryNeverRewritesAnUnknownFormat() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let original = Data(repeating: 7, count: 100)
        try original.write(to: url)
        #expect(throws: WAVWriterError.self) { try WAVWriter.repairHeader(at: url) }
        #expect(try Data(contentsOf: url) == original)
    }
}
