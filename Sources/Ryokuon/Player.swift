import AVFoundation
import Accelerate
import CoreAudio
import Foundation
import AudioToolbox

enum PlayerError: Error { case noAudio, invalidPosition }

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
    /// Bumped on every play/stop. `playerNode.stop()` fires the *previous*
    /// segment's completion handler, which lands after a seek has already
    /// started the next segment — without this check it marked playback as
    /// finished mid-play (reproduced: seek -> position frozen, isPlaying
    /// false, onFinish fired while audio kept going).
    private var generation = 0

    private(set) var isPlaying = false
    private(set) var duration: TimeInterval = 0
    var onFinish: (() -> Void)?

    /// Playback output device UID — nil means the system default output.
    /// Applied lazily in `play(url:...)`, only when it actually changed,
    /// since reconfiguring the output unit requires the engine to be
    /// stopped first.
    var outputDeviceUID: String?
    private var appliedOutputDeviceID: AudioDeviceID?

    init() {
        engine.attach(playerNode)
        // No connect() here — see the comment in `play(url:)` on why the
        // connection format has to come from the actual file, not this
        // default.
    }

    func play(url: URL, from: TimeInterval = 0, meGain: Double, remoteGain: Double) throws {
        stop()
        try applyOutputDeviceIfNeeded()
        guard from.isFinite else { throw PlayerError.invalidPosition }

        if loadedURL != url || buffer == nil {
            let file = try AVAudioFile(forReading: url)
            let format = file.processingFormat
            guard file.length > 0, file.length <= Int64(UInt32.max) else { throw PlayerError.noAudio }
            let frameCount = AVAudioFrameCount(file.length)
            guard frameCount > 0, let full = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
            else { throw PlayerError.noAudio }
            try file.read(into: full)
            buffer = full
            loadedURL = url
            duration = Double(frameCount) / format.sampleRate

            // `engine.connect(_:to:format:)` with `format: nil` derives the
            // connection's sample rate from the player node's own output
            // format at connect time — for a freshly attached node with
            // nothing scheduled yet, that's the engine's default processing
            // rate (the hardware output rate, e.g. 44.1/48kHz), not this
            // file's 16kHz. Scheduling a 16kHz buffer over a connection
            // declared at a higher rate plays it back too fast instead of
            // being resampled — audible as a pitched-up, chipmunked voice.
            // Confirmed by ear during this session (this bug predates the
            // GUI redesign; step 5 never actually listened to a playback,
            // only checked file existence/format).
            //
            // Fix: reconnect using the real file's format every time a new
            // file loads. The engine still resamples transparently at the
            // mixer -> hardware-output stage, so this doesn't lose fidelity
            // — it just tells the engine the true input rate.
            engine.stop()
            engine.disconnectNodeOutput(playerNode)
            engine.connect(playerNode, to: engine.mainMixerNode, format: format)
        }
        guard let buffer else { throw PlayerError.noAudio }

        let sampleRate = buffer.format.sampleRate
        let position = max(0, from)
        guard position < Double(buffer.frameLength) / sampleRate else { throw PlayerError.invalidPosition }
        let startFrame = AVAudioFramePosition(position * sampleRate)
        let length = AVAudioFrameCount(AVAudioFramePosition(buffer.frameLength) - startFrame)
        guard let segment = slice(buffer, from: AVAudioFrameCount(startFrame), length: length) else { throw PlayerError.noAudio }
        applyGain(to: segment, meGain: Float(meGain), remoteGain: Float(remoteGain))

        if !engine.isRunning { try engine.start() }
        startOffsetSeconds = position
        isPlaying = true
        generation += 1
        let thisGeneration = generation
        // .dataPlayedBack: fire when the audio has actually been heard, not
        // when the last frames were handed to the renderer (that ended the
        // position bar slightly early).
        playerNode.scheduleBuffer(segment, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == thisGeneration else { return }
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
        generation += 1
        playerNode.stop()
        isPlaying = false
    }

    /// Sets the output unit's `kAudioOutputUnitProperty_CurrentDevice` to
    /// `outputDeviceUID`'s resolved device, or leaves the system default in
    /// place if unset/unresolvable. The output unit only accepts this while
    /// stopped, so this always runs before `engine.start()`.
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
