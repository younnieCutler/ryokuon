import AVFoundation
import Accelerate
import CoreAudio
import Foundation
import AudioToolbox

enum PlayerError: Error { case noAudio, invalidPosition }

/// Keeps at most a few two-second decoded chunks in flight, including for
/// long meetings. Seeking opens a file reader at the selected frame; it does
/// not decode or copy the rest of the recording into memory.
@MainActor
final class Player {
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var source: AVAudioFile?
    private var connectedFormat: AVAudioFormat?
    private var startOffsetSeconds: TimeInterval = 0
    private var generation = 0
    private var meGain: Float = 1
    private var remoteGain: Float = 1

    private(set) var isPlaying = false
    private(set) var duration: TimeInterval = 0
    var onFinish: (() -> Void)?
    var onError: ((Error) -> Void)?
    var outputDeviceUID: String?
    private var appliedOutputDeviceID: AudioDeviceID?

    init() { engine.attach(playerNode) }

    func play(url: URL, from: TimeInterval = 0, meGain: Double, remoteGain: Double) throws {
        stop()
        guard from.isFinite, meGain.isFinite, remoteGain.isFinite,
              abs(meGain) <= Double(Float.greatestFiniteMagnitude),
              abs(remoteGain) <= Double(Float.greatestFiniteMagnitude)
        else { throw PlayerError.invalidPosition }
        try applyOutputDeviceIfNeeded()
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard file.length > 0, format.sampleRate > 0,
              format.sampleRate * 2 < Double(UInt32.max) else { throw PlayerError.noAudio }
        duration = Double(file.length) / format.sampleRate
        let position = max(0, from)
        guard position < duration else { throw PlayerError.invalidPosition }
        file.framePosition = AVAudioFramePosition(position * format.sampleRate)
        if connectedFormat != format {
            engine.stop()
            engine.disconnectNodeOutput(playerNode)
            engine.connect(playerNode, to: engine.mainMixerNode, format: format)
            connectedFormat = format
        }
        source = file
        self.meGain = Float(meGain)
        self.remoteGain = Float(remoteGain)
        startOffsetSeconds = position
        generation += 1
        isPlaying = true
        do {
            if !engine.isRunning { try engine.start() }
            // Two chunks of runway allow disk reads to stay ahead of rendering.
            try scheduleNextChunk()
            try scheduleNextChunk()
            playerNode.play()
        } catch {
            stop()
            throw error
        }
    }

    private func scheduleNextChunk() throws {
        guard isPlaying, let source, source.framePosition < source.length else { return }
        let capacity = AVAudioFrameCount(min(source.length - source.framePosition,
                                             AVAudioFramePosition(source.processingFormat.sampleRate * 2)))
        guard let chunk = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: capacity)
        else { throw PlayerError.noAudio }
        try source.read(into: chunk, frameCount: capacity)
        guard chunk.frameLength > 0 else { throw PlayerError.noAudio }
        applyGain(to: chunk, meGain: meGain, remoteGain: remoteGain)
        let isLast = source.framePosition >= source.length
        let thisGeneration = generation
        playerNode.scheduleBuffer(chunk, completionCallbackType: isLast ? .dataPlayedBack : .dataConsumed) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == thisGeneration, self.isPlaying else { return }
                if isLast {
                    self.isPlaying = false
                    self.source = nil
                    self.startOffsetSeconds = self.duration
                    self.onFinish?()
                } else {
                    do { try self.scheduleNextChunk() }
                    catch { self.stop(); self.onError?(error) }
                }
            }
        }
    }

    var currentTime: TimeInterval {
        guard isPlaying, let nodeTime = playerNode.lastRenderTime,
              let playerTime = playerNode.playerTime(forNodeTime: nodeTime)
        else { return startOffsetSeconds }
        return min(duration, startOffsetSeconds + Double(playerTime.sampleTime) / playerTime.sampleRate)
    }

    func stop() {
        generation += 1
        playerNode.stop()
        isPlaying = false
        source = nil
    }

    func invalidateCachedAudio() {
        stop()
        duration = 0
    }

    private func applyOutputDeviceIfNeeded() throws {
        // Resolve the default every time: returning from a manually selected
        // device to nil must actually reset the audio unit, not just its label.
        var resolvedID = outputDeviceUID.flatMap(deviceID(forUID:))
            ?? caReadValue(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice,
                           default: AudioDeviceID(kAudioObjectUnknown))
        guard resolvedID != kAudioObjectUnknown else { throw PlayerError.noAudio }
        guard resolvedID != appliedOutputDeviceID else { return }
        engine.stop()
        guard let audioUnit = engine.outputNode.audioUnit else { throw PlayerError.noAudio }
        let status = AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                          &resolvedID, UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else { throw CoreAudioError.status("set playback output device", status) }
        appliedOutputDeviceID = resolvedID
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
