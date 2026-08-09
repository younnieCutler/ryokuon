import Accelerate
import AppKit
import AVFoundation
import CoreAudio
import Foundation

// Step 0 verification #2: can we get mic and one app's audio as two
// sample-aligned channels out of a single aggregate device?
//
// Usage:  capture-test                  -> list apps currently making sound
//         capture-test <bundleID> [sec] -> record that app + mic to out.wav

// MARK: - CoreAudio property helpers

enum CAError: Error, CustomStringConvertible {
    case status(String, OSStatus)
    var description: String {
        guard case let .status(what, code) = self else { return "" }
        let chars = withUnsafeBytes(of: code.bigEndian) { bytes in
            String(bytes.map { Character(UnicodeScalar($0)) })
        }
        return "\(what) failed: \(code) ('\(chars)')"
    }
}

/// stdout is buffered and a fatalError swallows it, which hid every diagnostic
/// during bring-up. Diagnostics go to stderr.
func log(_ message: String) {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
}

func address(_ selector: AudioObjectPropertySelector,
             _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
    -> AudioObjectPropertyAddress
{
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                               mElement: kAudioObjectPropertyElementMain)
}

func readValue<T>(_ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector,
                  _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                  default fallback: T) -> T
{
    var addr = address(selector, scope)
    var value = fallback
    var size = UInt32(MemoryLayout<T>.size)
    let status = AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, &value)
    return status == noErr ? value : fallback
}

func readString(_ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var addr = address(selector)
    var value: CFString?
    var size = UInt32(MemoryLayout<CFString?>.size)
    let status = AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, &value)
    guard status == noErr else { return nil }
    return value as String?
}

func readArray<T: FixedWidthInteger>(_ objectID: AudioObjectID,
                                     _ selector: AudioObjectPropertySelector,
                                     _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                                     of type: T.Type) throws -> [T]
{
    var addr = address(selector, scope)
    var size: UInt32 = 0
    var status = AudioObjectGetPropertyDataSize(objectID, &addr, 0, nil, &size)
    guard status == noErr else { throw CAError.status("GetPropertyDataSize(\(selector))", status) }

    let count = Int(size) / MemoryLayout<T>.size
    guard count > 0 else { return [] }
    var buffer = [T](repeating: 0, count: count)
    status = AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, &buffer)
    guard status == noErr else { throw CAError.status("GetPropertyData(\(selector))", status) }
    return buffer
}

// MARK: - Audio process enumeration

struct AudioProcess {
    let objectID: AudioObjectID
    let pid: pid_t
    let bundleID: String?
    let isPlaying: Bool

    var displayName: String {
        NSRunningApplication(processIdentifier: pid)?.localizedName
            ?? bundleID
            ?? "pid \(pid)"
    }
}

func allAudioProcesses() throws -> [AudioProcess] {
    let system = AudioObjectID(kAudioObjectSystemObject)
    let ids = try readArray(system, kAudioHardwarePropertyProcessObjectList, of: AudioObjectID.self)
    return ids.map { id in
        let bundleID = readString(id, kAudioProcessPropertyBundleID)
        return AudioProcess(
            objectID: id,
            pid: readValue(id, kAudioProcessPropertyPID, default: pid_t(-1)),
            bundleID: (bundleID?.isEmpty ?? true) ? nil : bundleID,
            isPlaying: readValue(id, kAudioProcessPropertyIsRunningOutput, default: UInt32(0)) != 0)
    }
}

// MARK: - Tap + aggregate device

/// Wraps the process tap and the aggregate device that pairs it with the mic.
/// Both are torn down on `stop()` — leaking either one leaves a phantom device
/// in the user's audio settings.
final class CaptureDevice {
    private(set) var tapID = AudioObjectID(kAudioObjectUnknown)
    private(set) var aggregateID = AudioObjectID(kAudioObjectUnknown)
    let micChannels: Int
    let tapChannels: Int

