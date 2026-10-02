import AppKit
import AVFoundation
import CoreAudio
import Foundation
import SwiftUI
import UniformTypeIdentifiers

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
        (Transcriber.autoLanguage, .langAuto), ("ja-JP", .langJa), ("ko-KR", .langKo), ("en-US", .langEn),
    ]

    var language: String {
        get { UserDefaults.standard.string(forKey: "dev.ryokuon.language") ?? Transcriber.autoLanguage }
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

    /// Manually chosen input device UID, overriding the system default mic
    /// at capture start — "" means "use the system default" (unset). Setting
    /// this mid-recording also switches the live capture's mic immediately
    /// (`AudioCapture.switchMicDevice`), not just the next recording's.
    var selectedMicDeviceUID: String {
        get { UserDefaults.standard.string(forKey: "dev.ryokuon.micDeviceUID") ?? "" }
        set {
            UserDefaults.standard.set(newValue, forKey: "dev.ryokuon.micDeviceUID")
            guard isRecording, let capture else { return }
            do {
                try capture.switchMicDevice(uid: newValue.isEmpty ? nil : newValue)
                lastError = nil
            } catch {
                lastError = t(.errorMicSwitchFailed, "\(error)")
            }
        }
    }

    /// Manually chosen playback output device UID — "" means the system
    /// default output.
    var selectedOutputDeviceUID: String {
        get { UserDefaults.standard.string(forKey: "dev.ryokuon.outputDeviceUID") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "dev.ryokuon.outputDeviceUID") }
    }

    func availableInputDevices() -> [AudioIODevice] { listInputDevices() }
    func availableOutputDevices() -> [AudioIODevice] { listOutputDevices() }

    /// Name of the mic actually in effect for the next recording — the
    /// manual override if set and still connected, else the system default
    /// input, for display only ("현재 선택된 마이크").
    var currentMicrophoneName: String {
        if !selectedMicDeviceUID.isEmpty,
           let id = deviceID(forUID: selectedMicDeviceUID),
           let name = caReadString(id, kAudioObjectPropertyName)
        {
            return name
        }
        return AVCaptureDevice.default(for: .audio)?.localizedName ?? "—"
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
            let micDeviceUID = selectedMicDeviceUID.isEmpty ? nil : selectedMicDeviceUID
            let channels = CaptureDevice.isBuiltInMicActive(deviceUID: micDeviceUID) ? 1 : 2
            let (session, directory) = try sessionStore.createSession(language: language, targetBundleID: target.bundleID,
                                                                       targetDisplayName: target.displayName,
                                                                       channels: channels)
            let newCapture = try AudioCapture(process: target, outputDirectory: directory, channels: channels,
                                              micDeviceUID: micDeviceUID)

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
        // Same flow as an imported file: a finished recording goes straight to text.
        if let finished = sessions.first(where: { $0.id == session.id }), finished.state == .finished {
            transcribeSession(finished)
        }
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
            player.outputDeviceUID = selectedOutputDeviceUID.isEmpty ? nil : selectedOutputDeviceUID
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
    func transcribeSession(_ session: Session, language newLanguage: String? = nil) {
        // call.wav is still being written while recording — nothing to read yet.
        guard session.state != .recording else { return }
        var session = session
        // Picking a language from the menu sticks to the session (session.json)
        // — a later re-run and a queued run both use it.
        if let newLanguage, newLanguage != session.language {
            setLanguage(for: session, to: newLanguage)
            session.language = newLanguage
        }
        guard transcribingSessionID == nil else {
            if !transcribeQueue.contains(session.id) { transcribeQueue.append(session.id) }
            return
        }
        transcribingSessionID = session.id
        transcribeProgress = t(.progressStarting)
        let directory = sessionStore.directory(for: session)

        Task {
            do {
                var locale = session.language
                if locale == Transcriber.autoLanguage {
                    transcribeProgress = t(.progressDetectingLanguage)
                    locale = try await Transcriber.detectLanguage(sessionDirectory: directory)
                    // Saved, so the header shows what was detected and ▾ can override it.
                    if let current = sessions.first(where: { $0.id == session.id }) {
                        setLanguage(for: current, to: locale)
                    }
                }
                let words = try await Transcriber.transcribe(
                    sessionDirectory: directory, locale: locale,
                    meGain: session.gains.me, remoteGain: session.gains.remote
                ) { [weak self] message in
                    Task { @MainActor in self?.transcribeProgress = self?.localizedProgress(message) }
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
            while !transcribeQueue.isEmpty {
                let nextID = transcribeQueue.removeFirst()
                if let next = sessions.first(where: { $0.id == nextID }) { // skip ones deleted while waiting
                    transcribeSession(next)
                    break
                }
            }
        }
    }

    /// Sessions waiting for the one-at-a-time transcription slot (several
    /// imported files, or "전사하기" pressed on another session mid-run).
    private var transcribeQueue: [String] = []

    func isQueuedForTranscription(_ id: String) -> Bool { transcribeQueue.contains(id) }

    /// Transcriber reports plain English (the CLI prints it as-is); the
    /// window shows it in the UI language. "transcribing" alone adds
    /// nothing under a "변환하는 중" title, so it maps to nil.
    private func localizedProgress(_ message: String) -> String? {
        switch message {
        case "transcribing": return nil
        case "detecting language": return t(.progressDetectingLanguage)
        case "transcribing me track": return t(.progressMeTrack)
        case "transcribing remote track": return t(.progressRemoteTrack)
        default:
            guard message.hasPrefix("downloading speech model"),
                  let percent = message.split(separator: "(").last?.dropLast()
            else { return message }
            return t(.progressDownloadingModel, String(percent))
        }
    }

    /// Changes which language the next conversion of this session uses.
    func setLanguage(for session: Session, to language: String) {
        var updated = session
        updated.language = language
        try? sessionStore.save(updated, in: sessionStore.directory(for: session))
        if let index = sessions.firstIndex(where: { $0.id == session.id }) { sessions[index] = updated }
    }

    func languageName(_ id: String) -> String {
        AppState.supportedLanguages.first { $0.id == id }.map { t($0.labelKey) } ?? id
    }

    // MARK: - Import / export (M4A-to-MP3.html features, 2026-10-02)

    func presentImportPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.mpeg4Audio, .mp3, .wav]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        importAudio(panel.urls)
    }

    /// Import -> new session -> transcription queued automatically, so a
    /// dropped voice memo ends up in the same state as a finished recording.
    /// File currently being decoded — long m4a files take a few seconds
    /// and the sidebar shows this instead of looking frozen.
    private(set) var importingFileName: String?

    func importAudio(_ urls: [URL]) {
        let root = sessionStore.rootDirectory
        let language = language
        Task {
            for url in urls {
                importingFileName = url.lastPathComponent
                do {
                    let session = try await Task.detached {
                        try AudioImporter.importFile(url, store: SessionStore(rootDirectory: root), language: language)
                    }.value
                    reloadSessions()
                    transcribeSession(session)
                } catch {
                    lastError = t(.errorImportFailed, "\(url.lastPathComponent): \(error)")
                }
            }
            importingFileName = nil
        }
    }

    /// Writes the selected range as MP3 and/or analysis MD into the session
    /// folder, then shows the result in Finder.
    func export(_ session: Session, range: ClosedRange<Double>, bitrate: Int, mono: Bool,
                mp3: Bool, markdown: Bool) async {
        let directory = sessionStore.directory(for: session)
        let isFull = range.lowerBound <= 0 && range.upperBound >= session.durationSeconds
        let suffix = isFull ? "" : "_\(Self.fileTime(range.lowerBound))-\(Self.fileTime(range.upperBound))"
        let base = directory.appendingPathComponent(session.displayName.replacingOccurrences(of: "/", with: "-") + suffix)
        var written: [URL] = []
        do {
            if mp3 {
                guard let audioURL = AudioCapture.audioFileURL(in: directory) else { throw MP3ExporterError.noAudio }
                let mp3URL = base.appendingPathExtension("mp3")
                let gains = session.gains
                try await Task.detached {
                    try MP3Exporter.export(from: audioURL, range: range, gains: gains, bitrate: bitrate,
                                           mono: mono, to: mp3URL)
                }.value
                written.append(mp3URL)
            }
            if markdown {
                let text = try String(contentsOf: directory.appendingPathComponent("transcript.txt"), encoding: .utf8)
                let md = TranscriptBuilder.markdown(
                    TranscriptBuilder.parse(text), title: session.displayName, createdAt: session.createdAt,
                    durationSeconds: session.durationSeconds, language: session.language,
                    rangeMs: isFull ? nil : Int(range.lowerBound * 1000) ... Int(range.upperBound * 1000)
                )
                let mdURL = base.appendingPathExtension("md")
                try md.write(to: mdURL, atomically: true, encoding: .utf8)
                written.append(mdURL)
            }
            lastError = nil
            NSWorkspace.shared.activateFileViewerSelecting(written)
        } catch {
            lastError = t(.errorExportFailed, "\(error)")
        }
    }

    /// `1:05` isn't filename-safe on every tool that touches the file — `0105`.
    private static func fileTime(_ seconds: Double) -> String {
        let total = Int(seconds)
        return String(format: "%02d%02d", total / 60, total % 60)
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
