import AVFoundation
import CoreAudio
import Foundation

// Step 0.5 helper: play a file to ONE named output device, leaving the system
// default alone. Pair with capture-test to check that a process tap follows the
// process rather than the default output device — without touching the user's
// audio settings.
//
// Usage:  play-to-device                   -> list output devices
//         play-to-device <name> <file.wav> -> play there until killed

func address(_ selector: AudioObjectPropertySelector,
             _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
    -> AudioObjectPropertyAddress
{
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                               mElement: kAudioObjectPropertyElementMain)
}

func readString(_ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var addr = address(selector)
    var value: CFString?
    var size = UInt32(MemoryLayout<CFString?>.size)
    guard AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, &value) == noErr
    else { return nil }
    return value as String?
}

func outputChannels(of deviceID: AudioObjectID) -> Int {
    var addr = address(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeOutput)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(deviceID, &addr, 0, nil, &size) == noErr, size > 0
    else { return 0 }
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
    defer { raw.deallocate() }
    guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, raw) == noErr
    else { return 0 }
    let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
    return list.reduce(0) { $0 + Int($1.mNumberChannels) }
}

func allOutputDevices() -> [(id: AudioObjectID, name: String)] {
    var addr = address(kAudioHardwarePropertyDevices)
    var size: UInt32 = 0
    let system = AudioObjectID(kAudioObjectSystemObject)
    guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
    return ids.compactMap { id in
        guard outputChannels(of: id) > 0,
              let name = readString(id, kAudioObjectPropertyName) else { return nil }
        return (id, name)
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
let devices = allOutputDevices()

guard arguments.count >= 2 else {
    print("output devices:")
    for device in devices { print("  [\(device.id)] \(device.name)") }
    print("\nusage: play-to-device <name substring> <file.wav>")
    exit(0)
}

guard let device = devices.first(where: { $0.name.contains(arguments[0]) }) else {
    print("no output device matching '\(arguments[0])'")
    exit(1)
}

let file = try AVAudioFile(forReading: URL(fileURLWithPath: arguments[1]))
let engine = AVAudioEngine()
let player = AVAudioPlayerNode()
engine.attach(player)
engine.connect(player, to: engine.mainMixerNode, format: file.processingFormat)

// Route this engine's output to the chosen device. The system default is
// untouched, so anything the tap picks up came from the process, not the
// default output path.
var deviceID = device.id
let status = AudioUnitSetProperty(engine.outputNode.audioUnit!,
                                  kAudioOutputUnitProperty_CurrentDevice,
                                  kAudioUnitScope_Global, 0, &deviceID,
                                  UInt32(MemoryLayout<AudioDeviceID>.size))
guard status == noErr else {
    print("failed to set output device: \(status)")
    exit(1)
}

print("playing \(arguments[1]) to [\(device.id)] \(device.name) — pid \(getpid())")
try engine.start()

// Loop so the capture test always has something to hear.
func scheduleLoop() {
    player.scheduleFile(file, at: nil) { scheduleLoop() }
}
scheduleLoop()
player.play()

RunLoop.main.run()
