import Accelerate
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
enum Transcriber {
    /// Q4: the saved gain is applied both at playback (Player.swift) and
    /// here at STT time — a track recorded too quiet should get a real shot
    /// at being recognized, not just sound louder on replay.
    static func transcribe(sessionDirectory: URL, locale localeID: String,
                            meGain: Double = 1.0, remoteGain: Double = 1.0,
                            onProgress: ((String) -> Void)? = nil) async throws -> [TranscriptWord] {
        let wanted = Locale(identifier: localeID)
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: wanted) else {
            throw TranscriberError.unsupportedLocale(localeID)
        }

        // Not `.timeIndexedTranscriptionWithAlternatives` — despite the name,
        // that preset doesn't populate `.transcriptionConfidence` on result
        // runs (verified: every word came back with the exact same value,
        // which turned out to be this code's own `?? 1.0` fallback masking
        // a nil attribute). Requesting both attributes explicitly is what
        // Q13's low-confidence `?` marking needs.
        let attributes: Set<SpeechTranscriber.ResultAttributeOption> = [.audioTimeRange, .transcriptionConfidence]
        let meTranscriber = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                              reportingOptions: [], attributeOptions: attributes)
        let remoteTranscriber = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                                  reportingOptions: [], attributeOptions: attributes)

        try await ensureInstalled(modules: [meTranscriber, remoteTranscriber], onProgress: onProgress)

        guard let callURL = AudioCapture.audioFileURL(in: sessionDirectory) else {
            throw TranscriberError.unexpectedFileFormat
        }
        let (meChannel, remoteChannel) = try readStereoChannels(callURL)
        applyGain(Float(meGain), to: meChannel)
        applyGain(Float(remoteGain), to: remoteChannel)

        onProgress?("transcribing me track")
        let meWords = try await run(meTranscriber, buffer: meChannel, speaker: "M")
        onProgress?("transcribing remote track")
        let remoteWords = try await run(remoteTranscriber, buffer: remoteChannel, speaker: "R")

        let words = (meWords + remoteWords).sorted { $0.startMs < $1.startMs }
        let data = try JSONEncoder().encode(words)
        try data.write(to: sessionDirectory.appendingPathComponent("raw.json"))
        return words
    }

    private static func ensureInstalled(modules: [any SpeechModule], onProgress: ((String) -> Void)?) async throws {
        let status = await AssetInventory.status(forModules: modules)
        guard status != .installed else { return }
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: modules) else { return }
        onProgress?("downloading speech model (\(Int(request.progress.fractionCompleted * 100))%)")
        try await request.downloadAndInstall()
    }

    private static func applyGain(_ gain: Float, to buffer: AVAudioPCMBuffer) {
        guard gain != 1.0, let channel = buffer.floatChannelData?[0] else { return }
        var gain = gain
        vDSP_vsmul(channel, 1, &gain, channel, 1, vDSP_Length(buffer.frameLength))
    }

    /// `call.wav` is a stereo 16kHz Int16 file (L=me, R=remote). AVAudioFile
    /// decodes to its `processingFormat` (float32, non-interleaved) on read,
    /// so channels come back as separate pointers — no manual de-interleave.
    private static func readStereoChannels(_ url: URL) throws -> (me: AVAudioPCMBuffer, remote: AVAudioPCMBuffer) {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard format.channelCount == 2, let monoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate, channels: 1, interleaved: false
        ) else { throw TranscriberError.unexpectedFileFormat }

        let frameCount = AVAudioFrameCount(file.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              frameCount > 0 else { throw TranscriberError.unexpectedFileFormat }
        try file.read(into: buffer)
        guard let channelData = buffer.floatChannelData else { throw TranscriberError.unexpectedFileFormat }

        func mono(from source: UnsafeMutablePointer<Float>) throws -> AVAudioPCMBuffer {
            guard let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: frameCount)
            else { throw TranscriberError.unexpectedFileFormat }
            mono.frameLength = frameCount
            mono.floatChannelData![0].update(from: source, count: Int(frameCount))
            return mono
        }
        return (try mono(from: channelData[0]), try mono(from: channelData[1]))
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
