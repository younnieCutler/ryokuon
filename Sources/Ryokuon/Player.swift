import AVFoundation
import Accelerate
import Foundation

/// Plays `call.wav`/`call.flac` with independent me/remote gain (Q4: not a
/// live monitoring knob — a value chosen once, applied at playback and STT
/// time, original file never touched). Gain is baked into an in-memory copy
/// of the samples before scheduling playback, not a live mixer node — macOS
/// has no stock per-channel-of-a-stereo-file gain node, and this is a
/// personal-tool batch job, not a DAW.
@MainActor
final class Player {
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private(set) var isPlaying = false
    var onFinish: (() -> Void)?

    init() {
        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: nil)
    }

    func play(url: URL, meGain: Double, remoteGain: Double) throws {
        stop()

        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
        else { return }
        try file.read(into: buffer)
        applyGain(to: buffer, meGain: Float(meGain), remoteGain: Float(remoteGain))

        if !engine.isRunning { try engine.start() }
        isPlaying = true
        playerNode.scheduleBuffer(buffer) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.isPlaying = false
                self.onFinish?()
            }
        }
        playerNode.play()
    }

    func stop() {
        guard isPlaying || playerNode.isPlaying else { return }
        playerNode.stop()
        isPlaying = false
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
