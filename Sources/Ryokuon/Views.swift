import SwiftUI

struct MainWindowView: View {
    let appState: AppState

    var body: some View {
        Group {
            if appState.permissions.allGranted {
                RyokuonSplitView(appState: appState)
            } else {
                OnboardingView(appState: appState)
            }
        }
        .frame(minWidth: 720, minHeight: 440)
    }
}

// MARK: - Onboarding (System Settings-style permission list)

/// Q14: one permission at a time, each with a one-line explanation before
/// the system prompt appears.
struct OnboardingView: View {
    let appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: RTheme.Spacing.lg) {
            VStack(alignment: .leading, spacing: RTheme.Spacing.xs) {
                Text(appState.t(.onboardingTitle)).font(.title2.bold())
                Text(appState.t(.onboardingSubtitle)).font(.callout).foregroundStyle(.secondary)
            }

            VStack(spacing: 0) {
                PermissionRow(
                    icon: "mic",
                    title: appState.t(.permMicTitle),
                    explanation: appState.t(.permMicExplanation),
                    status: appState.permissions.microphone,
                    statusText: statusText(for: appState.permissions.microphone),
                    buttonTitle: appState.t(.permRequestButton)
                ) {
                    Task { await appState.permissions.requestMicrophone() }
                }
                Divider().padding(.leading, 44)
                PermissionRow(
                    icon: "waveform",
                    title: appState.t(.permCaptureTitle),
                    explanation: appState.t(.permCaptureExplanation),
                    status: appState.permissions.audioCapture,
                    statusText: statusText(for: appState.permissions.audioCapture),
                    buttonTitle: appState.t(.permRequestButton)
                ) {
                    appState.permissions.requestAudioCapture()
                }
                Divider().padding(.leading, 44)
                PermissionRow(
                    icon: "folder",
                    title: appState.t(.permFolderTitle),
                    explanation: appState.t(.permFolderExplanation, appState.sessionStore.rootDirectory.path),
                    status: appState.permissions.documentsFolder,
                    statusText: statusText(for: appState.permissions.documentsFolder),
                    buttonTitle: appState.t(.permRequestButton)
                ) {
                    appState.permissions.requestDocumentsAccess(root: appState.sessionStore.rootDirectory)
                }
            }
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))

            Spacer()
        }
        .padding(RTheme.Spacing.xl)
    }

    private func statusText(for status: PermissionsManager.Status) -> String {
        switch status {
        case .granted: appState.t(.statusGranted)
        case .denied: appState.t(.statusDenied)
        case .notDetermined: appState.t(.statusNotDetermined)
        }
    }
}

private struct PermissionRow: View {
    let icon: String
    let title: String
    let explanation: String
    let status: PermissionsManager.Status
    let statusText: String
    let buttonTitle: String
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: RTheme.Spacing.md) {
            Image(systemName: icon)
                .frame(width: 20)
                .foregroundStyle(.secondary)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body)
                Text(explanation).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if status == .granted {
                Label(statusText, systemImage: "checkmark.circle.fill")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.secondary)
            } else {
                Button(buttonTitle) { action() }
                    .controlSize(.small)
            }
        }
        .padding(RTheme.Spacing.md)
    }
}

// MARK: - Main split view (sidebar: sessions, detail: transcript + player)

struct RyokuonSplitView: View {
    let appState: AppState
    @State private var selection: String?
    @State private var showingSettings = false

    var body: some View {
        NavigationSplitView {
            SessionSidebar(appState: appState, selection: $selection)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            if let session = appState.sessions.first(where: { $0.id == selection }) {
                SessionDetailPane(appState: appState, session: session)
            } else {
                ContentUnavailableView(appState.t(.detailNoSelection), systemImage: "waveform")
            }
        }
        .onAppear { appState.reloadSessions() }
        .toolbar {
            ToolbarItem {
                Button { showingSettings = true } label: {
                    Image(systemName: "gearshape")
                }
                .help(appState.t(.settingsTitle))
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsSheetView(appState: appState)
        }
    }
}

private struct SessionSidebar: View {
    let appState: AppState
    @Binding var selection: String?
    @State private var searchText = ""

