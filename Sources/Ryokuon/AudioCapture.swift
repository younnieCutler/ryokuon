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

/// Captures mic + one app's audio into a single 16kHz stereo WAV file —
/// left channel = me, right channel = remote (user decision 2026-08-09:
/// one file to manage instead of two). STT in step 3 reads the two channels
/// independently, so this is purely a storage-layout change; ME/REMOTE
/// separation for transcription is unaffected.
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
    private let micRange: Range<Int>
    private let tapRange: Range<Int>
    private let drainQueue = DispatchQueue(label: "dev.ryokuon.capture.writer")
    private var drainTimer: DispatchSourceTimer?

    private let writer: WAVWriter
    private let sourceFormat: AVAudioFormat
    private let targetFormat: AVAudioFormat
    private let meConverter: AVAudioConverter
    private let remoteConverter: AVAudioConverter

    /// dB level per track, reported after each drain cycle (~5x/sec). Cheap
    /// byproduct of the resample step — step 2's level meter and silence
    /// warning (Q18) subscribe to this.
    var onLevel: ((_ meDB: Float, _ remoteDB: Float) -> Void)?

    var diagnostics: String {
        "mic=\(device.micChannels)ch tap=\(device.tapChannels)ch rate=\(device.sampleRate)Hz"
    }
    var framesWritten: Int { writer.framesWritten }
    static let fileName = "call.wav"

    init(process: AudioProcess, outputDirectory: URL) throws {
        device = try CaptureDevice(tapping: process)
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

        writer = try WAVWriter(url: outputDirectory.appendingPathComponent(Self.fileName), channels: 2)
    }

    func start() throws {
        let micRing = self.micRing
        let tapRing = self.tapRing
        let micRange = self.micRange
        let tapRange = self.tapRange

        var newProcID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&newProcID, device.aggregateID, nil) {
            _, inputData, _, _, _ in
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
            var channelIndex = 0
            for buffer in buffers {
                let channels = Int(buffer.mNumberChannels)
                guard channels > 0, let raw = buffer.mData else { channelIndex += channels; continue }
                let frames = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size / channels
                let samples = raw.assumingMemoryBound(to: Float.self)

                if channels == 1 {
                    if micRange.contains(channelIndex) { micRing.write(samples, count: frames) }
                    if tapRange.contains(channelIndex) { tapRing.write(samples, count: frames) }
                } else {
                    // Interleaved multi-channel buffer (e.g. a stereo mic) —
                    // de-interleave per channel before handing to the rings.
                    for offset in 0 ..< channels {
                        let absolute = channelIndex + offset
                        guard micRange.contains(absolute) || tapRange.contains(absolute) else { continue }
                        var extracted = [Float](repeating: 0, count: frames)
                        for frame in 0 ..< frames { extracted[frame] = samples[frame * channels + offset] }
                        extracted.withUnsafeBufferPointer { pointer in
                            guard let base = pointer.baseAddress else { return }
                            if micRange.contains(absolute) { micRing.write(base, count: frames) }
                            if tapRange.contains(absolute) { tapRing.write(base, count: frames) }
                        }
                    }
                }
                channelIndex += channels
            }
        }
        guard status == noErr else { throw CoreAudioError.status("AudioDeviceCreateIOProcIDWithBlock", status) }
        procID = newProcID

        let startStatus = AudioDeviceStart(device.aggregateID, newProcID)
        guard startStatus == noErr else { throw CoreAudioError.status("AudioDeviceStart", startStatus) }

        let timer = DispatchSource.makeTimerSource(queue: drainQueue)
        timer.schedule(deadline: .now() + .milliseconds(200), repeating: .milliseconds(200))
        timer.setEventHandler { [weak self] in self?.drainAndWrite() }
        timer.resume()
        drainTimer = timer
    }

    func stop() throws {
        drainTimer?.cancel()
        drainTimer = nil
        if let procID {
            AudioDeviceStop(device.aggregateID, procID)
            AudioDeviceDestroyIOProcID(device.aggregateID, procID)
        }
        drainQueue.sync { self.drainAndWrite() } // flush whatever's left in the rings
        try writer.finish()
        device.stop()
    }

    private func drainAndWrite() {
        var meSamples: [Float] = []
        var remoteSamples: [Float] = []
        micRing.drain(into: &meSamples)
        tapRing.drain(into: &remoteSamples)
        guard !meSamples.isEmpty || !remoteSamples.isEmpty else { return }

        do {
            let me = try convert(meSamples, using: meConverter)
            let remote = try convert(remoteSamples, using: remoteConverter)
            try writer.append(interleave(left: me, right: remote))
        } catch {
            // Priority 1 is not losing the recording. Log and keep going
            // rather than crash the capture loop over one bad chunk.
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
