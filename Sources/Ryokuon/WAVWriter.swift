import Foundation

private extension Data {
    mutating func append<T: FixedWidthInteger>(littleEndian value: T) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }
}

/// Streaming 16kHz/16-bit WAV writer with a crash-safe header. Mono or
/// stereo — the app writes one stereo file (left = me, right = remote; see
/// AudioCapture) but the writer itself doesn't care.
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
    let channels: UInt16
    private let handle: FileHandle
    private var dataBytesWritten: UInt32 = 0
    private var bytesSinceSync = 0
    private let syncEveryBytes: Int

    init(url: URL, channels: UInt16 = 1) throws {
        self.url = url
        self.channels = channels
        syncEveryBytes = Int(Self.sampleRate) * Int(channels) * 2 * 5 // ~5s
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: Self.header(dataBytes: 0, channels: channels))
    }

    /// Raw interleaved PCM samples — for a stereo writer, caller interleaves
    /// [L, R, L, R, ...] before calling.
    func append(_ samples: [Int16]) throws {
        guard !samples.isEmpty else { return }
        let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        dataBytesWritten += UInt32(data.count)
        bytesSinceSync += data.count
        if bytesSinceSync >= syncEveryBytes {
            try handle.synchronize()
            bytesSinceSync = 0
        }
    }

    /// Patches the header with the real data size. Call on normal stop.
    func finish() throws {
        try handle.synchronize()
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Self.header(dataBytes: dataBytesWritten, channels: channels))
        try handle.close()
    }

    /// Time-domain frame count (one sample per channel), independent of
    /// channel count — this is what you multiply by 1/sampleRate to get
    /// seconds.
    var framesWritten: Int { Int(dataBytesWritten) / 2 / Int(channels) }

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
    /// still says 0 bytes but the PCM data is on disk. `channels` must match
    /// what was actually being written (repairHeader can't recover it from
    /// the truncated file alone).
    static func repairHeader(at url: URL, channels: UInt16 = 1) throws {
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
        guard size > headerSize else { return }
        let dataBytes = UInt32(size - UInt64(headerSize))
        let handle = try FileHandle(forWritingTo: url)
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: header(dataBytes: dataBytes, channels: channels))
        try handle.close()
    }
}