    private var filteredSessions: [Session] {
        guard !searchText.isEmpty else { return appState.sessions }
        return appState.sessions.filter { $0.displayName.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        VStack(spacing: 0) {
            if appState.sessions.isEmpty && !appState.isRecording {
                ContentUnavailableView(appState.t(.emptyTitle), systemImage: "waveform",
                                       description: Text(appState.t(.emptySubtitle)))
            } else {
                List(filteredSessions, id: \.id, selection: $selection) { session in
                    SessionRow(session: session).tag(session.id)
                }
                .listStyle(.sidebar)
                .searchable(text: $searchText, placement: .sidebar, prompt: appState.t(.searchPlaceholder))
            }
            if let error = appState.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(RTheme.Spacing.sm)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            RecordingControlBar(appState: appState)
        }
    }
}

private struct SessionRow: View {
    let session: Session

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: RTheme.Spacing.xs) {
                Text(session.displayName)
                if session.state == .recovered {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            Text("\(session.targetDisplayName) · \(formattedDuration(session.durationSeconds))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

func formattedDuration(_ seconds: Double) -> String {
    let total = Int(seconds)
    return String(format: "%d:%02d", total / 60, total % 60)
}

/// Priority #1: recording start/stop is the one control that must always
/// be obvious — pinned at the bottom of the sidebar (Voice Memos' own
/// pattern) rather than buried in a toolbar menu. Collapses to just the
/// state + meters + stop button while recording (priority #4: no
/// unnecessary UI while recording — the app picker disappears).
private struct RecordingControlBar: View {
    let appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: RTheme.Spacing.sm) {
            if appState.isRecording {
                HStack(spacing: RTheme.Spacing.sm) {
                    RecordingDot()
                    Text(appState.t(.statusRecording)).font(.callout.weight(.medium))
                    Spacer()
                    Text(appState.lastTargetDisplayName ?? "").font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: RTheme.Spacing.lg) {
                    LevelMeter(label: appState.t(.gainMe), tint: .accentColor, db: appState.meLevelDB)
                    LevelMeter(label: appState.t(.gainRemote), tint: .secondary, db: appState.remoteLevelDB)
                }
                if let warning = appState.silenceWarning, !warning.isEmpty {
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Button(role: .destructive) {
                    appState.stop()
                } label: {
                    Label(appState.t(.recordingStop), systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
            } else {
                HStack(spacing: RTheme.Spacing.xs) {
                    Image(systemName: "mic").foregroundStyle(.secondary)
                    Text(appState.currentMicrophoneName).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                if let name = appState.lastTargetDisplayName {
                    Button {
                        appState.startWithLastTarget()
                    } label: {
                        Label(appState.t(.startRecordingWithName, name), systemImage: "record.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .tint(.red)
                }
                let processes = appState.playingProcesses()
                if !processes.isEmpty {
                    Menu(appState.lastTargetDisplayName == nil ? appState.t(.startRecording) : appState.t(.pickAnotherApp)) {
                        ForEach(processes) { process in
                            Button(process.displayName) { appState.start(target: process) }
                        }
                    }
                    .controlSize(.regular)
                } else if appState.lastTargetDisplayName == nil {
                    Text(appState.t(.noSoundApps))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(RTheme.Spacing.md)
    }
}

struct RecordingDot: View {
    @State private var pulse = false

    var body: some View {
        Circle().fill(.red).frame(width: 7, height: 7)
            .opacity(pulse ? 0.35 : 1)
            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
            .onAppear { pulse = true }
    }
}

/// Q18's level meter — thin native-style track, no rounded-pill/gradient
/// styling. ME reads in the system accent color (the "primary" side),
/// REMOTE in secondary gray, matching how System Settings distinguishes a
/// selected vs. unselected row rather than introducing a second brand hue.
struct LevelMeter: View {
    let label: String
    let tint: Color
    let db: Float

    private var normalized: Double {
        Double(max(0, min(1, (db + 60) / 60)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            GeometryReader { geo in
                RoundedRectangle(cornerRadius: RTheme.meterCornerRadius)
                    .fill(.quaternary)
                    .overlay(alignment: .leading) {
                        RoundedRectangle(cornerRadius: RTheme.meterCornerRadius)
                            .fill(tint)
                            .frame(width: max(2, geo.size.width * normalized))
                    }
            }
            .frame(height: 5)
        }
        .frame(width: 96)
    }
}

// MARK: - Settings (separate sheet, kept off the main screen — priority #6)

/// Q7(전사 언어) + 앱 언어 + Q9(저장 폴더) — 전부 System Settings 스타일 Form.
struct SettingsSheetView: View {
    let appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var transcriptionLanguage: String
    @State private var appLanguage: String

    init(appState: AppState) {
        self.appState = appState
        _transcriptionLanguage = State(initialValue: appState.language)
        _appLanguage = State(initialValue: appState.appLanguage)
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(appState.t(.settingsTitle)).font(.title3.bold()).padding(RTheme.Spacing.lg)
            Divider()

            Form {
                Section {
                    Picker(appState.t(.settingsTranscriptionLanguage), selection: $transcriptionLanguage) {
                        ForEach(AppState.supportedLanguages, id: \.id) { option in
                            Text(appState.t(option.labelKey)).tag(option.id)
                        }
                    }
                    .onChange(of: transcriptionLanguage) { _, newValue in appState.language = newValue }
                } footer: {
                    Text(appState.t(.settingsTranscriptionLanguageNote)).font(.caption).foregroundStyle(.secondary)
                }

                Section {
                    Picker(appState.t(.settingsAppLanguage), selection: $appLanguage) {
                        ForEach(Localization.supportedLanguages, id: \.id) { option in
                            Text(option.label).tag(option.id)
                        }
                    }
                    .onChange(of: appLanguage) { _, newValue in appState.appLanguage = newValue }
                } footer: {
                    Text(appState.t(.settingsAppLanguageNote)).font(.caption).foregroundStyle(.secondary)
                }

                Section {
                    LabeledContent(appState.t(.settingsStorageFolder)) {
                        Text(appState.sessionStore.rootDirectory.path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Button(appState.t(.settingsChangeFolder)) { appState.changeStorageFolder() }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button(appState.t(.settingsClose)) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(RTheme.Spacing.md)
        }
        .frame(width: 420, height: 380)
    }
}

// MARK: - Session detail (transcript-centric, compact player pinned below)

private struct TranscriptLine: Identifiable {
    let id: Int
    let startMs: Int
    let speaker: String
    let text: String

    var startSeconds: Double { Double(startMs) / 1000 }
}

/// Step 5: playback with independent me/remote gain (Q4), transcript
/// (steps 3/4) with search highlighting and playback-position sync.
struct SessionDetailPane: View {
    let appState: AppState
    let session: Session

    @State private var meGain: Double
    @State private var remoteGain: Double
    @State private var lines: [TranscriptLine] = []
    @State private var displayName: String
    @State private var query = ""

    init(appState: AppState, session: Session) {
        self.appState = appState
        self.session = session
        _meGain = State(initialValue: session.gains.me)
        _remoteGain = State(initialValue: session.gains.remote)
        _displayName = State(initialValue: session.displayName)
    }

    private var isPlayingThis: Bool { appState.playingSessionID == session.id }
    private var isTranscribingThis: Bool { appState.transcribingSessionID == session.id }

    private var filteredLines: [TranscriptLine] {
        guard !query.isEmpty else { return lines }
        return lines.filter { $0.text.localizedCaseInsensitiveContains(query) }
    }

    /// The utterance currently playing, for the highlighted-line sync.
    private var currentLineID: Int? {
        guard isPlayingThis else { return nil }
        return lines.last { $0.startSeconds <= appState.playbackTime }?.id
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if lines.isEmpty {
                emptyTranscriptState
            } else {
                ScrollViewReader { proxy in
                    List(filteredLines) { line in
                        TranscriptRow(line: line, query: query, isCurrent: line.id == currentLineID)
                            .id(line.id)
                            .contentShape(Rectangle())
                            .onTapGesture { appState.seekPlayback(session, toSeconds: line.startSeconds) }
                    }
                    .listStyle(.plain)
                    .searchable(text: $query, prompt: appState.t(.searchPlaceholder))
                    .onChange(of: currentLineID) { _, newValue in
                        guard let newValue else { return }
                        withAnimation { proxy.scrollTo(newValue, anchor: .center) }
                    }
                }
            }

            Divider()
            CompactPlayerBar(appState: appState, session: session, meGain: $meGain, remoteGain: $remoteGain)
        }
        .onAppear { loadTranscript() }
        .onChange(of: appState.transcribingSessionID) { _, newValue in
            if newValue == nil { loadTranscript() }
        }
        // Binding form, not `.navigationTitle(displayName)` — that plus a
        // separate toolbar TextField showed the session name twice in the
        // toolbar (confirmed by screenshot). The binding gives a native,
        // inline-editable window title (the same rename affordance Finder/
        // Notes use), so no extra text field is needed at all.
        .navigationTitle($displayName)
        .onChange(of: displayName) { _, newValue in appState.rename(session, to: newValue) }
        .toolbar {
            ToolbarItem {
                Button {
                    appState.transcribeSession(session)
                } label: {
                    if isTranscribingThis {
                        ProgressView().controlSize(.small)
                    } else {
                        Label(lines.isEmpty ? appState.t(.transcribeButton) : appState.t(.retranscribeButton),
                              systemImage: "text.bubble")
                    }
                }
                .disabled(isTranscribingThis)
            }
        }
    }

    private var header: some View {
        HStack(spacing: RTheme.Spacing.sm) {
            Text("\(session.targetDisplayName) · \(formattedDuration(session.durationSeconds)) · \(session.language)")
                .font(.caption)
                .foregroundStyle(.secondary)
            if session.state == .recovered {
                Label(appState.t(.recoveredBadge), systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            Spacer()
            if isTranscribingThis, let progress = appState.transcribeProgress {
                Text(progress).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, RTheme.Spacing.lg)
        .padding(.vertical, RTheme.Spacing.sm)
    }

    private var emptyTranscriptState: some View {
        ContentUnavailableView(
            appState.t(.notTranscribedYet),
            systemImage: "text.bubble",
            description: Text("")
        )
    }

    private func loadTranscript() {
        let path = appState.sessionStore.directory(for: session).appendingPathComponent("transcript.txt")
        guard let text = try? String(contentsOf: path, encoding: .utf8) else {
            lines = []
            return
        }
        lines = text.split(separator: "\n").enumerated().compactMap { index, rawLine in
            let parts = rawLine.split(separator: "|", maxSplits: 2)
            guard parts.count == 3, let ms = Int(parts[0]) else { return nil }
            return TranscriptLine(id: index, startMs: ms, speaker: String(parts[1]), text: String(parts[2]))
        }
    }
}

/// Speaker letter uses the same accent/secondary split as the level meter.
/// Search matches are highlighted inline instead of just filtering rows —
/// "검색 결과 highlight."
private struct TranscriptRow: View {
    let line: TranscriptLine
    let query: String
    let isCurrent: Bool

    var body: some View {
        HStack(alignment: .top, spacing: RTheme.Spacing.sm) {
            Text(timestamp(line.startMs))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
            Text(line.speaker)
                .font(.caption.bold())
                .foregroundStyle(line.speaker == "M" ? Color.accentColor : Color.secondary)
                .frame(width: 16)
            highlightedText
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, RTheme.Spacing.sm)
        .background(isCurrent ? Color.accentColor.opacity(0.12) : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private var highlightedText: Text {
        guard !query.isEmpty, let range = line.text.range(of: query, options: .caseInsensitive) else {
            return Text(line.text)
        }
        var result = AttributedString(line.text)
        if let attributedRange = Range(range, in: result) {
            result[attributedRange].inlinePresentationIntent = .stronglyEmphasized
            result[attributedRange].underlineStyle = .single
        }
        return Text(result)
    }

    private func timestamp(_ ms: Int) -> String {
        formattedDuration(Double(ms) / 1000)
    }
}

/// Bottom-pinned player: play/stop, seekable position, ME/REMOTE gain —
/// deliberately one compact row, not a separate panel, so it reads as a
/// utility strip (Voice Memos' own player bar) rather than a feature.
private struct CompactPlayerBar: View {
    let appState: AppState
    let session: Session
    @Binding var meGain: Double
    @Binding var remoteGain: Double
    @State private var isScrubbing = false
    @State private var scrubTime: Double = 0

    private var isPlayingThis: Bool { appState.playingSessionID == session.id }
    private var duration: Double { max(session.durationSeconds, 0.01) }

    /// `appState.playbackTime` is shared across whichever session is
    /// actually playing — reading it directly here for a session that
    /// *isn't* the one playing shows whatever was left over from the last
    /// thing played (confirmed visually: switching to an unplayed 2s
    /// session showed "0:04" left over from a previous session). Falls
    /// back to 0 whenever this session isn't the one currently playing.
    private var displayTime: Double {
        if isScrubbing { return scrubTime }
        return isPlayingThis ? appState.playbackTime : 0
    }

    var body: some View {
        VStack(spacing: RTheme.Spacing.xs) {
            HStack(spacing: RTheme.Spacing.sm) {
                Button {
                    if isPlayingThis { appState.stopPlayback() } else { appState.play(session) }
                } label: {
                    Image(systemName: isPlayingThis ? "stop.fill" : "play.fill")
                }
                .controlSize(.regular)

                Text(formattedDuration(displayTime)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Slider(value: Binding(
                    get: { displayTime },
                    set: { scrubTime = $0 }
                ), in: 0 ... duration, onEditingChanged: { editing in
                    isScrubbing = editing
                    if !editing { appState.seekPlayback(session, toSeconds: scrubTime) }
                })
                Text(formattedDuration(duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }

            HStack(spacing: RTheme.Spacing.lg) {
                GainControl(label: appState.t(.gainMe), tint: .accentColor, value: $meGain) {
                    appState.setGains(for: session, me: meGain, remote: remoteGain)
                }
                GainControl(label: appState.t(.gainRemote), tint: .secondary, value: $remoteGain) {
                    appState.setGains(for: session, me: meGain, remote: remoteGain)
                }
            }
        }
        .padding(RTheme.Spacing.md)
    }
}

private struct GainControl: View {
    let label: String
    let tint: Color
    @Binding var value: Double
    let onChange: () -> Void

    var body: some View {
        HStack(spacing: RTheme.Spacing.xs) {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 32, alignment: .leading)
            Slider(value: $value, in: 0.25 ... 3.0, step: 0.05) { editing in
                if !editing { onChange() }
            }
            .tint(tint)
            Text(String(format: "%.1fx", value))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 32, alignment: .trailing)
        }
        .frame(maxWidth: 220)
    }
}
