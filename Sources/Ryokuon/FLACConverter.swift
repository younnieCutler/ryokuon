import AVFoundation
import Foundation

enum FLACConverterError: Error {
    case emptySource
    case incompleteConversion
}

/// Q3: after transcription, `call.wav` (the STT-quality raw capture) isn't
/// needed anymore — `call.flac` is playable and roughly half the size.
/// Converts in place and only deletes the original once the FLAC file has
/// actually been read back and verified non-empty, so a crash mid-convert
/// can't lose both files.
enum FLACConverter {
    static func convert(sessionDirectory: URL) throws -> URL {
        try Task.checkCancellation()
        let wavURL = sessionDirectory.appendingPathComponent(AudioCapture.fileName)
        let flacURL = sessionDirectory.appendingPathComponent("call.flac")

        let stagedURL = sessionDirectory.appendingPathComponent(".\(UUID().uuidString).flac")
        defer { try? FileManager.default.removeItem(at: stagedURL) }
        let source = try AVAudioFile(forReading: wavURL)
        guard source.length > 0 else { throw FLACConverterError.emptySource }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatFLAC,
            AVSampleRateKey: source.processingFormat.sampleRate,
            AVNumberOfChannelsKey: source.processingFormat.channelCount,
            AVLinearPCMBitDepthKey: 16,
        ]
        try write(from: source, settings: settings, to: stagedURL)

        // `write(to:)` must return with `destination` (the writing
        // AVAudioFile) fully out of scope before this reopens the same path
        // for reading — AVAudioFile has no explicit close(), so its file
        // handle closes on deinit. Verifying while the writer was still
        // alive (both inline in this function) failed to even open the
        // file ('fmt?' / kAudioFileUnsupportedDataFormatError) despite
        // `afinfo` reading the exact same bytes on disk just fine — the
        // FLAC container wasn't finalized yet.
        let verify = try AVAudioFile(forReading: stagedURL)
        guard verify.length == source.length,
              verify.processingFormat.channelCount == source.processingFormat.channelCount,
              verify.processingFormat.sampleRate == source.processingFormat.sampleRate
        else { throw FLACConverterError.incompleteConversion }
        try Task.checkCancellation()
        try AtomicFile.publish(stagedURL, to: flacURL)

        try FileManager.default.removeItem(at: wavURL)
        return flacURL
    }

    private static func write(from source: AVAudioFile, settings: [String: Any], to flacURL: URL) throws {
        // `commonFormat`/`interleaved` here describe the format of buffers
        // *we* pass to `write(from:)` — AVAudioFile converts internally to
        // whatever `settings` describes. This must match what we actually
        // read into (source.processingFormat: float32, non-interleaved), or
        // `write(from:)` fails with paramErr (-50, confirmed by running it
        // with a mismatched int16-interleaved commonFormat here).
        let destination = try AVAudioFile(forWriting: flacURL, settings: settings,
                                          commonFormat: source.processingFormat.commonFormat,
                                          interleaved: source.processingFormat.isInterleaved)

        // Streamed in chunks, not one giant buffer — call.wav can be an
        // hour+ of audio (Q3's "1시간당 ~115MB"), no reason to hold all of
        // it in memory just to re-encode it.
        let chunkFrames: AVAudioFrameCount = 16000 * 10 // 10s per chunk
        guard let readBuffer = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: chunkFrames)
        else { throw FLACConverterError.emptySource }
        while source.framePosition < source.length {
            try Task.checkCancellation()
            readBuffer.frameLength = 0
            try source.read(into: readBuffer, frameCount: chunkFrames)
            guard readBuffer.frameLength > 0 else { throw FLACConverterError.incompleteConversion }
            try destination.write(from: readBuffer)
        }
    }
}