    init(tapping process: AudioProcess) throws {
        let description = CATapDescription(monoMixdownOfProcesses: [process.objectID])
        description.name = "Ryokuon Tap"
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = CATapMuteBehavior.unmuted

        var status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr else { throw CAError.status("AudioHardwareCreateProcessTap", status) }

        guard let tapUID = readString(tapID, kAudioTapPropertyUID) else {
            throw CAError.status("read kAudioTapPropertyUID", -1)
        }

        let micID = readValue(AudioObjectID(kAudioObjectSystemObject),
                              kAudioHardwarePropertyDefaultInputDevice,
                              default: AudioObjectID(kAudioObjectUnknown))
        guard micID != kAudioObjectUnknown,
              let micUID = readString(micID, kAudioDevicePropertyDeviceUID)
        else { throw CAError.status("no default input device", -1) }

        micChannels = try channelCount(of: micID)
        tapChannels = try tapChannelCount(tapID)

        let aggregateUID = UUID().uuidString
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Ryokuon Capture",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceMainSubDeviceKey: micUID,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: micUID]],
            // Drift compensation is the whole point: the mic and the tapped app
            // run off different clocks, and an hour of uncorrected drift puts the
            // two tracks hundreds of milliseconds apart.
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: tapUID,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]

        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID)
        guard status == noErr else {
            throw CAError.status("AudioHardwareCreateAggregateDevice", status)
        }
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID) }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        aggregateID = kAudioObjectUnknown
        tapID = kAudioObjectUnknown
    }
}

func channelCount(of deviceID: AudioObjectID) throws -> Int {
    var addr = address(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput)
    var size: UInt32 = 0
    var status = AudioObjectGetPropertyDataSize(deviceID, &addr, 0, nil, &size)
    guard status == noErr else { throw CAError.status("stream config size", status) }

    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
    defer { raw.deallocate() }
    status = AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, raw)
    guard status == noErr else { throw CAError.status("stream config", status) }

    let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
    return list.reduce(0) { $0 + Int($1.mNumberChannels) }
}

func tapChannelCount(_ tapID: AudioObjectID) throws -> Int {
    var addr = address(kAudioTapPropertyFormat)
    var format = AudioStreamBasicDescription()
    var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    let status = AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &format)
    guard status == noErr else { throw CAError.status("kAudioTapPropertyFormat", status) }
    log("tap format: \(format.mSampleRate)Hz \(format.mChannelsPerFrame)ch "
        + "flags=\(format.mBitsPerChannel)bit id=\(format.mFormatID)")
    return Int(format.mChannelsPerFrame)
}

// MARK: - Recording

