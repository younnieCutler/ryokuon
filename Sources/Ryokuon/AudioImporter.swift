import AVFoundation
import Foundation

enum AudioImporterError: Error {
    case unsupportedFormat
}

/// Turns an outside recording (iPhone voice memo m4a, mp3, wav) into a
/// normal session: decoded and resampled to the same 16kHz mono `call.wav`
/// a no-headset recording produces, so Transcriber/Player/FLACConverter and
/// the MP3 export all work on it unchanged. Downsampling to 16kHz is fine
/// for speech (the app's whole purpose) but would audibly dull music.
enum AudioImporter {
    static func importFile(_ url: URL, store: SessionStore, language: String) throws -> Session {
        let source = try AVAudioFile(forReading: url)
        var (session, directory) = try store.createSession(
            language: language, targetBundleID: nil, targetDisplayName: url.lastPathComponent, channels: 1
        )
        do {
            let writer = try WAVWriter(url: directory.appendingPathComponent(AudioCapture.fileName))
            try convert(source, into: writer)
            try writer.finish()

            session.displayName = url.deletingPathExtension().lastPathComponent
            session.state = .finished
            session.durationSeconds = Double(writer.framesWritten) / Double(WAVWriter.sampleRate)
            try store.save(session, in: directory)
            return session
        } catch {
            // Don't leave a half-written session behind in the sidebar.
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private static func convert(_ source: AVAudioFile, into writer: WAVWriter) throws {
        let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(WAVWriter.sampleRate),
                                         channels: 1, interleaved: true)!
        guard let converter = AVAudioConverter(from: source.processingFormat, to: targetFormat)
        else { throw AudioImporterError.unsupportedFormat }
        converter.downmix = true // stereo source -> average both channels, not just keep L

        let chunkFrames: AVAudioFrameCount = 16000 * 10
        let reader = ChunkReader(file: source, chunkFrames: chunkFrames)
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: chunkFrames)
        else { throw AudioImporterError.unsupportedFormat }

        while true {
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
                guard let buffer = reader.next() else { outStatus.pointee = .endOfStream; return nil }
                outStatus.pointee = .haveData
                return buffer
            }
            if let conversionError { throw conversionError }
            if output.frameLength > 0, let samples = output.int16ChannelData {
                try writer.append(Array(UnsafeBufferPointer(start: samples[0], count: Int(output.frameLength))))
            }
            if status == .endOfStream || status == .error { break }
        }
    }

    /// Feeds the converter's input block one chunk at a time; a class so
    /// the block can advance it without capturing a mutable local.
    private final class ChunkReader: @unchecked Sendable {
        let file: AVAudioFile
        let chunkFrames: AVAudioFrameCount
        init(file: AVAudioFile, chunkFrames: AVAudioFrameCount) {
            self.file = file
            self.chunkFrames = chunkFrames
        }

        func next() -> AVAudioPCMBuffer? {
            guard file.framePosition < file.length,
                  let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunkFrames),
                  (try? file.read(into: buffer, frameCount: chunkFrames)) != nil,
                  buffer.frameLength > 0
            else { return nil }
            return buffer
        }
    }
}
