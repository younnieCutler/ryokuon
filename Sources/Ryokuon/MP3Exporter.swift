import AVFoundation
import Foundation

enum MP3ExporterError: Error {
    case lameNotInstalled
    case noAudio
    case invalidRange
    case unsupportedAudio
    case incompleteAudio
    case lameFailed(Int32)
}

/// CoreAudio can decode MP3 but not encode it, so this shells out to the
/// `lame` binary bundled in the app (the app isn't sandboxed). The selected range is
/// first written to a temp 16-bit WAV — lame can't read FLAC, and this is
/// also where the session's stored ME/REMOTE gain (Q4) gets baked in.
enum MP3Exporter {
    /// The copy bundle.sh ships in Contents/Helpers first; Homebrew's only
    /// matters for `swift run`/`swift test`, where there is no app bundle.
    static var lameURL: URL? {
        [Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/lame"),
         URL(fileURLWithPath: "/opt/homebrew/bin/lame"), URL(fileURLWithPath: "/usr/local/bin/lame")]
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static func export(from audioURL: URL, range: ClosedRange<Double>, gains: Session.Gains,
                       bitrate: Int, mono: Bool, to mp3URL: URL) throws {
        guard range.lowerBound.isFinite, range.upperBound.isFinite,
              range.lowerBound >= 0, range.upperBound > range.lowerBound,
              gains.me.isFinite, gains.remote.isFinite else { throw MP3ExporterError.invalidRange }
        guard let lame = lameURL else { throw MP3ExporterError.lameNotInstalled }
        let tempWAV = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: tempWAV) }
        try writeRange(of: audioURL, range: range, gains: gains, to: tempWAV)

        let stagedURL = mp3URL.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).mp3")
        defer { try? FileManager.default.removeItem(at: stagedURL) }
        let process = Process()
        process.executableURL = lame
        process.arguments = ["--quiet", "-b", "\(bitrate)"] + (mono ? ["-m", "m"] : []) + [tempWAV.path, stagedURL.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw MP3ExporterError.lameFailed(process.terminationStatus) }
        let output = try AVAudioFile(forReading: stagedURL)
        guard output.length > 0 else { throw MP3ExporterError.incompleteAudio }
        try AtomicFile.publish(stagedURL, to: mp3URL)
    }

    private static func writeRange(of audioURL: URL, range: ClosedRange<Double>, gains: Session.Gains,
                                   to wavURL: URL) throws {
        let source = try AVAudioFile(forReading: audioURL)
        let rate = source.processingFormat.sampleRate
        let channels = Int(source.processingFormat.channelCount)
        guard rate == Double(WAVWriter.sampleRate), (1 ... 2).contains(channels)
        else { throw MP3ExporterError.unsupportedAudio }
        let duration = Double(source.length) / rate
        guard range.lowerBound < duration else { throw MP3ExporterError.noAudio }
        let start = AVAudioFramePosition(range.lowerBound * rate)
        let end = min(AVAudioFramePosition(min(range.upperBound, duration) * rate), source.length)
        guard end > start else { throw MP3ExporterError.noAudio }
        source.framePosition = start

        // L=me, R=remote (Q1) — same rule as Player: gain only applies to stereo.
        let channelGains = channels == 2 ? [Float(gains.me), Float(gains.remote)] : [Float](repeating: 1, count: channels)
        let writer = try WAVWriter(url: wavURL, channels: UInt16(channels))
        let chunkFrames: AVAudioFrameCount = 16000 * 10
        guard let buffer = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: chunkFrames)
        else { throw MP3ExporterError.noAudio }

        var remaining = end - start
        while remaining > 0 {
            try source.read(into: buffer, frameCount: AVAudioFrameCount(min(remaining, AVAudioFramePosition(chunkFrames))))
            let frames = Int(buffer.frameLength)
            guard frames > 0, let data = buffer.floatChannelData else { throw MP3ExporterError.incompleteAudio }
            var interleaved = [Int16](repeating: 0, count: frames * channels)
            for frame in 0 ..< frames {
                for channel in 0 ..< channels {
                    let sample = max(-1, min(1, data[channel][frame] * channelGains[channel]))
                    interleaved[frame * channels + channel] = Int16(sample * Float(Int16.max))
                }
            }
            try writer.append(interleaved)
            remaining -= AVAudioFramePosition(frames)
        }
        try writer.finish()
    }
}