/// Collects the aggregate device's input channels.
///
/// AVAudioEngine was the first attempt: bind the aggregate to
/// `kAudioOutputUnitProperty_CurrentDevice` and `installTap`. The audio unit does
/// bind to the right device, but the input node keeps reporting 1 channel and
/// never exposes the tap's channels. A raw IOProc sees the real buffer list, and
/// it is what Apple's own process-tap sample uses.
func record(process: AudioProcess, seconds: Double, toDirectory directory: URL) throws {
    let device = try CaptureDevice(tapping: process)
    defer { device.stop() }

    log("tap=\(device.tapID) aggregate=\(device.aggregateID)")
    log("mic channels=\(device.micChannels)  tap channels=\(device.tapChannels)")

    let totalChannels = try channelCount(of: device.aggregateID)
    let sampleRate = readValue(device.aggregateID, kAudioDevicePropertyNominalSampleRate,
                               default: Float64(48000))
    log("aggregate: \(totalChannels)ch @ \(sampleRate)Hz")
    guard totalChannels >= 2 else {
        throw CAError.status("aggregate has \(totalChannels) input channels, need >= 2", -1)
    }

    // Channel order follows the aggregate's stream list: sub-devices first, taps
    // after. Never hardcode the split — a stereo mic would shift everything.
    let micRange = 0 ..< device.micChannels
    let tapRange = device.micChannels ..< totalChannels
    log("channel map: mic=\(micRange) tap=\(tapRange)")

    var micSamples = [Float]()
    var tapSamples = [Float]()
    var sawLayout = false
    let lock = NSLock()

    var procID: AudioDeviceIOProcID?
    let queue = DispatchQueue(label: "dev.ryokuon.capture-test")
    var status = AudioDeviceCreateIOProcIDWithBlock(&procID, device.aggregateID, queue) {
        _, inputData, _, _, _ in
        let buffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: inputData))

        lock.lock()
        defer { lock.unlock() }

        if !sawLayout {
            sawLayout = true
            let shape = buffers.map { "\($0.mNumberChannels)ch" }.joined(separator: " + ")
            log("IOProc buffer list: \(buffers.count) buffer(s) — \(shape)")
        }

        // Walk the buffer list as one flat channel sequence so both the
        // interleaved and the one-buffer-per-channel layouts work.
        var channelIndex = 0
        for buffer in buffers {
            let channels = Int(buffer.mNumberChannels)
            guard let raw = buffer.mData else { channelIndex += channels; continue }
            let frames = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size / max(channels, 1)
            let samples = raw.assumingMemoryBound(to: Float.self)

            for offset in 0 ..< channels {
                let absolute = channelIndex + offset
                var extracted = [Float](repeating: 0, count: frames)
                for frame in 0 ..< frames {
                    extracted[frame] = samples[frame * channels + offset]
                }
                if micRange.contains(absolute) { micSamples.append(contentsOf: extracted) }
                if tapRange.contains(absolute) { tapSamples.append(contentsOf: extracted) }
            }
            channelIndex += channels
        }
    }
    guard status == noErr else { throw CAError.status("AudioDeviceCreateIOProcIDWithBlock", status) }
    defer { AudioDeviceDestroyIOProcID(device.aggregateID, procID!) }

    status = AudioDeviceStart(device.aggregateID, procID)
    guard status == noErr else { throw CAError.status("AudioDeviceStart", status) }

    print("recording \(seconds)s — talk into the mic AND play sound in \(process.displayName)")
    Thread.sleep(forTimeInterval: seconds)
    AudioDeviceStop(device.aggregateID, procID)

    lock.lock()
    let mic = micSamples
    let tap = tapSamples
    lock.unlock()

    for (name, samples) in [("me", mic), ("remote", tap)] {
        let url = directory.appendingPathComponent("\(name).wav")
        try writeWAV(samples, sampleRate: sampleRate, to: url)
        var peak: Float = 0
        vDSP_maxmgv(samples, 1, &peak, vDSP_Length(samples.count))
        let db = peak > 0 ? 20 * log10(peak) : -Float.infinity
        let bar = String(repeating: "#", count: min(40, Int(max(0, db + 60) / 1.5)))
        print(String(format: "  %-7@ %6d frames  peak %6.1f dB %@",
                     name as NSString, samples.count, db, bar))
    }
}

func writeWAV(_ samples: [Float], sampleRate: Float64, to url: URL) throws {
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                               channels: 1, interleaved: false)!
    let file = try AVAudioFile(forWriting: url, settings: [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
    ])
    guard !samples.isEmpty,
          let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                        frameCapacity: AVAudioFrameCount(samples.count))
    else { return }
    buffer.frameLength = AVAudioFrameCount(samples.count)
    samples.withUnsafeBufferPointer {
        buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count)
    }
    try file.write(from: buffer)
}

// MARK: - main

let arguments = Array(CommandLine.arguments.dropFirst())
let processes = try allAudioProcesses()

if arguments.isEmpty {
    print("obj    pid    out  bundleID / name")
    for process in processes.sorted(by: { $0.pid < $1.pid }) {
        print(String(format: "%-6d %-6d %-4@ %@",
                     process.objectID, process.pid,
                     (process.isPlaying ? "♪" : "-") as NSString,
                     process.bundleID ?? "(no bundle) \(process.displayName)"))
    }
    print("\nusage: capture-test <bundleID|pid:N> [seconds]")
    exit(0)
}

let selector = arguments[0]
let target: AudioProcess?
if selector.hasPrefix("pid:"), let pid = pid_t(selector.dropFirst(4)) {
    target = processes.first { $0.pid == pid }
} else {
    target = processes.first { $0.bundleID == selector }
}
guard let target else {
    print("no audio process matching \(selector)")
    exit(1)
}

let duration = arguments.count > 1 ? Double(arguments[1]) ?? 5 : 5
let outputDirectory = URL(fileURLWithPath: ".")
for name in ["me.wav", "remote.wav"] {
    try? FileManager.default.removeItem(at: outputDirectory.appendingPathComponent(name))
}
try record(process: target, seconds: duration, toDirectory: outputDirectory)
