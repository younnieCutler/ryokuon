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
    let sessionStore: SessionStore
    let permissions = PermissionsManager()
    let player = Player()
    var selectedRecordingProcessID: pid_t?
    var isShowingPermissionSetup = false
    var isShowingSettings = false
    @ObservationIgnored private let trashSession: (Session) throws -> Void

    private(set) var isRecording = false
    private(set) var meLevelDB: Float = -.infinity
    private(set) var remoteLevelDB: Float = -.infinity
    private(set) var silenceWarning: String?
    private(set) var sessions: [Session] = []
    private(set) var libraryNodes: [AudioLibraryNode] = []
    private(set) var libraryError: String?
    private(set) var libraryRevision = 0
    @ObservationIgnored private var librarySnapshot = AudioLibrarySnapshot(nodes: [], sessions: [], error: nil)
    @ObservationIgnored private var libraryWatcher: AudioLibraryWatcher?
    @ObservationIgnored private var libraryRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var libraryScanSequence = 0
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

    var language: String = UserDefaults.standard.string(forKey: "dev.ryokuon.language") ?? Transcriber.autoLanguage {
        didSet { UserDefaults.standard.set(language, forKey: "dev.ryokuon.language") }
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
        if transcribingSessionID != nil || importingFileName != nil || !exportingSessionIDs.isEmpty { return .processing }
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

    init(sessionStore: SessionStore = SessionStore(), trashSession: ((Session) throws -> Void)? = nil) {
        self.sessionStore = sessionStore
        self.trashSession = trashSession ?? { try sessionStore.trash($0) }
        // Q11: repair anything a crash left behind before the user can see
        // or touch the session list.
        let recovered = sessionStore.recoverCrashedSessions()
        if !recovered.isEmpty {
            lastError = t(.errorRecovered, recovered.count)
        }
        reloadSessions()
        libraryWatcher = AudioLibraryWatcher { [weak self] in
            Task { @MainActor in self?.scheduleLibraryRefresh() }
        }
        libraryWatcher?.start(root: sessionStore.rootDirectory)
    }

    func reloadSessions() {
        applyLibrarySnapshot(AudioLibraryScanner.scan(root: sessionStore.rootDirectory))
    }

    private func applyLibrarySnapshot(_ snapshot: AudioLibrarySnapshot) {
        if let path = playingAudioPath,
           !snapshot.containsAudio(at: path) || snapshot.audioStamp(at: path) != playingAudioStamp {
            stopPlayback()
            player.invalidateCachedAudio()
        }
        librarySnapshot = snapshot
        libraryNodes = snapshot.nodes
        sessions = snapshot.sessions
        libraryError = snapshot.error
        libraryRevision += 1
    }

    /// Coalesce bursts of filesystem events, then scan away from the UI thread.
    /// A sequence number prevents an old root's scan from replacing a newer one.
    private func scheduleLibraryRefresh() {
        libraryRefreshTask?.cancel()
        libraryScanSequence += 1
        let sequence = libraryScanSequence
        let root = sessionStore.rootDirectory
        libraryRefreshTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let snapshot = await Task.detached(priority: .utility) {
                AudioLibraryScanner.scan(root: root)
            }.value
            guard !Task.isCancelled, sequence == libraryScanSequence,
                  root == sessionStore.rootDirectory else { return }
            applyLibrarySnapshot(snapshot)
        }
    }

    func refreshLibrary() {
        scheduleLibraryRefresh()
    }

    func audioNode(at relativePath: String) -> AudioLibraryNode? {
        librarySnapshot.audioNode(at: relativePath)
    }

    func libraryNode(at relativePath: String) -> AudioLibraryNode? {
        librarySnapshot.node(at: relativePath)
    }

    func session(forAudioPath relativePath: String) -> Session? {
        let name = URL(fileURLWithPath: relativePath).lastPathComponent
        guard name == AudioCapture.fileName || name == AudioCapture.flacFileName else { return nil }
        let parent = (relativePath as NSString).deletingLastPathComponent
        return sessions.first { $0.relativePath == parent }
    }

    /// Manually chosen input device UID, overriding the system default mic
    /// at capture start — "" means "use the system default" (unset). Setting
    /// this mid-recording also switches the live capture's mic immediately
    /// (`AudioCapture.switchMicDevice`), not just the next recording's.
    var selectedMicDeviceUID: String = UserDefaults.standard.string(forKey: "dev.ryokuon.micDeviceUID") ?? "" {
        didSet {
            UserDefaults.standard.set(selectedMicDeviceUID, forKey: "dev.ryokuon.micDeviceUID")
            guard isRecording, let capture else { return }
            do {
                try capture.switchMicDevice(uid: selectedMicDeviceUID.isEmpty ? nil : selectedMicDeviceUID)
                lastError = nil
            } catch {
                // The IOProc was stopped for the switch. Finalize the recording
                // instead of showing an active timer with no input callbacks.
                stop()
                UserDefaults.standard.set(oldValue, forKey: "dev.ryokuon.micDeviceUID")
                selectedMicDeviceUID = oldValue
                lastError = t(.errorMicSwitchFailed, "\(error)")
            }
        }
    }

    /// Manually chosen playback output device UID — "" means the system
    /// default output.
    var selectedOutputDeviceUID: String = UserDefaults.standard.string(forKey: "dev.ryokuon.outputDeviceUID") ?? "" {
        didSet {
            UserDefaults.standard.set(selectedOutputDeviceUID, forKey: "dev.ryokuon.outputDeviceUID")
            guard let path = playingAudioPath, !isPlaybackPaused else { return }
            let position = playbackTime
            if let session = session(forAudioPath: path) { play(session, from: position) }
            else { playExternalAudio(at: path, from: position) }
        }
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

    func recordingTarget(in processes: [AudioProcess]) -> AudioProcess? {
        RecordingTargetSelection.choose(from: processes, selectedPID: selectedRecordingProcessID,
                                        lastBundleID: lastTargetBundleID)
    }

    func toggleRecording() {
        if isRecording { stop(); return }
        guard let target = recordingTarget(in: playingProcesses()) else {
            lastError = t(.recordTargetUnavailable)
            return
        }
        start(target: target)
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
            isShowingPermissionSetup = true
            lastError = t(.errorPermissionsIncomplete)
            return
        }

        var pendingDirectory: URL?
        do {
            let micDeviceUID = selectedMicDeviceUID.isEmpty ? nil : selectedMicDeviceUID
            let channels = CaptureDevice.isBuiltInMicActive(deviceUID: micDeviceUID) ? 1 : 2
            let (session, directory) = try sessionStore.createSession(language: language, targetBundleID: target.bundleID,
                                                                       targetDisplayName: target.displayName,
                                                                       channels: channels)
            pendingDirectory = directory
            let newCapture = try AudioCapture(process: target, outputDirectory: directory, channels: channels,
                                              micDeviceUID: micDeviceUID)

            let newWatchdog = SilenceWatchdog()
            newWatchdog.onWarning = { [weak self] meSilent, remoteSilent in
                Task { @MainActor in
                    self?.silenceWarning = SilenceWatchdog.message(meSilent: meSilent, remoteSilent: remoteSilent)
                }
            }

            newCapture.onError = { [weak self] error in
                Task { @MainActor in
                    self?.stop()
                    self?.lastError = self?.t(.errorStopFailed, "\(error)")
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
            // Capture never started, so this directory has no completed audio.
            if let pendingDirectory { try? FileManager.default.removeItem(at: pendingDirectory) }
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
            // The writer finalizes whatever reached disk even if capture failed.
            // Preserve that partial recording with a recovery badge, rather than
            // leaving an unusable recording-state row until the next launch.
            session.state = .recovered
            session.durationSeconds = Double(capture.framesWritten) / Double(WAVWriter.sampleRate)
            try? sessionStore.save(session, in: directory)
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
        if let finished = sessions.first(where: { $0.relativePath == session.relativePath }), finished.state == .finished {
            transcribeSession(finished)
        }
    }

    // MARK: - Playback (step 5, Q4)

    private(set) var playingAudioPath: String?
    private(set) var isPlaybackPaused = false
    @ObservationIgnored private var playingAudioStamp: AudioFileStamp?
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
        let relativeAudioPath = session.relativePath + "/" + url.lastPathComponent
        playAudio(at: url, relativePath: relativeAudioPath, from: from,
                  meGain: session.gains.me, remoteGain: session.gains.remote)
    }

    func playExternalAudio(at relativePath: String, from: TimeInterval = 0) {
        guard librarySnapshot.containsAudio(at: relativePath) else {
            lastError = t(.errorNoAudioFile)
            return
        }
        let url = sessionStore.rootDirectory.appendingPathComponent(relativePath)
        playAudio(at: url, relativePath: relativePath, from: from, meGain: 1, remoteGain: 1)
    }

    private func playAudio(at url: URL, relativePath: String, from: TimeInterval,
                           meGain: Double, remoteGain: Double) {
        stopPlayback()
        do {
            player.onFinish = { [weak self] in
                self?.playbackTime = self?.player.duration ?? 0
                self?.isPlaybackPaused = true
                self?.stopPlaybackTimer()
            }
            player.onError = { [weak self] error in
                self?.stopPlayback()
                self?.lastError = self?.t(.errorPlayFailed, "\(error)")
            }
            player.outputDeviceUID = selectedOutputDeviceUID.isEmpty ? nil : selectedOutputDeviceUID
            try player.play(url: url, from: from, meGain: meGain, remoteGain: remoteGain)
            playingAudioPath = relativePath
            playingAudioStamp = librarySnapshot.audioStamp(at: relativePath)
            playbackTime = from
            isPlaybackPaused = false
            lastError = nil
            startPlaybackTimer()
        } catch {
            lastError = t(.errorPlayFailed, "\(error)")
        }
    }

    /// Jumps playback to a transcript line's timestamp — reuses `play(_:from:)`,
    /// which is cheap here since `Player` caches the decoded buffer per URL
    /// and only re-reads from disk when the URL changes.
    func seekPlayback(_ session: Session, toSeconds seconds: TimeInterval) {
        guard seconds.isFinite else { return }
        let position = min(max(seconds, 0), max(0, session.durationSeconds - 0.01))
        if playingAudioPath?.hasPrefix(session.relativePath + "/") == true, isPlaybackPaused {
            playbackTime = position
        } else {
            play(session, from: position)
        }
    }

    func pausePlayback() {
        guard playingAudioPath != nil, !isPlaybackPaused else { return }
        playbackTime = min(max(player.currentTime, 0), player.duration)
        player.stop()
        isPlaybackPaused = true
        stopPlaybackTimer()
    }

    func togglePlayback(_ session: Session) {
        guard session.state != .recording else { return }
        let isCurrent = playingAudioPath?.hasPrefix(session.relativePath + "/") == true
        if isCurrent && !isPlaybackPaused { pausePlayback(); return }
        let position = isCurrent && playbackTime < player.duration ? playbackTime : 0
        play(session, from: position)
    }

    func toggleExternalPlayback(at path: String) {
        let isCurrent = playingAudioPath == path
        if isCurrent && !isPlaybackPaused { pausePlayback(); return }
        let position = isCurrent && playbackTime < player.duration ? playbackTime : 0
        playExternalAudio(at: path, from: position)
    }

    func seekExternalPlayback(at path: String, toSeconds seconds: TimeInterval, duration: TimeInterval) {
        guard seconds.isFinite, duration.isFinite else { return }
        let position = min(max(seconds, 0), max(0, duration - 0.01))
        if playingAudioPath == path && isPlaybackPaused {
            playbackTime = position
        } else {
            playExternalAudio(at: path, from: position)
        }
    }

    func stopPlayback() {
        player.stop()
        playingAudioPath = nil
        playingAudioStamp = nil
        isPlaybackPaused = false
        playbackTime = 0
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

    /// Apply saved gains to playback without changing the original audio.
    func setGains(for session: Session, me: Double, remote: Double) {
        guard persist(session, change: { $0.gains = .init(me: me, remote: remote) }) else { return }
        if playingAudioPath?.hasPrefix(session.relativePath + "/") == true, !isPlaybackPaused,
           let updated = sessions.first(where: { $0.relativePath == session.relativePath }) {
            play(updated, from: playbackTime)
        }
    }

    /// Always mutate fresh metadata, and publish only a successful disk write.
    @discardableResult
    private func persist(_ session: Session, change: (inout Session) -> Void) -> Bool {
        do {
            let directory = sessionStore.directory(for: session)
            var updated = try sessionStore.load(from: directory)
            change(&updated)
            try sessionStore.save(updated, in: directory)
            if let index = sessions.firstIndex(where: { $0.relativePath == session.relativePath }) { sessions[index] = updated }
            lastError = nil
            return true
        } catch {
            lastError = t(.errorMetadataSaveFailed, "\(error)")
            return false
        }
    }

    var canChangeStorageFolder: Bool {
        !isRecording && transcribingSessionID == nil && importingFileName == nil && exportingSessionIDs.isEmpty
    }

    func canDelete(_ session: Session) -> Bool {
        session.relativePath != currentSession?.relativePath
            && session.relativePath != transcribingSessionID && !exportingSessionIDs.contains(session.relativePath)
    }

    func canExport(_ session: Session) -> Bool {
        session.state != .recording && session.relativePath != transcribingSessionID
            && !isQueuedForTranscription(session.relativePath) && !exportingSessionIDs.contains(session.relativePath)
    }

    // MARK: - Settings (Q9, Q10)

    /// Q9: "저장 폴더 바꾸기" — only affects where new sessions go, existing
    /// ones stay put (SessionStore.setRootDirectory's own contract).
    func changeStorageFolder() {
        guard canChangeStorageFolder else { lastError = t(.errorOperationBusy); return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = sessionStore.rootDirectory
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard canChangeStorageFolder else { lastError = t(.errorOperationBusy); return }
        do {
            try sessionStore.setRootDirectory(url)
            stopPlayback()
            libraryRefreshTask?.cancel()
            libraryScanSequence += 1
            libraryWatcher?.start(root: url)
            reloadSessions()
        } catch {
            lastError = t(.errorStorageChangeFailed, "\(error)")
        }
    }

    /// Q10: renaming only touches session.json — the folder name (the
    /// stable ID) never changes.
    @discardableResult
    func rename(_ session: Session, to newName: String) -> Bool {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard trimmed != session.displayName else { return true }
        return persist(session) { $0.displayName = trimmed }
    }

    /// Refuse the whole selection if a background writer owns any session.
    @discardableResult
    func delete(_ ids: Set<String>) -> Bool {
        let selected = sessions.filter { ids.contains($0.relativePath) }
        guard selected.allSatisfy({ canDelete($0) }) else {
            lastError = t(.errorOperationBusy)
            return false
        }
        var succeeded = true
        for session in selected {
            if playingAudioPath?.hasPrefix(session.relativePath + "/") == true { stopPlayback() }
            do {
                try trashSession(session)
                transcribeQueue.removeAll { $0 == session.relativePath }
            } catch {
                succeeded = false
                lastError = t(.errorDeleteFailed, "\(session.displayName): \(error)")
            }
        }
        reloadSessions()
        return succeeded
    }

    var hasActiveWork: Bool { !canChangeStorageFolder || !transcribeQueue.isEmpty }

    func cancelQueuedTranscription(_ session: Session) {
        transcribeQueue.removeAll { $0 == session.relativePath }
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
        guard session.state != .recording, session.relativePath != transcribingSessionID,
              !exportingSessionIDs.contains(session.relativePath) else { return }
        var session = session
        // Picking a language from the menu sticks to the session (session.json)
        // — a later re-run and a queued run both use it.
        if let newLanguage, newLanguage != session.language {
            guard setLanguage(for: session, to: newLanguage) else { return }
            session.language = newLanguage
        }
        guard transcribingSessionID == nil else {
            if !transcribeQueue.contains(session.relativePath) { transcribeQueue.append(session.relativePath) }
            return
        }
        transcribingSessionID = session.relativePath
        transcribeProgress = t(.progressStarting)
        let directory = sessionStore.directory(for: session)

        Task {
            do {
                var locale = session.language
                if locale == Transcriber.autoLanguage {
                    transcribeProgress = t(.progressDetectingLanguage)
                    locale = try await Transcriber.detectLanguage(sessionDirectory: directory)
                    // Saved, so the header shows what was detected and ▾ can override it.
                    if let current = sessions.first(where: { $0.relativePath == session.relativePath }) {
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
                    _ = try await Task.detached { try FLACConverter.convert(sessionDirectory: directory) }.value
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
                if let next = sessions.first(where: { $0.relativePath == nextID }) { // skip ones deleted while waiting
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
    @discardableResult
    func setLanguage(for session: Session, to language: String) -> Bool {
        persist(session) { $0.language = language }
    }

    func languageName(_ id: String) -> String {
        AppState.supportedLanguages.first { $0.id == id }.map { t($0.labelKey) } ?? id
    }

    // MARK: - Import / export (M4A-to-MP3.html features, 2026-10-02)

    func presentImportPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.mpeg4Audio, .mp3, .wav]
            + [UTType(filenameExtension: "flac")].compactMap { $0 }
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        importAudio(panel.urls)
    }

    /// Import -> new session -> transcription queued automatically, so a
    /// dropped voice memo ends up in the same state as a finished recording.
    /// File currently being decoded — long m4a files take a few seconds
    /// and the sidebar shows this instead of looking frozen.
    private(set) var importingFileName: String?

    private var pendingImports: [(url: URL, language: String)] = []

    func importAudio(_ urls: [URL]) {
        pendingImports.append(contentsOf: urls.map { ($0, language) })
        guard importingFileName == nil, let first = pendingImports.first else { return }
        // Claim the worker before scheduling it: a second drop joins this queue.
        importingFileName = first.url.lastPathComponent
        let root = sessionStore.rootDirectory
        Task {
            defer { importingFileName = nil }
            while !pendingImports.isEmpty {
                let item = pendingImports.removeFirst()
                importingFileName = item.url.lastPathComponent
                do {
                    let session = try await Task.detached {
                        try AudioImporter.importFile(item.url, store: SessionStore(rootDirectory: root), language: item.language)
                    }.value
                    reloadSessions()
                    transcribeSession(session)
                } catch {
                    lastError = t(.errorImportFailed, "\(item.url.lastPathComponent): \(error)")
                }
            }
        }
    }

    private(set) var exportingSessionIDs: Set<String> = []

    /// Writes the selected range as MP3 and/or analysis MD into the session
    /// folder, then shows the result in Finder.
    func export(_ session: Session, range: ClosedRange<Double>, bitrate: Int, mono: Bool,
                mp3: Bool, markdown: Bool, destination: URL? = nil, allowOverwrite: Bool = false) async -> Bool {
        guard canExport(session), mp3 || markdown else {
            lastError = t(.errorOperationBusy)
            return false
        }
        guard range.lowerBound.isFinite, range.upperBound.isFinite,
              range.lowerBound >= 0, range.upperBound > range.lowerBound,
              range.upperBound <= session.durationSeconds,
              range.upperBound < Double(Int.max) / 1000 else {
            lastError = t(.errorExportFailed, "\(MP3ExporterError.invalidRange)")
            return false
        }
        exportingSessionIDs.insert(session.relativePath)
        defer { exportingSessionIDs.remove(session.relativePath) }
        let directory = sessionStore.directory(for: session)
        let isFull = range.lowerBound <= 0 && range.upperBound >= session.durationSeconds
        var written: [URL] = []
        do {
            let plan = try SessionExportPlan(session: session, range: range, directory: destination ?? directory,
                                             mp3: mp3, markdown: markdown)
            guard allowOverwrite || plan.existingURLs.isEmpty else {
                lastError = t(.errorExportExists)
                return false
            }
            // Read the transcript before starting the encoder: a missing text file
            // must not leave an MP3 behind from an otherwise invalid combined job.
            let transcript = markdown
                ? try String(contentsOf: directory.appendingPathComponent("transcript.txt"), encoding: .utf8) : nil
            if mp3 {
                guard let audioURL = AudioCapture.audioFileURL(in: directory) else { throw MP3ExporterError.noAudio }
                guard let mp3URL = plan.mp3URL else { throw MP3ExporterError.invalidRange }
                let gains = session.gains
                try await Task.detached {
                    try MP3Exporter.export(from: audioURL, range: range, gains: gains, bitrate: bitrate,
                                           mono: mono, to: mp3URL)
                }.value
                written.append(mp3URL)
            }
            if markdown {
                guard let text = transcript, let mdURL = plan.markdownURL else { throw MP3ExporterError.invalidRange }
                let md = TranscriptBuilder.markdown(
                    TranscriptBuilder.parse(text), title: session.displayName, createdAt: session.createdAt,
                    durationSeconds: session.durationSeconds, language: session.language,
                    rangeMs: isFull ? nil : Int(range.lowerBound * 1000) ... Int(range.upperBound * 1000)
                )
                try md.write(to: mdURL, atomically: true, encoding: .utf8)
                written.append(mdURL)
            }
            lastError = nil
            NSWorkspace.shared.activateFileViewerSelecting(written)
            return true
        } catch {
            lastError = t(.errorExportFailed, "\(error)")
            return false
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
