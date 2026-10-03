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
    /// `micChannels`/`sampleRate` are `var`, not `let`: `switchMic(toUID:)`
    /// rebuilds the aggregate around a different mic mid-recording, and
    /// both can change if the new mic's channel count or native rate
    /// differs from the old one's.
    private(set) var micChannels: Int
    let tapChannels: Int
    private(set) var sampleRate: Float64

    /// `micDeviceUID` overrides the system default input device (e.g. "use
    /// the built-in mic even though AirPods are the default input") — nil
    /// falls back to `kAudioHardwarePropertyDefaultInputDevice` exactly as
    /// before. An unresolvable UID (device unplugged since it was chosen in
    /// Settings) also falls back rather than throwing.
    init(tapping process: AudioProcess, micDeviceUID: String? = nil) throws {
        let description = CATapDescription(monoMixdownOfProcesses: [process.objectID])
        description.name = "Ryokuon Tap"
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = CATapMuteBehavior.unmuted

        let status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr else { throw CoreAudioError.status("AudioHardwareCreateProcessTap", status) }
        let createdTapID = tapID
        var completed = false
        defer {
            if !completed { AudioHardwareDestroyProcessTap(createdTapID) }
        }

        guard let tapUID = caReadString(tapID, kAudioTapPropertyUID) else {
            throw CoreAudioError.status("read kAudioTapPropertyUID", -1)
        }
        tapChannels = try Self.channelCount(of: tapID, scope: kAudioObjectPropertyScopeGlobal, isTapFormat: true)

        let (micID, micUID) = try Self.resolveMic(uid: micDeviceUID)
        micChannels = try Self.channelCount(of: micID, scope: kAudioObjectPropertyScopeInput, isTapFormat: false)
        aggregateID = try Self.makeAggregateDevice(micUID: micUID, tapUID: tapUID)

        // The aggregate's rate follows its main sub-device (the mic), not a
        // fixed 48kHz — confirmed in step 0 with AirPods (24kHz) vs the
        // built-in mic (48kHz). Never hardcode this.
        sampleRate = caReadValue(aggregateID, kAudioDevicePropertyNominalSampleRate, default: Float64(48000))
        completed = true
    }

    deinit { stop() }

    /// Rebuilds the aggregate device around a different mic while a
    /// recording is in progress — the tap (target app audio) is untouched,
    /// so only the "me" side of the capture is interrupted for the moment
    /// it takes to tear down the old aggregate and stand up the new one.
    /// Callers (`AudioCapture`) must recreate their IOProc against the new
    /// `aggregateID`/`micChannels` afterward — this only swaps the device.
    ///
    /// Deliberately does not touch the session's mono/stereo channel count:
    /// that was fixed at recording start (`AppState.start`) and changing it
    /// mid-file would corrupt the WAV header. Switching mics only changes
    /// which physical device fills the "mic" slot, never the file layout.
    func switchMic(toUID micDeviceUID: String?) throws {
        guard let tapUID = caReadString(tapID, kAudioTapPropertyUID) else {
            throw CoreAudioError.status("read kAudioTapPropertyUID", -1)
        }
        let (micID, micUID) = try Self.resolveMic(uid: micDeviceUID)
        let newMicChannels = try Self.channelCount(of: micID, scope: kAudioObjectPropertyScopeInput, isTapFormat: false)
        let newAggregateID = try Self.makeAggregateDevice(micUID: micUID, tapUID: tapUID)

        let oldAggregateID = aggregateID
        aggregateID = newAggregateID
        micChannels = newMicChannels
        sampleRate = caReadValue(newAggregateID, kAudioDevicePropertyNominalSampleRate, default: sampleRate)
        if oldAggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(oldAggregateID) }
    }

    private static func resolveMic(uid: String?) throws -> (id: AudioObjectID, uid: String) {
        let micID = uid.flatMap(deviceID(forUID:))
            ?? caReadValue(AudioObjectID(kAudioObjectSystemObject),
                           kAudioHardwarePropertyDefaultInputDevice,
                           default: AudioObjectID(kAudioObjectUnknown))
        guard micID != kAudioObjectUnknown,
              let micUID = caReadString(micID, kAudioDevicePropertyDeviceUID)
        else { throw CoreAudioError.status("no default input device", -1) }
        return (micID, micUID)
    }

    private static func makeAggregateDevice(micUID: String, tapUID: String) throws -> AudioObjectID {
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
        var newAggregateID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &newAggregateID)
        guard status == noErr else { throw CoreAudioError.status("AudioHardwareCreateAggregateDevice", status) }
        return newAggregateID
    }

    /// True when the mic actually being used — `micDeviceUID` if given and
    /// resolvable, else the system default input — is the built-in mic, i.e.
    /// no AirPods/Bluetooth/USB headset in use. Callers use this to fall
    /// back to mono recording, since without a headset the remote party's
    /// audio leaks acoustically from the speaker back into the mic (echo).
    static func isBuiltInMicActive(deviceUID: String? = nil) -> Bool {
        let micID = deviceUID.flatMap(deviceID(forUID:))
            ?? caReadValue(AudioObjectID(kAudioObjectSystemObject),
                           kAudioHardwarePropertyDefaultInputDevice,
                           default: AudioObjectID(kAudioObjectUnknown))
        guard micID != kAudioObjectUnknown else { return false }
        let transportType: UInt32 = caReadValue(micID, kAudioDevicePropertyTransportType,
                                                default: kAudioDeviceTransportTypeUnknown)
        return transportType == kAudioDeviceTransportTypeBuiltIn
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
