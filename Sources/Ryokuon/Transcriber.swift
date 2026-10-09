import AVFoundation
import Foundation
import Speech

/// Word-level transcript output for one channel. `raw.json` (step 4 input)
/// is just `[TranscriptWord]` sorted by `startMs` across both speakers —
/// TranscriptBuilder merges same-speaker runs into utterances from this.
struct TranscriptWord: Codable {
    let speaker: String // "M" or "R"
    let text: String
    let startMs: Int
    let durationMs: Int
    let confidence: Double
}

enum TranscriberError: Error {
    case unsupportedLocale(String)
    case noCompatibleAudioFormat
    case unexpectedFileFormat
}

/// Runs Apple's on-device SpeechTranscriber over `call.wav`'s two channels
/// (L=me, R=remote — Q1 stereo layout) and writes word-level results to
/// `raw.json`. Sequential, not concurrent (plan priority 4: low CPU — two
/// SpeechAnalyzer instances competing for the ANE at once is wasteful for a
/// batch job with no latency requirement).
///
/// 2026-08-13: mono sessions (no headset at record time — see AudioCapture's
/// downmix) skip the M/R split entirely and produce one unified transcript
/// tagged `speaker: "U"` — the ME/REMOTE tracks were never separate to begin
/// with, so there's nothing to diarize.
enum Transcriber {
    /// Stored as a session/setting language meaning "detect before transcribing".
    static let autoLanguage = "auto"
    /// What auto-detection chooses between — the three locales Q7 verified.
    static let candidateLocales = ["ja-JP", "ko-KR", "en-US"]

