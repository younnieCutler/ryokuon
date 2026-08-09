import AVFoundation
import Foundation

/// Q14: three permissions, requested one at a time with an explanation
/// screen before each system prompt — not all at once.
///
/// Audio-capture and Documents-folder access have no query API (unlike
/// microphone), so they're tracked as "requested this launch" rather than a
/// true live status: macOS surfaces its own system prompt the first time the
/// underlying API is actually used, and we cache whether that attempt
/// succeeded.
@Observable
final class PermissionsManager {
    enum Status: Equatable {
        case notDetermined
        case granted
        case denied
    }

    private(set) var microphone: Status = .notDetermined
    private(set) var audioCapture: Status = .notDetermined
    private(set) var documentsFolder: Status = .notDetermined

    var allGranted: Bool {
        microphone == .granted && audioCapture == .granted && documentsFolder == .granted
    }

    init() {
        refreshMicrophoneStatus()
        if UserDefaults.standard.bool(forKey: "dev.ryokuon.audioCaptureGranted") {
            audioCapture = .granted
        }
        if UserDefaults.standard.bool(forKey: "dev.ryokuon.documentsFolderGranted") {
            documentsFolder = .granted
        }
    }

    func refreshMicrophoneStatus() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: microphone = .granted
        case .denied, .restricted: microphone = .denied
        case .notDetermined: microphone = .notDetermined
        @unknown default: microphone = .notDetermined
        }
    }

    @MainActor
    func requestMicrophone() async {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        microphone = granted ? .granted : .denied
    }

    /// There's no dedicated "request audio capture" API — the system prompt
    /// appears the first time a process tap is actually created. Tapping our
    /// own process is a harmless way to trigger it without depending on any
    /// other app being open.
    func requestAudioCapture() {
        guard let ownProcess = try? listAudioProcesses().first(where: { $0.pid == getpid() }) else {
            audioCapture = .denied
            return
        }
        if let device = try? CaptureDevice(tapping: ownProcess) {
            device.stop()
            audioCapture = .granted
        } else {
            audioCapture = .denied
        }
        UserDefaults.standard.set(audioCapture == .granted, forKey: "dev.ryokuon.audioCaptureGranted")
    }

    /// Same story as audio capture: writing to Documents is what triggers
    /// the system's folder-access prompt.
    func requestDocumentsAccess(root: URL) {
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let probe = root.appendingPathComponent(".ryokuon-probe")
            try Data().write(to: probe)
            try FileManager.default.removeItem(at: probe)
            documentsFolder = .granted
        } catch {
            documentsFolder = .denied
        }
        UserDefaults.standard.set(documentsFolder == .granted, forKey: "dev.ryokuon.documentsFolderGranted")
    }
}
