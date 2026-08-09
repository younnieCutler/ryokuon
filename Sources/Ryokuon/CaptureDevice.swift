import CoreAudio
import Foundation

/// Pairs a process tap (the target app's audio) with the default input mic in
/// a private aggregate device, so both arrive sample-aligned in one IOProc
/// callback. See plan/2026-08-09-step0-results.md for why this beats
/// AVAudioEngine (its input node never exposes more than 1 channel on an
/// aggregate device, even though the device itself is multi-channel).
///
/// Both objects are torn down together in `stop()` — leaking either leaves a
/// phantom device in the user's Audio MIDI Setup.
final class CaptureDevice {
    private(set) var tapID = AudioObjectID(kAudioObjectUnknown)
    private(set) var aggregateID = AudioObjectID(kAudioObjectUnknown)

    /// Channel count of the mic sub-device. The aggregate's channels are
    /// ordered [mic channels..., tap channels...] — never assume mono.
    let micChannels: Int
    let tapChannels: Int
    let sampleRate: Float64

    init(tapping process: AudioProcess) throws {
        let description = CATapDescription(monoMixdownOfProcesses: [process.objectID])
        description.name = "Ryokuon Tap"
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = CATapMuteBehavior.unmuted

        var status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr else { throw CoreAudioError.status("AudioHardwareCreateProcessTap", status) }

        guard let tapUID = caReadString(tapID, kAudioTapPropertyUID) else {
            throw CoreAudioError.status("read kAudioTapPropertyUID", -1)
        }
        tapChannels = try Self.channelCount(of: tapID, scope: kAudioObjectPropertyScopeGlobal, isTapFormat: true)

        let micID = caReadValue(AudioObjectID(kAudioObjectSystemObject),
                                kAudioHardwarePropertyDefaultInputDevice,
                                default: AudioObjectID(kAudioObjectUnknown))
        guard micID != kAudioObjectUnknown,
              let micUID = caReadString(micID, kAudioDevicePropertyDeviceUID)
        else { throw CoreAudioError.status("no default input device", -1) }
        micChannels = try Self.channelCount(of: micID, scope: kAudioObjectPropertyScopeInput, isTapFormat: false)

        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Ryokuon Capture",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceMainSubDeviceKey: micUID,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: micUID]],
            // Drift compensation is the whole point: mic and tap run off
            // different clocks, and uncorrected drift over an hour puts the
            // two tracks hundreds of milliseconds apart.
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: tapUID,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]

        status = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregateID)
        guard status == noErr else { throw CoreAudioError.status("AudioHardwareCreateAggregateDevice", status) }

        // The aggregate's rate follows its main sub-device (the mic), not a
        // fixed 48kHz — confirmed in step 0 with AirPods (24kHz) vs the
        // built-in mic (48kHz). Never hardcode this.
        sampleRate = caReadValue(aggregateID, kAudioDevicePropertyNominalSampleRate, default: Float64(48000))
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID) }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        aggregateID = kAudioObjectUnknown
        tapID = kAudioObjectUnknown
    }

    static func channelCount(of deviceID: AudioObjectID, scope: AudioObjectPropertyScope,
                             isTapFormat: Bool) throws -> Int
    {
        if isTapFormat {
            var address = caAddress(kAudioTapPropertyFormat)
            var format = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &format)
            guard status == noErr else { throw CoreAudioError.status("kAudioTapPropertyFormat", status) }
            return Int(format.mChannelsPerFrame)
        }

        var address = caAddress(kAudioDevicePropertyStreamConfiguration, scope)
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size)
        guard status == noErr else { throw CoreAudioError.status("stream config size", status) }

        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { raw.deallocate() }
        status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, raw)
        guard status == noErr else { throw CoreAudioError.status("stream config", status) }

        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}
