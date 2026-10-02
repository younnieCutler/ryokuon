import AVFoundation
import Foundation

/// Peak envelope for the export sheet's range editor — one value per
/// bucket, the loudest sample across all channels, normalized so the
/// loudest bucket is 1 (a quiet call would otherwise draw as a flat line).
enum Waveform {
    static func peaks(of url: URL, buckets: Int) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard file.length > 0, buckets > 0 else { return [] }
        let framesPerBucket = max(1, Int(file.length) / buckets)
        let chunkFrames: AVAudioFrameCount = 16000 * 10
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunkFrames)
        else { return [] }

        var peaks = [Float](repeating: 0, count: buckets)
        var frameIndex = 0
        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: chunkFrames)
            guard buffer.frameLength > 0, let data = buffer.floatChannelData else { break }
            for frame in 0 ..< Int(buffer.frameLength) {
                let bucket = min(frameIndex / framesPerBucket, buckets - 1)
                for channel in 0 ..< Int(buffer.format.channelCount) {
                    peaks[bucket] = max(peaks[bucket], abs(data[channel][frame]))
                }
                frameIndex += 1
            }
        }
        let loudest = peaks.max() ?? 0
        return loudest > 0 ? peaks.map { $0 / loudest } : peaks
    }
}
