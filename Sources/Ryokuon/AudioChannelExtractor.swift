import AVFoundation
import Foundation

/// Streams one channel into a temporary lossless file for SpeechAnalyzer's
/// file input API. No full-meeting PCM arrays or eagerly buffered AsyncStreams.
enum AudioChannelExtractor {
    static func write(from sourceURL: URL, channel: Int, gain: Double, to destination: URL) throws {
        let source = try AVAudioFile(forReading: sourceURL)
        let format = source.processingFormat
        guard source.length > 0, channel >= 0, channel < Int(format.channelCount),
              gain.isFinite, (0...4).contains(gain),
              let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                  sampleRate: format.sampleRate, channels: 1, interleaved: false)
        else { throw TranscriberError.unexpectedFileFormat }
        let capacity = AVAudioFrameCount(format.sampleRate * 10)
        guard let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity),
              let output = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: capacity)
        else { throw TranscriberError.noCompatibleAudioFormat }
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatFLAC,
            AVSampleRateKey: format.sampleRate, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16]
        let destinationFile = try AVAudioFile(forWriting: destination, settings: settings,
                                             commonFormat: .pcmFormatFloat32, interleaved: false)
        while source.framePosition < source.length {
            try Task.checkCancellation()
            try source.read(into: input, frameCount: capacity)
            guard input.frameLength > 0, let samples = input.floatChannelData?[channel],
                  let mono = output.floatChannelData?[0] else { throw TranscriberError.unexpectedFileFormat }
            output.frameLength = input.frameLength
            for frame in 0..<Int(input.frameLength) { mono[frame] = max(-1, min(1, samples[frame] * Float(gain))) }
            try destinationFile.write(from: output)
        }
    }
}
