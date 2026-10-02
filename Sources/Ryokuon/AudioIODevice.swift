import CoreAudio
import Foundation

/// A CoreAudio device the settings UI can offer as a manual input/output
/// pick, overriding whatever `kAudioHardwarePropertyDefault{Input,Output}Device`
/// the system currently reports.
struct AudioIODevice: Identifiable, Hashable {
    let uid: String
    let name: String
    var id: String { uid }
}

/// Every hardware device with at least one input channel.
func listInputDevices() -> [AudioIODevice] {
    devices(withChannelsIn: kAudioObjectPropertyScopeInput)
}

/// Every hardware device with at least one output channel.
func listOutputDevices() -> [AudioIODevice] {
    devices(withChannelsIn: kAudioObjectPropertyScopeOutput)
}

/// Resolves a device UID (as stored in `AppState`/`UserDefaults`) back to
/// the live `AudioObjectID` CoreAudio calls need — device IDs aren't stable
/// across reboots/reconnects, so only the UID is ever persisted.
func deviceID(forUID uid: String) -> AudioObjectID? {
    let system = AudioObjectID(kAudioObjectSystemObject)
    guard let ids = try? caReadArray(system, kAudioHardwarePropertyDevices, of: AudioObjectID.self) else { return nil }
    return ids.first { caReadString($0, kAudioDevicePropertyDeviceUID) == uid }
}

private func devices(withChannelsIn scope: AudioObjectPropertyScope) -> [AudioIODevice] {
    let system = AudioObjectID(kAudioObjectSystemObject)
    guard let ids = try? caReadArray(system, kAudioHardwarePropertyDevices, of: AudioObjectID.self) else { return [] }
    return ids.compactMap { id in
        guard let channels = try? CaptureDevice.channelCount(of: id, scope: scope, isTapFormat: false),
              channels > 0,
              let uid = caReadString(id, kAudioDevicePropertyDeviceUID)
        else { return nil }
        let name = caReadString(id, kAudioObjectPropertyName) ?? uid
        return AudioIODevice(uid: uid, name: name)
    }
}
