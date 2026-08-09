import AVFoundation
import Accelerate
import Foundation

/// Plays `call.wav`/`call.flac` with independent me/remote gain (Q4: not a
/// live monitoring knob — a value chosen once, applied at playback and STT
/// time, original file never touched). Gain is baked into an in-memory
/// segment before scheduling playback, not a live mixer node — macOS has no
/// stock per-channel-of-a-stereo-file gain node, and this is a personal-tool
/// batch job, not a DAW.
///
/// Supports seeking (`play(url:from:...)`) so the main window can jump
/// playback to a transcript line's timestamp and keep a position readout in
/// sync — the raw file buffer is read once per URL and cached, so seeking
/// within the same session doesn't re-read from disk.
@MainActor
final class Player {
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var buffer: AVAudioPCMBuffer?
    private var loadedURL: URL?
    private var startOffsetSeconds: TimeInterval = 0

    private(set) var isPlaying = false
    private(set) var duration: TimeInterval = 0
    var onFinish: (() -> Void)?

    init() {
        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: nil)
    }

    func play(url: URL, from: TimeInterval = 0, meGain: Double, remoteGain: Double) throws {
        stop()

        if loadedURL != url || buffer == nil {
            let file = try AVAudioFile(forReading: url)
            let format = file.processingFormat
            let frameCount = AVAudioFrameCount(file.length)
            guard frameCount > 0, let full = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
            else { return }
            try file.read(into: full)
            buffer = full
            loadedURL = url
            duration = Double(frameCount) / format.sampleRate
        }
        guard let buffer else { return }

        let sampleRate = buffer.format.sampleRate
        let startFrame = AVAudioFramePosition(max(0, from) * sampleRate)
        guard startFrame < AVAudioFramePosition(buffer.frameLength) else { return }
        let length = AVAudioFrameCount(AVAudioFramePosition(buffer.frameLength) - startFrame)
        guard let segment = slice(buffer, from: AVAudioFrameCount(startFrame), length: length) else { return }
        applyGain(to: segment, meGain: Float(meGain), remoteGain: Float(remoteGain))

        if !engine.isRunning { try engine.start() }
        startOffsetSeconds = from
        isPlaying = true
        playerNode.scheduleBuffer(segment) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.isPlaying = false
                self.onFinish?()
            }
        }
        playerNode.play()
    }

    /// Current position within the file, in seconds — `startOffsetSeconds`
    /// (where this scheduled segment began) plus however far the node has
    /// actually played into it.
    var currentTime: TimeInterval {
        guard isPlaying, let nodeTime = playerNode.lastRenderTime,
              let playerTime = playerNode.playerTime(forNodeTime: nodeTime)
        else { return startOffsetSeconds }
        return startOffsetSeconds + Double(playerTime.sampleTime) / playerTime.sampleRate
    }

    func stop() {
        guard isPlaying || playerNode.isPlaying else { return }
        playerNode.stop()
        isPlaying = false
    }

    /// Copies frames `[from, from+length)` into a fresh buffer via raw
    /// `AudioBufferList` bytes — same approach as `Transcriber.slice`, safe
    /// regardless of the buffer's exact PCM subformat.
    private func slice(_ buffer: AVAudioPCMBuffer, from offset: AVAudioFrameCount,
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

    /// L=me, R=remote (Q1 stereo layout). Silently no-ops on anything else
    /// — this is only ever called with `call.wav`/`call.flac`.
    private func applyGain(to buffer: AVAudioPCMBuffer, meGain: Float, remoteGain: Float) {
        guard let channels = buffer.floatChannelData, buffer.format.channelCount == 2 else { return }
        var me = meGain
        var remote = remoteGain
        let frameLength = vDSP_Length(buffer.frameLength)
        vDSP_vsmul(channels[0], 1, &me, channels[0], 1, frameLength)
        vDSP_vsmul(channels[1], 1, &remote, channels[1], 1, frameLength)
    }
}
