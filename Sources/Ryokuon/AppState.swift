import AppKit
import Foundation
import SwiftUI

/// Everything the menu bar + window UI reads and drives. One instance, owned
/// by RyokuonApp.
@MainActor
@Observable
final class AppState {
    let sessionStore = SessionStore()
    let permissions = PermissionsManager()
    let player = Player()

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

    /// Q7: 일본어 기본, 한국어·영어 지원 — 0단계에서 이 세 로케일만 실제로 검증했으므로
    /// 선택지도 그만큼만 노출한다(SpeechTranscriber가 지원하는 다른 로케일도 있지만
    /// 검증 안 된 걸 고를 수 있게 하면 "일본어인 줄 알았는데 안 됨" 같은 혼란만 생긴다).
    static let supportedLanguages: [(id: String, label: String)] = [
        ("ja-JP", "일본어"), ("ko-KR", "한국어"), ("en-US", "영어"),
    ]

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
            session.durationSeconds = Double(capture.framesWritten) / Double(WAVWriter.sampleRate)
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

    // MARK: - Playback (step 5, Q4)

    private(set) var playingSessionID: String?

    func play(_ session: Session) {
        let directory = sessionStore.directory(for: session)
        guard let url = AudioCapture.audioFileURL(in: directory) else {
            lastError = "재생할 오디오 파일 없음"
            return
        }
        do {
            player.onFinish = { [weak self] in self?.playingSessionID = nil }
            try player.play(url: url, meGain: session.gains.me, remoteGain: session.gains.remote)
            playingSessionID = session.id
        } catch {
            lastError = "재생 실패: \(error)"
        }
    }

    func stopPlayback() {
        player.stop()
        playingSessionID = nil
    }

    /// Q4: gain is a stored value applied at playback/STT time, not a live
    /// monitoring knob — this just persists it. Playing again (or the next
    /// transcription run) picks up the new value; the audio file itself is
    /// never touched.
    func setGains(for session: Session, me: Double, remote: Double) {
        var updated = session
        updated.gains = .init(me: me, remote: remote)
        let directory = sessionStore.directory(for: session)
        try? sessionStore.save(updated, in: directory)
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index] = updated
        }
    }

    // MARK: - Settings (Q9, Q10)

    /// Q9: "저장 폴더 바꾸기" — only affects where new sessions go, existing
    /// ones stay put (SessionStore.setRootDirectory's own contract).
    func changeStorageFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = sessionStore.rootDirectory
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try sessionStore.setRootDirectory(url)
            reloadSessions()
        } catch {
            lastError = "저장 폴더 변경 실패: \(error)"
        }
    }

    /// Q10: renaming only touches session.json — the folder name (the
    /// stable ID) never changes.
    func rename(_ session: Session, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != session.displayName else { return }
        var updated = session
        updated.displayName = trimmed
        let directory = sessionStore.directory(for: session)
        try? sessionStore.save(updated, in: directory)
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index] = updated
        }
    }

    // MARK: - Transcription (steps 3-5, run from the GUI)

    private(set) var transcribingSessionID: String?
    private(set) var transcribeProgress: String?

    /// Runs the full post-recording pipeline a session needs before it's
    /// actually useful: word-level STT (step 3) -> merged transcript.txt
    /// (step 4) -> FLAC conversion + original deletion (step 5, Q3). Steps
    /// 3-5 were only reachable via CLI dev commands until now — this is the
    /// GUI entry point a normal user actually has.
    func transcribeSession(_ session: Session) {
        guard transcribingSessionID == nil else { return }
        transcribingSessionID = session.id
        transcribeProgress = "시작"
        let directory = sessionStore.directory(for: session)

        Task {
            do {
                let words = try await Transcriber.transcribe(
                    sessionDirectory: directory, locale: session.language,
                    meGain: session.gains.me, remoteGain: session.gains.remote
                ) { [weak self] message in
                    Task { @MainActor in self?.transcribeProgress = message }
                }
                let utterances = TranscriptBuilder.build(from: words)
                try TranscriptBuilder.writeTranscript(
                    utterances, to: directory.appendingPathComponent("transcript.txt")
                )
                if FileManager.default.fileExists(atPath: directory.appendingPathComponent(AudioCapture.fileName).path) {
                    transcribeProgress = "FLAC 변환 중"
                    _ = try FLACConverter.convert(sessionDirectory: directory)
                }
                lastError = nil
            } catch {
                lastError = "전사 실패: \(error)"
            }
            transcribingSessionID = nil
            transcribeProgress = nil
            reloadSessions()
        }
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
