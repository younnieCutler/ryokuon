import AppKit
import CoreAudio
import Foundation

/// A process CoreAudio knows can render audio. `bundleID` is often reported
/// incorrectly for processes without a real app bundle (confirmed in step 0
/// against `play-to-device`, a bare CLI tool) — treat `pid` as the reliable
/// identifier and `bundleID` as a display hint only.
struct AudioProcess: Identifiable {
    let objectID: AudioObjectID
    let pid: pid_t
    let bundleID: String?
    let isPlaying: Bool

    var id: pid_t { pid }

    /// Menu-bar-only apps (eqMac and other audio routers) report as "playing"
    /// all the time because system audio passes through them — they should
    /// never be the default recording target. Browser/Zoom helper processes
    /// have no NSRunningApplication at all, so they don't count as this.
    var isMenuBarUtility: Bool {
        NSRunningApplication(processIdentifier: pid)?.activationPolicy == .accessory
    }

    /// CoreAudio often reports the *helper* subprocess that actually
    /// renders audio (`com.google.Chrome.helper`, `...helper.Renderer`),
    /// not the main app — confirmed by a real session where this ended up
    /// showing "com.google.Chrome.helper" as the target instead of
    /// "Chrome". `NSRunningApplication` doesn't know about headless helper
    /// processes (no Dock entry), so it returns nil for those and we'd
    /// otherwise fall straight through to the raw bundle ID. The alias
    /// table catches known apps' helper bundle IDs before that fallback.
    var displayName: String {
        NSRunningApplication(processIdentifier: pid)?.localizedName
            ?? bundleID.flatMap(Self.friendlyName(forBundleID:))
            ?? bundleID
            ?? "pid \(pid)"
    }

    /// Matched by substring, not exact bundle ID, since helper processes
    /// append suffixes like `.helper`, `.helper.Renderer`, `.helper.GPU`.
    private static let knownAliases: [(needle: String, name: String)] = [
        ("com.google.chrome", "Chrome"),
        ("org.mozilla.firefox", "Firefox"),
        ("com.microsoft.edgemac", "Edge"),
        ("com.apple.safari", "Safari"),
        ("us.zoom.xos", "Zoom"),
        ("com.microsoft.teams", "Teams"),
        ("com.tinyspeck.slackmacgap", "Slack"),
        ("com.hnc.discord", "Discord"),
        ("com.apple.facetime", "FaceTime"),
        ("net.whatsapp.whatsapp", "WhatsApp"),
        ("jp.naver.line.mac", "LINE"),
        ("com.kakao.kakaotalkmac", "카카오톡"),
        ("com.skype.skype", "Skype"),
        ("com.google.meet", "Google Meet"),
        ("com.electron.discord", "Discord"),
        ("com.spotify.client", "Spotify"),
    ]

    static func friendlyName(forBundleID bundleID: String) -> String? {
        let lowered = bundleID.lowercased()
        return knownAliases.first { lowered.contains($0.needle) }?.name
    }
}

enum RecordingTargetSelection {
    static func choose(from processes: [AudioProcess], selectedPID: pid_t?, lastBundleID: String?) -> AudioProcess? {
        // An explicit choice must never silently fall back to another call.
        if let selectedPID { return processes.first { $0.pid == selectedPID } }
        return processes.first { $0.bundleID != nil && $0.bundleID == lastBundleID && !$0.isMenuBarUtility }
            ?? processes.first { !$0.isMenuBarUtility }
    }
}

enum CoreAudioError: Error, CustomStringConvertible {
    case status(String, OSStatus)

    var description: String {
        guard case let .status(what, code) = self else { return "" }
        let chars = withUnsafeBytes(of: code.bigEndian) { bytes in
            String(bytes.map { Character(UnicodeScalar($0)) })
        }
        return "\(what) failed: \(code) ('\(chars)')"
    }
}

func caAddress(_ selector: AudioObjectPropertySelector,
               _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
    -> AudioObjectPropertyAddress
{
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                               mElement: kAudioObjectPropertyElementMain)
}

func caReadValue<T: SIMDScalar>(_ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                                default fallback: T) -> T
{
    var address = caAddress(selector, scope)
    var value = fallback
    var size = UInt32(MemoryLayout<T>.size)
    let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value)
    return status == noErr ? value : fallback
}

func caReadString(_ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var address = caAddress(selector)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value)
    guard status == noErr, let value else { return nil }
    return value.takeRetainedValue() as String
}

func caReadArray<T: FixedWidthInteger>(_ objectID: AudioObjectID,
                                       _ selector: AudioObjectPropertySelector,
                                       _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                                       of type: T.Type) throws -> [T]
{
    var address = caAddress(selector, scope)
    var size: UInt32 = 0
    var status = AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &size)
    guard status == noErr else { throw CoreAudioError.status("GetPropertyDataSize(\(selector))", status) }

    let count = Int(size) / MemoryLayout<T>.size
    guard count > 0 else { return [] }
    var buffer = [T](repeating: 0, count: count)
    status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &buffer)
    guard status == noErr else { throw CoreAudioError.status("GetPropertyData(\(selector))", status) }
    return buffer
}

/// Every process CoreAudio has ever seen render or capture audio, not just
/// ones currently playing. Filter on `isPlaying` for a "what's making sound
/// right now" list.
func listAudioProcesses() throws -> [AudioProcess] {
    let system = AudioObjectID(kAudioObjectSystemObject)
    let ids = try caReadArray(system, kAudioHardwarePropertyProcessObjectList, of: AudioObjectID.self)
    return ids.map { id in
        let bundleID = caReadString(id, kAudioProcessPropertyBundleID)
        return AudioProcess(
            objectID: id,
            pid: caReadValue(id, kAudioProcessPropertyPID, default: pid_t(-1)),
            bundleID: (bundleID?.isEmpty ?? true) ? nil : bundleID,
            isPlaying: caReadValue(id, kAudioProcessPropertyIsRunningOutput, default: UInt32(0)) != 0)
    }
}
