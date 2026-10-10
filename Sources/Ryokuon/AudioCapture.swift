import Accelerate
import AVFoundation
import CoreAudio
import Foundation

/// AVAudioConverter's input closure is `@Sendable`, but it always runs
/// synchronously on the calling thread during a single `convert(to:...)`
/// call — this box just gives the compiler a `Sendable` type to capture
/// instead of a mutable `Bool` + non-Sendable `AVAudioPCMBuffer`.
private final class ConsumeOnceBox: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?
    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
    func take() -> AVAudioPCMBuffer? {
        defer { buffer = nil }
        return buffer
    }
}

/// Captures mic + one app's audio into a single 16kHz WAV file — normally
/// stereo (left = me, right = remote; user decision 2026-08-09: one file to
/// manage instead of two), but mono when no headset is in use (2026-08-13:
/// without one the mic just picks up the remote channel's acoustic echo, so
/// ME/REMOTE separation is downmixed away instead of storing a fake stereo
/// split). STT in step 3 reads the two channels independently when stereo;
/// mono sessions get a single unified transcript instead.
///
/// Pipeline: IOProc (real-time, copy-only) → RingBuffer per track → a serial
/// queue drains every 200ms, resamples each track with its own
/// AVAudioConverter, interleaves L/R, and appends to one WAVWriter. Nothing
/// that can allocate, lock for long, or hit disk runs on the audio thread —
/// see RingBuffer's doc comment for why.
final class AudioCapture {
    private let device: CaptureDevice
    private var procID: AudioDeviceIOProcID?
    private let micRing: RingBuffer
    private let tapRing: RingBuffer
    /// `var`, not `let`: `switchMicDevice(uid:)` recomputes these against
    /// the new mic's channel count before recreating the IOProc.
    private var micRange: Range<Int>
    private var tapRange: Range<Int>
    private let drainQueue = DispatchQueue(label: "dev.ryokuon.capture.writer")
    private var drainTimer: DispatchSourceTimer?

    private let writer: WAVWriter
    /// True when recording mono (no headset — see CaptureDevice.isBuiltInMicActive).
    private let isMono: Bool
    /// `var`, not `let`: `switchMicDevice(uid:)` rebuilds all three when the
    /// new mic's native rate differs from the old one's — the aggregate's
    /// rate follows its mic sub-device (see `CaptureDevice`'s doc comment),
    /// so a mic switch can change the rate `convert()` needs to assume.
    /// Only ever mutated from `drainQueue` (see `switchMicDevice`) since
    /// `convert()` reads them from that same queue.
    private var sourceFormat: AVAudioFormat
    private let targetFormat: AVAudioFormat
    private var meConverter: AVAudioConverter
    private var remoteConverter: AVAudioConverter

    /// dB level per track, reported after each drain cycle (~5x/sec). Cheap
    /// byproduct of the resample step — step 2's level meter and silence
    /// warning (Q18) subscribe to this.
    var onError: ((Error) -> Void)?
    private var writeError: Error? // accessed only by drainQueue

    var onLevel: ((_ meDB: Float, _ remoteDB: Float) -> Void)?

    var diagnostics: String {
        "mic=\(device.micChannels)ch tap=\(device.tapChannels)ch rate=\(device.sampleRate)Hz"
    }
    var framesWritten: Int { drainQueue.sync { writer.framesWritten } }
    static let fileName = "call.wav"
    static let flacFileName = "call.flac"

