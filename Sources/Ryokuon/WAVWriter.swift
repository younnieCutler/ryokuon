import Darwin
import Foundation

private extension Data {
    mutating func append<T: FixedWidthInteger>(littleEndian value: T) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }
}

enum WAVWriterError: LocalizedError {
    case invalidChannels, incompleteFrame, fileTooLarge, closed, invalidHeader
    var errorDescription: String? {
        switch self {
        case .invalidChannels: "Only mono and stereo PCM are supported."
        case .incompleteFrame: "The audio buffer contains an incomplete frame."
        case .fileTooLarge: "The WAV size limit was reached. Start a new recording."
        case .closed: "The recording file is already closed."
        case .invalidHeader: "This file is not a Ryokuon PCM WAV; it was left unchanged."
        }
    }
}

/// Queue-confined streaming PCM writer. Never overwrites an existing recording.
/// The zero-length header can be recovered from complete frames after a crash.
final class WAVWriter {
    static let sampleRate: UInt32 = 16000
    private static let headerSize = 44
    static let maximumDataBytes = UInt32.max - 36
    let url: URL
    let channels: UInt16
    private let handle: FileHandle
    private var dataBytesWritten: UInt32 = 0
    private var bytesSinceSync = 0
    private let syncEveryBytes: Int
    private var isClosed = false

    init(url: URL, channels: UInt16 = 1) throws {
        guard (1...2).contains(channels) else { throw WAVWriterError.invalidChannels }
        self.url = url
        self.channels = channels
        syncEveryBytes = Int(Self.sampleRate) * Int(channels) * 2 * 5
        let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do { try handle.write(contentsOf: Self.header(dataBytes: 0, channels: channels)) }
        catch { try? handle.close(); try? FileManager.default.removeItem(at: url); throw error }
    }

    deinit { try? handle.close() }

    func append(_ samples: [Int16]) throws {
        guard !isClosed else { throw WAVWriterError.closed }
        guard samples.count % Int(channels) == 0 else { throw WAVWriterError.incompleteFrame }
        guard !samples.isEmpty else { return }
        let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        guard UInt64(dataBytesWritten) + UInt64(data.count) <= UInt64(Self.maximumDataBytes) else {
            throw WAVWriterError.fileTooLarge
        }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        dataBytesWritten += UInt32(data.count)
        bytesSinceSync += data.count
        if bytesSinceSync >= syncEveryBytes {
            try handle.synchronize()
            bytesSinceSync = 0
        }
    }

    func finish() throws {
        guard !isClosed else { return }
        defer { isClosed = true; try? handle.close() }
        try handle.synchronize()
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Self.header(dataBytes: dataBytesWritten, channels: channels))
        try handle.synchronize()
    }

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
        data.append(littleEndian: UInt16(1))
        data.append(littleEndian: channels)
        data.append(littleEndian: sampleRate)
        data.append(littleEndian: byteRate)
        data.append(littleEndian: blockAlign)
        data.append(littleEndian: bitsPerSample)
        data.append(contentsOf: Array("data".utf8))
        data.append(littleEndian: dataBytes)
        return data
    }

    static func repairHeader(at url: URL, channels: UInt16 = 1) throws {
        guard (1...2).contains(channels) else { throw WAVWriterError.invalidChannels }
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        guard size > headerSize else { return }
        try handle.seek(toOffset: 0)
        let actual = try handle.read(upToCount: headerSize) ?? Data()
        let expected = header(dataBytes: 0, channels: channels)
        // RIFF and data lengths are the only bytes allowed to differ.
        guard actual.count == headerSize,
              actual[0..<4] == expected[0..<4],
              actual[8..<40] == expected[8..<40] else { throw WAVWriterError.invalidHeader }
        let frameBytes = UInt64(channels) * 2
        let payload = size - UInt64(headerSize)
        let completeBytes = payload - payload % frameBytes
        guard completeBytes <= UInt64(maximumDataBytes) else { throw WAVWriterError.fileTooLarge }
        // A failed write may end halfway through a stereo frame. Discard only
        // that incomplete tail; every complete frame remains available.
        try handle.truncate(atOffset: UInt64(headerSize) + completeBytes)
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: header(dataBytes: UInt32(completeBytes), channels: channels))
        try handle.synchronize()
    }
}
