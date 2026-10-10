import AVFoundation
import Accelerate
import CoreAudio
import Foundation
import AudioToolbox

enum PlayerError: Error { case noAudio, invalidPosition }

/// Bounded-memory playback: at most two five-second PCM buffers are queued.
/// Seeking repositions the file instead of copying the rest of a long meeting.
@MainActor
final class Player {
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var file: AVAudioFile?
    private var meGain: Float = 1
    private var remoteGain: Float = 1
    static let bufferSeconds: Double = 5
    private var loadedURL: URL?
    private var loadedStamp: AudioFileStamp?
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
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let stamp = AudioFileStamp(size: Int64(values.fileSize ?? 0), modifiedAt: values.contentModificationDate)

        if loadedURL != url || loadedStamp != stamp || file == nil {
            let source = try AVAudioFile(forReading: url)
            guard source.length > 0, source.processingFormat.sampleRate > 0 else { throw PlayerError.noAudio }
            file = source
            loadedURL = url
            loadedStamp = stamp
            duration = Double(source.length) / source.processingFormat.sampleRate
            engine.stop()
            engine.disconnectNodeOutput(playerNode)
            engine.connect(playerNode, to: engine.mainMixerNode, format: source.processingFormat)
        }
        guard let file else { throw PlayerError.noAudio }
        let position = max(0, from)
        guard position < duration, meGain.isFinite, remoteGain.isFinite,
              (0...4).contains(meGain), (0...4).contains(remoteGain) else { throw PlayerError.invalidPosition }
        file.framePosition = AVAudioFramePosition(position * file.processingFormat.sampleRate)
        self.meGain = Float(meGain)
        self.remoteGain = Float(remoteGain)
        startOffsetSeconds = position
        if !engine.isRunning { try engine.start() }
        isPlaying = true
        do {
            try scheduleNextBuffer()
            try scheduleNextBuffer()
            playerNode.play()
        } catch {
            stop()
            throw error
        }
    }

    private func scheduleNextBuffer() throws {
        guard let file, file.framePosition < file.length else { return }
        let frames = AVAudioFrameCount(min(file.length - file.framePosition,
            AVAudioFramePosition(file.processingFormat.sampleRate * Self.bufferSeconds)))
        guard let chunk = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else {
            throw PlayerError.noAudio
        }
        try file.read(into: chunk, frameCount: frames)
        guard chunk.frameLength > 0 else { throw PlayerError.noAudio }
        applyGain(to: chunk, meGain: meGain, remoteGain: remoteGain)
        let last = file.framePosition >= file.length
        let thisGeneration = generation
        playerNode.scheduleBuffer(chunk, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == thisGeneration, self.isPlaying else { return }
                if last {
                    self.isPlaying = false
                    self.onFinish?()
                } else {
                    do { try self.scheduleNextBuffer() }
                    catch { self.stop(); self.onError?(error) }
                }
            }
        }
    }

    var onError: ((Error) -> Void)?

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
        generation += 1
        playerNode.stop()
        isPlaying = false
    }

    /// A file can be replaced at the same path in Finder. The next play must
    /// read its new bytes rather than reuse the previously decoded buffer.
    func invalidateCachedAudio() {
        stop()
        file = nil
        loadedURL = nil
        loadedStamp = nil
        duration = 0
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
