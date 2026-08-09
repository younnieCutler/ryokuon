import Foundation
import SwiftUI

/// Everything the menu bar + window UI reads and drives. One instance, owned
/// by RyokuonApp.
@MainActor
@Observable
final class AppState {
    let sessionStore = SessionStore()
    let permissions = PermissionsManager()

    private(set) var isRecording = false
    private(set) var meLevelDB: Float = -.infinity
    private(set) var remoteLevelDB: Float = -.infinity
    private(set) var silenceWarning: String?
    private(set) var sessions: [Session] = []
    var lastError: String?

    /// Remembered target so the menu bar item can read "녹음 시작 — Zoom"
    /// and start on a single click (Q17's one-click requirement survives
    /// picking a specific app).
    var lastTargetBundleID: String? {
        get { UserDefaults.standard.string(forKey: "dev.ryokuon.lastTargetBundleID") }
        set { UserDefaults.standard.set(newValue, forKey: "dev.ryokuon.lastTargetBundleID") }
    }
    var lastTargetDisplayName: String? {
        get { UserDefaults.standard.string(forKey: "dev.ryokuon.lastTargetDisplayName") }
        set { UserDefaults.standard.set(newValue, forKey: "dev.ryokuon.lastTargetDisplayName") }
    }

    var language: String {
        get { UserDefaults.standard.string(forKey: "dev.ryokuon.language") ?? "ja-JP" }
        set { UserDefaults.standard.set(newValue, forKey: "dev.ryokuon.language") }
    }

    private var capture: AudioCapture?
    private var watchdog: SilenceWatchdog?
    private var currentDirectory: URL?
    private var currentSession: Session?
    private var lastTickDate: Date?

    init() {
        // Q11: repair anything a crash left behind before the user can see
        // or touch the session list.
        let recovered = sessionStore.recoverCrashedSessions()
        if !recovered.isEmpty {
            lastError = "이전 실행이 비정상 종료됨 — \(recovered.count)개 녹음 복구됨"
        }
        reloadSessions()
    }

    func reloadSessions() {
        sessions = sessionStore.listSessions()
    }

    /// Apps currently making sound, for the "다른 앱 선택" submenu.
    func playingProcesses() -> [AudioProcess] {
        (try? listAudioProcesses().filter(\.isPlaying)) ?? []
    }

    func startWithLastTarget() {
        guard let bundleID = lastTargetBundleID,
              let process = (try? listAudioProcesses())?.first(where: { $0.bundleID == bundleID })
        else {
            lastError = "마지막으로 녹음한 앱(\(lastTargetDisplayName ?? "?"))이 지금 실행 중이 아님 — 다른 앱 선택 필요"
            return
        }
        start(target: process)
    }

    func start(target: AudioProcess) {
        guard !isRecording else { return }
        guard permissions.allGranted else {
            lastError = "권한 설정을 먼저 끝내야 함"
            return
        }

        do {
            let (session, directory) = try sessionStore.createSession(language: language, target: target)
            let newCapture = try AudioCapture(process: target, outputDirectory: directory)

            let newWatchdog = SilenceWatchdog()
            newWatchdog.onWarning = { [weak self] meSilent, remoteSilent in
                Task { @MainActor in
                    self?.silenceWarning = SilenceWatchdog.message(meSilent: meSilent, remoteSilent: remoteSilent)
                }
            }

            newCapture.onLevel = { [weak self] me, remote in
                Task { @MainActor in
                    guard let self else { return }
                    self.meLevelDB = me
                    self.remoteLevelDB = remote
                    let now = Date()
                    let delta = self.lastTickDate.map { now.timeIntervalSince($0) } ?? 0.2
                    self.lastTickDate = now
                    self.watchdog?.tick(meDB: me, remoteDB: remote, deltaTime: delta)
                }
            }

            try newCapture.start()

            capture = newCapture
            watchdog = newWatchdog
            currentDirectory = directory
            currentSession = session
            lastTargetBundleID = target.bundleID
            lastTargetDisplayName = target.displayName
            silenceWarning = nil
            lastError = nil
            isRecording = true
        } catch {
            lastError = "녹음 시작 실패: \(error)"
        }
    }

    func stop() {
        guard isRecording, let capture, var session = currentSession, let directory = currentDirectory else { return }
        do {
            try capture.stop()
            session.state = .finished
            session.durationSeconds = Double(capture.meFramesWritten) / Double(WAVWriter.sampleRate)
            try sessionStore.save(session, in: directory)
        } catch {
            lastError = "녹음 종료 중 오류: \(error)"
        }

        self.capture = nil
        watchdog = nil
        currentDirectory = nil
        currentSession = nil
        lastTickDate = nil
        isRecording = false
        meLevelDB = -.infinity
        remoteLevelDB = -.infinity
        reloadSessions()
    }
}

extension SilenceWatchdog {
    static func message(meSilent: Bool, remoteSilent: Bool) -> String {
        switch (meSilent, remoteSilent) {
        case (true, true): return "⚠ 양쪽 트랙 모두 30초간 무음 — 마이크·앱 소리 확인 필요"
        case (true, false): return "⚠ 내 목소리 트랙이 30초간 무음 — 마이크 음소거 확인 필요"
        case (false, true): return "⚠ 상대방 트랙이 30초간 무음 — 대상 앱 소리 확인 필요"
        case (false, false): return ""
        }
    }
}