    /// call.wav until step 5's FLAC conversion runs post-transcription, then
    /// call.flac (the WAV is deleted once the FLAC is verified — Q3). Any
    /// code that needs to read the audio back (Transcriber, Player) should
    /// go through this instead of assuming which one exists.
    static func audioFileURL(in directory: URL) -> URL? {
        let wav = directory.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: wav.path) { return wav }
        let flac = directory.appendingPathComponent(flacFileName)
        if FileManager.default.fileExists(atPath: flac.path) { return flac }
        return nil
    }

    init(process: AudioProcess, outputDirectory: URL, channels: Int, micDeviceUID: String? = nil) throws {
        isMono = channels == 1
        device = try CaptureDevice(tapping: process, micDeviceUID: micDeviceUID)
        micRange = 0 ..< device.micChannels
        tapRange = device.micChannels ..< (device.micChannels + device.tapChannels)

        // 10 seconds of headroom per track at the device's native rate. The
        // drain timer empties this every 200ms, so this is purely a buffer
        // against scheduling hiccups, not steady-state storage.
        let ringCapacity = Int(device.sampleRate) * 10
        micRing = RingBuffer(capacity: ringCapacity)
        tapRing = RingBuffer(capacity: ringCapacity)

        sourceFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: device.sampleRate,
                                     channels: 1, interleaved: false)!
        targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Float64(WAVWriter.sampleRate),
                                     channels: 1, interleaved: true)!
        guard let meConverter = AVAudioConverter(from: sourceFormat, to: targetFormat),
              let remoteConverter = AVAudioConverter(from: sourceFormat, to: targetFormat)
        else { throw CoreAudioError.status("AVAudioConverter init", -1) }
        self.meConverter = meConverter
        self.remoteConverter = remoteConverter

        writer = try WAVWriter(url: outputDirectory.appendingPathComponent(Self.fileName),
                               channels: UInt16(channels))
    }

    func start() throws {
        try startIOProc()

        let timer = DispatchSource.makeTimerSource(queue: drainQueue)
        timer.schedule(deadline: .now() + .milliseconds(200), repeating: .milliseconds(200))
        timer.setEventHandler { [weak self] in self?.drainAndWrite() }
        timer.resume()
        drainTimer = timer
    }

    /// Creates and starts the IOProc against `device.aggregateID` — shared
    /// by `start()` and `switchMicDevice(uid:)`, which needs to recreate
    /// this against a freshly rebuilt aggregate without touching the drain
    /// timer or anything downstream of the rings.
    private func startIOProc() throws {
        let micRing = self.micRing
        let tapRing = self.tapRing
        let micRange = self.micRange
        let tapRange = self.tapRange

        var newProcID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&newProcID, device.aggregateID, nil) {
            _, inputData, _, _, _ in
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
            AudioTrackMixer.write(buffers, channels: micRange, into: micRing)
            AudioTrackMixer.write(buffers, channels: tapRange, into: tapRing)
        }
        guard status == noErr else { throw CoreAudioError.status("AudioDeviceCreateIOProcIDWithBlock", status) }
        procID = newProcID

        let startStatus = AudioDeviceStart(device.aggregateID, newProcID)
        guard startStatus == noErr else {
            if let newProcID { AudioDeviceDestroyIOProcID(device.aggregateID, newProcID) }
            procID = nil
            throw CoreAudioError.status("AudioDeviceStart", startStatus)
        }
    }

    /// Swaps the mic feeding this recording without stopping it — tears
    /// down the old IOProc/aggregate, rebuilds the aggregate around the new
    /// mic (`CaptureDevice.switchMic`), recomputes `micRange`/`tapRange`
    /// against its (possibly different) channel count, and starts a fresh
    /// IOProc. The tap (target app audio) and the WAV's mono/stereo layout
    /// are untouched — only which physical device fills the "mic" slot
    /// changes. There's a brief gap in both tracks while this runs (device
    /// teardown/rebuild isn't instant); callers should expect a fraction of
    /// a second of silence rather than a click or crash.
    func switchMicDevice(uid: String?) throws {
        if let procID {
            AudioDeviceStop(device.aggregateID, procID)
            AudioDeviceDestroyIOProcID(device.aggregateID, procID)
            self.procID = nil
        }
        // Drain old-rate samples before replacing their resamplers.
        drainQueue.sync { self.drainAndWrite() }
        let oldRate = device.sampleRate
        try device.switchMic(toUID: uid)
        micRange = 0 ..< device.micChannels
        tapRange = device.micChannels ..< (device.micChannels + device.tapChannels)

        // The new mic can bring a different native rate (e.g. built-in
        // 48kHz vs. AirPods 24kHz) — the aggregate's rate follows it, so
        // `convert()`'s input format has to follow too, or it resamples on
        // the wrong ratio and every sample after this point plays back
        // pitch-shifted. Rebuilt on `drainQueue` since that's the only
        // queue `convert()` ever runs on.
        if device.sampleRate != oldRate {
            guard let newSourceFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: device.sampleRate,
                                                       channels: 1, interleaved: false),
                  let newMeConverter = AVAudioConverter(from: newSourceFormat, to: targetFormat),
                  let newRemoteConverter = AVAudioConverter(from: newSourceFormat, to: targetFormat)
            else { throw CoreAudioError.status("AVAudioConverter init", -1) }
            drainQueue.sync {
                sourceFormat = newSourceFormat
                meConverter = newMeConverter
                remoteConverter = newRemoteConverter
            }
        }

        try startIOProc()
    }

    deinit {
        drainTimer?.cancel()
        if let procID {
            AudioDeviceStop(device.aggregateID, procID)
            AudioDeviceDestroyIOProcID(device.aggregateID, procID)
        }
    }

    func stop() throws {
        defer { device.stop() }
        drainTimer?.cancel()
        drainTimer = nil
        if let procID {
            AudioDeviceStop(device.aggregateID, procID)
            AudioDeviceDestroyIOProcID(device.aggregateID, procID)
        }
        procID = nil
        let failure = drainQueue.sync {
            self.drainAndWrite()
            return self.writeError
        }
        try writer.finish()
        if let failure { throw failure }
    }

    private func drainAndWrite() {
        guard writeError == nil else { return }
        var meSamples: [Float] = []
        var remoteSamples: [Float] = []
        micRing.drain(into: &meSamples)
        tapRing.drain(into: &remoteSamples)
        guard !meSamples.isEmpty || !remoteSamples.isEmpty else { return }

        do {
            let me = try convert(meSamples, using: meConverter)
            let remote = try convert(remoteSamples, using: remoteConverter)
            try writer.append(isMono ? downmix(me, remote) : interleave(left: me, right: remote))
        } catch {
            // Preserve the first failure: stop must not claim a complete file.
            if writeError == nil {
                writeError = error
                onError?(error)
            }
            FileHandle.standardError.write("ryokuon: write error: \(error)\n".data(using: .utf8)!)
        }

        onLevel?(decibels(of: meSamples), decibels(of: remoteSamples))
    }

    /// Both rings are fed the same frame count per IOProc call (one aggregate
    /// device, one callback) and drained together, so `left.count ==
    /// right.count` holds in practice — verified by step 1's exact frame
    /// match over a 3-minute recording. Still pads the shorter side with
    /// silence rather than trust that invariant blindly; a channel dropping
    /// out of sync would otherwise slowly shift L/R out of alignment.
    private func interleave(left: [Int16], right: [Int16]) -> [Int16] {
        let count = max(left.count, right.count)
        guard count > 0 else { return [] }
        var output = [Int16](repeating: 0, count: count * 2)
        for i in 0 ..< count {
            output[i * 2] = i < left.count ? left[i] : 0
            output[i * 2 + 1] = i < right.count ? right[i] : 0
        }
        return output
    }

    /// ponytail: no headset means the mic already picked up the remote
    /// channel's acoustic leak — keeping ME/REMOTE separate just bakes that
    /// echo into "me" without adding real isolation. Average into one track.
    private func downmix(_ left: [Int16], _ right: [Int16]) -> [Int16] {
        let count = max(left.count, right.count)
        guard count > 0 else { return [] }
        var output = [Int16](repeating: 0, count: count)
        for i in 0 ..< count {
            let l = Int32(i < left.count ? left[i] : 0)
            let r = Int32(i < right.count ? right[i] : 0)
            output[i] = Int16((l + r) / 2)
        }
        return output
    }

    private func decibels(of samples: [Float]) -> Float {
        guard !samples.isEmpty else { return -.infinity }
        var sumSquares: Float = 0
        vDSP_measqv(samples, 1, &sumSquares, vDSP_Length(samples.count))
        let rms = sqrtf(sumSquares)
        return rms > 0 ? 20 * log10f(rms) : -.infinity
    }

    private func convert(_ samples: [Float], using converter: AVAudioConverter) throws -> [Int16] {
        guard !samples.isEmpty else { return [] }
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat,
                                                 frameCapacity: AVAudioFrameCount(samples.count))
        else { return [] }
        inputBuffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { pointer in
            inputBuffer.floatChannelData![0].update(from: pointer.baseAddress!, count: samples.count)
        }

        let ratio = Double(WAVWriter.sampleRate) / sourceFormat.sampleRate
        let outCapacity = AVAudioFrameCount(Double(samples.count) * ratio) + 32
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCapacity)
        else { return [] }

        let box = ConsumeOnceBox(inputBuffer)
        var conversionError: NSError?
        converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            guard let buffer = box.take() else { outStatus.pointee = .noDataNow; return nil }
            outStatus.pointee = .haveData
            return buffer
        }
        if let conversionError { throw conversionError }

        guard let channelData = outputBuffer.int16ChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: channelData[0], count: Int(outputBuffer.frameLength)))
    }
}
