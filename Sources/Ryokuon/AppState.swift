import AppKit
import AVFoundation
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
    static let supportedLanguages: [(id: String, labelKey: L10nKey)] = [
        ("ja-JP", .langJa), ("ko-KR", .langKo), ("en-US", .langEn),
    ]

    var language: String {
        get { UserDefaults.standard.string(forKey: "dev.ryokuon.language") ?? "ja-JP" }
        set { UserDefaults.standard.set(newValue, forKey: "dev.ryokuon.language") }
    }

    /// UI language — independent of `language` (the STT transcription
    /// target). Needs to be an `@Observable`-tracked *stored* property, not
    /// a computed pass-through to UserDefaults like `language` above: every
    /// screen's `t(...)` calls read this, and a computed property reading
    /// UserDefaults directly gives SwiftUI nothing to observe, so changing
    /// it in Settings wouldn't re-render anything already on screen.
    var appLanguage: String = UserDefaults.standard.string(forKey: "dev.ryokuon.appLanguage")
        ?? Localization.defaultLanguage()
    {
        didSet { UserDefaults.standard.set(appLanguage, forKey: "dev.ryokuon.appLanguage") }
    }

    func t(_ key: L10nKey) -> String { Localization.string(key, language: appLanguage) }
    func t(_ key: L10nKey, _ argument: String) -> String {
        String(format: Localization.string(key, language: appLanguage), argument)
    }
    func t(_ key: L10nKey, _ argument: Int) -> String {
        String(format: Localization.string(key, language: appLanguage), argument)
    }

    enum RunState { case ready, recording, processing }

    /// For the "Ready / Recording / Processing" status the menu bar and
    /// window both need — a session is "processing" the moment its
    /// transcription pipeline (step 3-5) is running.
    var runState: RunState {
        if isRecording { return .recording }
        if transcribingSessionID != nil { return .processing }
        return .ready
    }

    func runStateText() -> String {
        switch runState {
        case .ready: t(.statusReady)
        case .recording: t(.statusRecording)
        case .processing: t(.statusProcessing)
        }
    }

    private var capture: AudioCapture?
    private var watchdog: SilenceWatchdog?
    private var currentDirectory: URL?
    private var currentSession: Session?
    private var lastTickDate: Date?

    /// Elapsed recording time, polled the same way `playbackTime` is —
    /// drives the duration readout in the menu bar and the window's
    /// recording indicator.
    private(set) var recordingElapsed: TimeInterval = 0
    private var recordingStartDate: Date?
    private var recordingTimer: Timer?

    init() {
        // Q11: repair anything a crash left behind before the user can see
        // or touch the session list.
        let recovered = sessionStore.recoverCrashedSessions()
        if !recovered.isEmpty {
            lastError = t(.errorRecovered, recovered.count)
        }
        reloadSessions()
    }

    func reloadSessions() {
        sessions = sessionStore.listSessions()
    }

    /// System default input device's name, for display only ("현재 선택된
    /// 마이크"). Read-only query — doesn't touch `CaptureDevice`/
    /// `AudioCapture`, which resolve their own input at capture start
    /// exactly as before; this is purely a label.
    var currentMicrophoneName: String {
        AVCaptureDevice.default(for: .audio)?.localizedName ?? "—"
    }

    /// Apps currently making sound, for the "pick another app" submenu.
    func playingProcesses() -> [AudioProcess] {
        (try? listAudioProcesses().filter(\.isPlaying)) ?? []
    }

    func startWithLastTarget() {
        guard let bundleID = lastTargetBundleID,
              let process = (try? listAudioProcesses())?.first(where: { $0.bundleID == bundleID })
        else {
            lastError = t(.errorLastTargetNotRunning, lastTargetDisplayName ?? "?")
            return
        }
        start(target: process)
    }

    func start(target: AudioProcess) {
        guard !isRecording else { return }
        guard permissions.allGranted else {
            lastError = t(.errorPermissionsIncomplete)
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
            recordingStartDate = Date()
            recordingElapsed = 0
            startRecordingTimer()
        } catch {
            lastError = t(.errorStartFailed, "\(error)")
        }
    }

    private func startRecordingTimer() {
        recordingTimer?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let start = self.recordingStartDate else { return }
                self.recordingElapsed = Date().timeIntervalSince(start)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        recordingTimer = timer
    }

    func stop() {
        guard isRecording, let capture, var session = currentSession, let directory = currentDirectory else { return }
        do {
            try capture.stop()
            session.state = .finished
            session.durationSeconds = Double(capture.framesWritten) / Double(WAVWriter.sampleRate)
            try sessionStore.save(session, in: directory)
        } catch {
            lastError = t(.errorStopFailed, "\(error)")
        }

        self.capture = nil
        watchdog = nil
        currentDirectory = nil
        currentSession = nil
        lastTickDate = nil
        isRecording = false
        meLevelDB = -.infinity
        remoteLevelDB = -.infinity
        recordingTimer?.invalidate()
        recordingTimer = nil
        recordingStartDate = nil
        recordingElapsed = 0
        reloadSessions()
    }

    // MARK: - Playback (step 5, Q4)

    private(set) var playingSessionID: String?
    /// Current position within the playing file, in seconds — polled from
    /// `player.currentTime` on a timer since `Player` isn't itself
    /// `@Observable`. Drives the transcript's current-line highlight and
    /// the compact player's position readout.
    private(set) var playbackTime: TimeInterval = 0
    private var playbackTimer: Timer?

    var playbackDuration: TimeInterval { player.duration }

    func play(_ session: Session, from: TimeInterval = 0) {
        let directory = sessionStore.directory(for: session)
        guard let url = AudioCapture.audioFileURL(in: directory) else {
            lastError = t(.errorNoAudioFile)
            return
        }
        do {
            player.onFinish = { [weak self] in
                self?.playingSessionID = nil
                self?.stopPlaybackTimer()
            }
            try player.play(url: url, from: from, meGain: session.gains.me, remoteGain: session.gains.remote)
            playingSessionID = session.id
            playbackTime = from
            startPlaybackTimer()
        } catch {
            lastError = t(.errorPlayFailed, "\(error)")
        }
    }

    /// Jumps playback to a transcript line's timestamp — reuses `play(_:from:)`,
    /// which is cheap here since `Player` caches the decoded buffer per URL
    /// and only re-reads from disk when the URL changes.
    func seekPlayback(_ session: Session, toSeconds seconds: TimeInterval) {
        play(session, from: seconds)
    }

    func stopPlayback() {
        player.stop()
        playingSessionID = nil
        stopPlaybackTimer()
    }

    private func startPlaybackTimer() {
        playbackTimer?.invalidate()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.playbackTime = self?.player.currentTime ?? 0 }
        }
        RunLoop.main.add(timer, forMode: .common)
        playbackTimer = timer
    }

    private func stopPlaybackTimer() {
        playbackTimer?.invalidate()
        playbackTimer = nil
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
            lastError = t(.errorStorageChangeFailed, "\(error)")
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

    /// Permanently deletes the given sessions (edit-mode multi-select or a
    /// single row's "..." menu both funnel through here).
    func delete(_ ids: Set<String>) {
        for session in sessions where ids.contains(session.id) {
            sessionStore.delete(session)
        }
        reloadSessions()
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
        transcribeProgress = t(.progressStarting)
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
                    transcribeProgress = t(.progressConvertingFLAC)
                    _ = try FLACConverter.convert(sessionDirectory: directory)
                }
                lastError = nil
            } catch {
                lastError = t(.errorTranscribeFailed, "\(error)")
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
