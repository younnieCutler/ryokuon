import AVFoundation
import Foundation

/// Demand-driven, bounded audio input. One AsyncSequence iterator owns this
/// reader; neither the file nor its converter is shared with another consumer.
final class TranscriptionAudioReader: @unchecked Sendable {
    private let file: AVAudioFile
    private let channel: Int
    private let gain: Float
    private let monoFormat: AVAudioFormat
    private let targetFormat: AVAudioFormat
    private let converter: AVAudioConverter?
    private let chunkFrames: AVAudioFrameCount
    private var didFlush = false

    init(url: URL, channel: Int, gain: Double, targetFormat: AVAudioFormat, chunkSeconds: Double = 2) throws {
        let source = try AVAudioFile(forReading: url)
        let format = source.processingFormat
        guard channel >= 0, channel < Int(format.channelCount), gain.isFinite,
              abs(gain) <= Double(Float.greatestFiniteMagnitude), chunkSeconds > 0, chunkSeconds <= 30,
              format.sampleRate.isFinite, format.sampleRate > 0,
              format.sampleRate * chunkSeconds < Double(UInt32.max),
              let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate,
                                       channels: 1, interleaved: false)
        else { throw TranscriberError.unexpectedFileFormat }
        let selectedConverter = mono == targetFormat ? nil : AVAudioConverter(from: mono, to: targetFormat)
        guard mono == targetFormat || selectedConverter != nil else { throw TranscriberError.noCompatibleAudioFormat }
        selectedConverter?.primeMethod = .none
        file = source
        self.channel = channel
        self.gain = Float(gain)
        monoFormat = mono
        self.targetFormat = targetFormat
        converter = selectedConverter
        chunkFrames = AVAudioFrameCount(format.sampleRate * chunkSeconds)
    }

    func next() throws -> AVAudioPCMBuffer? {
        guard file.framePosition < file.length else {
            guard let converter, !didFlush else { return nil }
            didFlush = true
            guard let tail = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: 512)
            else { throw TranscriberError.noCompatibleAudioFormat }
            var failure: NSError?
            converter.convert(to: tail, error: &failure) { _, status in
                status.pointee = .endOfStream
                return nil
            }
            if let failure { throw failure }
            return tail.frameLength > 0 ? tail : nil
        }
        guard let source = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunkFrames),
              let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: chunkFrames)
        else { throw TranscriberError.unexpectedFileFormat }
        try file.read(into: source, frameCount: chunkFrames)
        guard source.frameLength > 0, let channels = source.floatChannelData,
              let output = mono.floatChannelData?[0] else { throw TranscriberError.unexpectedFileFormat }
        mono.frameLength = source.frameLength
        for frame in 0..<Int(source.frameLength) { output[frame] = channels[channel][frame] * gain }
        guard let converter else { return mono }
        let capacity = AVAudioFrameCount(ceil(Double(mono.frameLength) * targetFormat.sampleRate / monoFormat.sampleRate)) + 64
        guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity)
        else { throw TranscriberError.noCompatibleAudioFormat }
        let input = TranscriptionInputBox(mono)
        var failure: NSError?
        converter.convert(to: converted, error: &failure) { _, status in
            guard let buffer = input.take() else { status.pointee = .noDataNow; return nil }
            status.pointee = .haveData
            return buffer
        }
        if let failure { throw failure }
        guard converted.frameLength > 0 else { throw TranscriberError.noCompatibleAudioFormat }
        return converted
    }
}

private final class TranscriptionInputBox: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?
    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
    func take() -> AVAudioPCMBuffer? {
        defer { buffer = nil }
        return buffer
    }
}
