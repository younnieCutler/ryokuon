import Foundation

private extension Data {
    mutating func append<T: FixedWidthInteger>(littleEndian value: T) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }
}

/// Streaming mono 16kHz/16-bit WAV writer with a crash-safe header.
///
/// The header is written with `dataBytes: 0` up front and only patched to the
/// real size on `finish()`. If the process dies mid-recording, the header
/// still claims 0 bytes — `repairHeader` recomputes it from the file's actual
/// size so nothing recorded before the crash is lost (Q11: crash safety is
/// priority 1).
final class WAVWriter {
    static let sampleRate: UInt32 = 16000
    private static let headerSize = 44

    let url: URL
    private let handle: FileHandle
    private var dataBytesWritten: UInt32 = 0
    private var bytesSinceSync = 0
    private static let syncEveryBytes = Int(sampleRate) * 2 * 5 // ~5s of mono 16-bit

    init(url: URL) throws {
        self.url = url
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: Self.header(dataBytes: 0))
    }

    func append(_ samples: [Int16]) throws {
        guard !samples.isEmpty else { return }
        let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        dataBytesWritten += UInt32(data.count)
        bytesSinceSync += data.count
        if bytesSinceSync >= Self.syncEveryBytes {
            try handle.synchronize()
            bytesSinceSync = 0
        }
    }

    /// Patches the header with the real data size. Call on normal stop.
    func finish() throws {
        try handle.synchronize()
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Self.header(dataBytes: dataBytesWritten))
        try handle.close()
    }

    var framesWritten: Int { Int(dataBytesWritten) / 2 }

    static func header(dataBytes: UInt32, channels: UInt16 = 1, bitsPerSample: UInt16 = 16) -> Data {
        var data = Data(capacity: headerSize)
        let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)
        data.append(contentsOf: Array("RIFF".utf8))
        data.append(littleEndian: UInt32(36) + dataBytes)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        data.append(littleEndian: UInt32(16))
        data.append(littleEndian: UInt16(1)) // PCM
        data.append(littleEndian: channels)
        data.append(littleEndian: sampleRate)
        data.append(littleEndian: byteRate)
        data.append(littleEndian: blockAlign)
        data.append(littleEndian: bitsPerSample)
        data.append(contentsOf: Array("data".utf8))
        data.append(littleEndian: dataBytes)
        return data
    }

    /// Recomputes the header from the file's actual size. Used on next launch
    /// when a session directory is found in "recording" state — the header
    /// still says 0 bytes but the PCM data is on disk.
    static func repairHeader(at url: URL) throws {
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
        guard size > headerSize else { return }
        let dataBytes = UInt32(size - UInt64(headerSize))
        let handle = try FileHandle(forWritingTo: url)
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: header(dataBytes: dataBytes))
        try handle.close()
    }
}