    /// SpeechTranscriber has no language auto-detection (one locale per
    /// instance). Workaround, measured on real ja/ko/en recordings: run a
    /// 30s probe through each candidate and keep the one with the highest
    /// summed word confidence — the wrong locale returns zero or few,
    /// low-confidence words (ja audio: ja 55 words @0.90 vs ko 0 vs en 6
    /// @0.21; en audio: en 13 @0.98 vs ko 13 @0.79 vs ja 14 @0.73).
    // ponytail: one language per recording; per-utterance detection if mixed-language calls matter
    static func detectLanguage(sessionDirectory: URL,
                               onProgress: (@Sendable (String) -> Void)? = nil) async throws -> String {
        guard let callURL = AudioCapture.audioFileURL(in: sessionDirectory) else {
            throw TranscriberError.unexpectedFileFormat
        }
        let probe = try readProbe(callURL, seconds: 30)
        var best = (id: candidateLocales[0], score: -1.0)
        for id in candidateLocales {
            guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: id))
            else { continue }
            let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                                reportingOptions: [], attributeOptions: attributes)
            try await ensureInstalled(modules: [transcriber], onProgress: onProgress)
            onProgress?("detecting language")
            let score = try await run(transcriber, buffer: probe, speaker: "U").map(\.confidence).reduce(0, +)
            if score > best.score { best = (id, score) }
        }
        return best.id
    }

    /// Not `.timeIndexedTranscriptionWithAlternatives` — despite the name,
    /// that preset doesn't populate `.transcriptionConfidence` on result
    /// runs (verified: every word came back with the exact same value,
    /// which turned out to be this code's own `?? 1.0` fallback masking
    /// a nil attribute). Requesting both attributes explicitly is what
    /// Q13's low-confidence `?` marking (and language detection) needs.
    private static let attributes: Set<SpeechTranscriber.ResultAttributeOption> = [.audioTimeRange, .transcriptionConfidence]

    /// Q4: the saved gain is applied both at playback (Player.swift) and
    /// here at STT time — a track recorded too quiet should get a real shot
    /// at being recognized, not just sound louder on replay.
    static func transcribe(sessionDirectory: URL, locale localeID: String,
                            meGain: Double = 1.0, remoteGain: Double = 1.0,
                            onProgress: (@Sendable (String) -> Void)? = nil) async throws -> [TranscriptWord] {
        let wanted = Locale(identifier: localeID)
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: wanted) else {
            throw TranscriberError.unsupportedLocale(localeID)
        }

        guard let callURL = AudioCapture.audioFileURL(in: sessionDirectory) else {
            throw TranscriberError.unexpectedFileFormat
        }
        let channelCount = try AVAudioFile(forReading: callURL).processingFormat.channelCount

        let words: [TranscriptWord]
        if channelCount == 1 {
            let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                                reportingOptions: [], attributeOptions: attributes)
            try await ensureInstalled(modules: [transcriber], onProgress: onProgress)

            onProgress?("transcribing")
            words = try await run(transcriber, fileURL: callURL, channel: 0, gain: 1, speaker: "U")
        } else {
            let meTranscriber = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                                  reportingOptions: [], attributeOptions: attributes)
            let remoteTranscriber = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                                      reportingOptions: [], attributeOptions: attributes)
            try await ensureInstalled(modules: [meTranscriber, remoteTranscriber], onProgress: onProgress)

            onProgress?("transcribing me track")
            let meWords = try await run(meTranscriber, fileURL: callURL, channel: 0, gain: meGain, speaker: "M")
            onProgress?("transcribing remote track")
            let remoteWords = try await run(remoteTranscriber, fileURL: callURL, channel: 1, gain: remoteGain, speaker: "R")
            words = (meWords + remoteWords).sorted { $0.startMs < $1.startMs }
        }

        let data = try JSONEncoder().encode(words)
        try data.write(to: sessionDirectory.appendingPathComponent("raw.json"), options: .atomic)
        return words
    }

    private static func ensureInstalled(modules: [any SpeechModule], onProgress: (@Sendable (String) -> Void)?) async throws {
        let status = await AssetInventory.status(forModules: modules)
        guard status != .installed else { return }
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: modules) else { return }
        onProgress?("downloading speech model (\(Int(request.progress.fractionCompleted * 100))%)")
        try await request.downloadAndInstall()
    }

    /// Up to `seconds` from the middle of the recording, all channels mixed
    /// to mono — the middle skips ring-tone/greeting silence at the start.
    private static func readProbe(_ url: URL, seconds: Double) throws -> AVAudioPCMBuffer {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let wanted = AVAudioFramePosition(seconds * format.sampleRate)
        let length = min(wanted, file.length)
        guard length > 0,
              let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate,
                                             channels: 1, interleaved: false),
              let source = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(length)),
              let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: AVAudioFrameCount(length))
        else { throw TranscriberError.unexpectedFileFormat }
        file.framePosition = (file.length - length) / 2
        try file.read(into: source, frameCount: AVAudioFrameCount(length))
        guard let input = source.floatChannelData, let output = mono.floatChannelData?[0]
        else { throw TranscriberError.unexpectedFileFormat }
        let channels = Int(format.channelCount)
        mono.frameLength = source.frameLength
        for frame in 0 ..< Int(source.frameLength) {
            var sum: Float = 0
            for channel in 0 ..< channels { sum += input[channel][frame] }
            output[frame] = sum / Float(channels)
        }
        return mono
    }

    private static func run(_ transcriber: SpeechTranscriber, fileURL: URL, channel: Int,
                            gain: Double, speaker: String) async throws -> [TranscriptWord] {
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        else { throw TranscriberError.noCompatibleAudioFormat }
        let reader = try TranscriptionAudioReader(url: fileURL, channel: channel, gain: gain, targetFormat: format)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let collector = Task {
            var words: [TranscriptWord] = []
            for try await result in transcriber.results {
                words.append(contentsOf: extractWords(result, speaker: speaker))
            }
            return words
        }
        defer { collector.cancel() }
        let stream = AsyncThrowingStream<AnalyzerInput, Error>(unfolding: {
            try Task.checkCancellation()
            return try reader.next().map { AnalyzerInput(buffer: $0) }
        })
        _ = try await analyzer.analyzeSequence(stream)
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        return try await collector.value
    }

    private static func run(_ transcriber: SpeechTranscriber, buffer: AVAudioPCMBuffer,
                             speaker: String) async throws -> [TranscriptWord] {
        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        else { throw TranscriberError.noCompatibleAudioFormat }
        let converted = try convert(buffer, to: analyzerFormat)

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let collector = Task {
            var words: [TranscriptWord] = []
            for try await result in transcriber.results {
                words.append(contentsOf: extractWords(result, speaker: speaker))
            }
            return words
        }
        defer { collector.cancel() }

        // 2s chunks: keeps this close to how the analyzer is meant to be
        // fed (a stream, not one giant buffer) without adding real
        // complexity — still one straight-line loop, no reason to feed the
        // whole buffer in a single AnalyzerInput.
        let chunkFrames = AVAudioFrameCount(analyzerFormat.sampleRate * 2)
        let stream = AsyncStream<AnalyzerInput> { continuation in
            var offset: AVAudioFrameCount = 0
            while offset < converted.frameLength {
                let length = min(chunkFrames, converted.frameLength - offset)
                if let chunk = slice(converted, from: offset, length: length) {
                    continuation.yield(AnalyzerInput(buffer: chunk))
                }
                offset += length
            }
            continuation.finish()
        }

        _ = try await analyzer.analyzeSequence(stream)
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        return try await collector.value
    }

    private static func extractWords(_ result: SpeechTranscriber.Result, speaker: String) -> [TranscriptWord] {
        var words: [TranscriptWord] = []
        for run in result.text.runs {
            let text = String(result.text[run.range].characters)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            guard let timeRange = run.audioTimeRange else { continue }
            let confidence = run.transcriptionConfidence ?? 1.0
            words.append(TranscriptWord(
                speaker: speaker, text: text,
                startMs: Int(timeRange.start.seconds * 1000),
                durationMs: Int(timeRange.duration.seconds * 1000),
                confidence: confidence
            ))
        }
        return words
    }

    /// `bestAvailableAudioFormat` isn't guaranteed to be float32 (it wasn't
    /// in practice — `floatChannelData` came back nil), so this can't index
    /// through `floatChannelData` like `readStereoChannels` does. Copying
    /// raw bytes off the `AudioBufferList` works for any PCM format,
    /// interleaved or not.
    private static func slice(_ buffer: AVAudioPCMBuffer, from offset: AVAudioFrameCount,
                               length: AVAudioFrameCount) -> AVAudioPCMBuffer? {
        guard length > 0, let out = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: length)
        else { return nil }
        out.frameLength = length
        let bytesPerFrame = Int(buffer.format.streamDescription.pointee.mBytesPerFrame)
        let srcList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
        let dstList = UnsafeMutableAudioBufferListPointer(out.mutableAudioBufferList)
        for (src, dst) in zip(srcList, dstList) {
            guard let srcData = src.mData, let dstData = dst.mData else { continue }
            memcpy(dstData, srcData.advanced(by: Int(offset) * bytesPerFrame), Int(length) * bytesPerFrame)
        }
        return out
    }

    private static func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        guard buffer.format != format else { return buffer }
        guard let converter = AVAudioConverter(from: buffer.format, to: format)
        else { throw TranscriberError.noCompatibleAudioFormat }

        let ratio = format.sampleRate / buffer.format.sampleRate
        let outCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: outCapacity)
        else { throw TranscriberError.noCompatibleAudioFormat }

        let box = ConsumeOnceBox(buffer)
        var conversionError: NSError?
        converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            guard let buffer = box.take() else { outStatus.pointee = .noDataNow; return nil }
            outStatus.pointee = .haveData
            return buffer
        }
        if let conversionError { throw conversionError }
        return outputBuffer
    }
}

/// Same role as AudioCapture's private one: gives AVAudioConverter's
/// `@Sendable` input closure a Sendable box around a non-Sendable buffer
/// that's only ever consumed once, synchronously, on the calling thread.
private final class ConsumeOnceBox: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?
    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
    func take() -> AVAudioPCMBuffer? {
        defer { buffer = nil }
        return buffer
    }
}
