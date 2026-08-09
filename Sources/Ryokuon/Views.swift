import SwiftUI

struct MainWindowView: View {
    let appState: AppState

    var body: some View {
        Group {
            if appState.permissions.allGranted {
                SessionListView(appState: appState)
            } else {
                OnboardingView(appState: appState)
            }
        }
        .frame(minWidth: 440, minHeight: 380)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// Q14: one permission at a time, each with a one-line explanation before
/// the system prompt appears.
struct OnboardingView: View {
    let appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: RTheme.Spacing.lg) {
            HStack(spacing: RTheme.Spacing.sm) {
                Text("🎙️").font(.system(size: 28))
                Text("Ryokuon 시작하기").font(RTheme.heading(22)).foregroundStyle(RTheme.ink)
            }
            Text("녹음을 시작하기 전에 세 가지 권한이 필요해요.")
                .font(.callout)
                .foregroundStyle(RTheme.slate)

            PermissionRow(
                icon: "mic.fill", tint: RTheme.me,
                title: "마이크",
                explanation: "내 목소리를 녹음하기 위해 마이크를 사용합니다.",
                status: appState.permissions.microphone
            ) {
                Task { await appState.permissions.requestMicrophone() }
            }

            PermissionRow(
                icon: "waveform", tint: RTheme.remote,
                title: "오디오 캡처",
                explanation: "상대방 목소리를 녹음하기 위해 선택한 앱의 소리를 가져옵니다.",
                status: appState.permissions.audioCapture
            ) {
                appState.permissions.requestAudioCapture()
            }

            PermissionRow(
                icon: "folder.fill", tint: RTheme.slate,
                title: "저장 폴더",
                explanation: "녹음 파일을 \(appState.sessionStore.rootDirectory.path)에 저장합니다.",
                status: appState.permissions.documentsFolder
            ) {
                appState.permissions.requestDocumentsAccess(root: appState.sessionStore.rootDirectory)
            }

            Spacer()
        }
        .padding(RTheme.Spacing.xl)
    }
}

private struct PermissionRow: View {
    let icon: String
    let tint: Color
    let title: String
    let explanation: String
    let status: PermissionsManager.Status
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: RTheme.Spacing.md) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(tint.opacity(0.15), in: Circle())

            VStack(alignment: .leading, spacing: RTheme.Spacing.xs) {
                HStack {
                    Text(title).font(.headline).foregroundStyle(RTheme.ink)
                    Spacer()
                    statusLabel
                }
                Text(explanation).font(.callout).foregroundStyle(RTheme.slate)
                if status != .granted {
                    Button("허용 요청") { action() }
                        .buttonStyle(.borderedProminent)
                        .tint(tint)
                        .controlSize(.small)
                }
            }
        }
        .rCard()
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch status {
        case .granted: Label("허용됨", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(RTheme.me)
        case .denied: Label("거부됨", systemImage: "xmark.circle.fill").font(.caption).foregroundStyle(RTheme.record)
        case .notDetermined: Label("대기중", systemImage: "circle.dashed").font(.caption).foregroundStyle(RTheme.slate)
        }
    }
}

struct SessionListView: View {
    let appState: AppState
    @State private var showingSettings = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if appState.isRecording {
                    RecordingBanner(appState: appState)
                } else {
                    StartRecordingBar(appState: appState)
                }
                if let error = appState.lastError {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(RTheme.warning)
                        .padding(RTheme.Spacing.sm)
                }
                if appState.sessions.isEmpty {
                    emptyState
                } else {
                    List(appState.sessions, id: \.id) { session in
                        NavigationLink(value: session.id) {
                            SessionRow(session: session)
                        }
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                    }
                    .listStyle(.plain)
                }
            }
            .onAppear { appState.reloadSessions() }
            .navigationTitle("Ryokuon")
            .navigationDestination(for: String.self) { sessionID in
                if let session = appState.sessions.first(where: { $0.id == sessionID }) {
                    SessionDetailView(appState: appState, session: session)
                }
            }
            .toolbar {
                ToolbarItem {
                    Button { showingSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $showingSettings) {
                SettingsSheetView(appState: appState)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: RTheme.Spacing.sm) {
            Spacer()
            Text("🌊").font(.system(size: 40))
            Text("아직 녹음이 없어요").font(.headline).foregroundStyle(RTheme.ink)
            Text("위에서 녹음을 시작해보세요").font(.caption).foregroundStyle(RTheme.slate)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

private struct SessionRow: View {
    let session: Session

    var body: some View {
        HStack(spacing: RTheme.Spacing.md) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: RTheme.Spacing.xs) {
                    Text(session.displayName).font(.headline).foregroundStyle(RTheme.ink)
                    if session.state == .recovered {
                        Label("복구됨", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption2).foregroundStyle(RTheme.warning)
                    }
                }
                Text("\(session.targetDisplayName) · \(Int(session.durationSeconds))초 · \(session.language)")
                    .font(.caption)
                    .foregroundStyle(RTheme.slate)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(RTheme.slate.opacity(0.5))
        }
        .rCard()
    }
}

/// Q7(언어) + Q9(저장 폴더) — 둘 다 새 녹음부터 적용되고 기존 세션은 그대로 둔다는 게
/// 원래 설계 그대로(AppState.language/changeStorageFolder의 계약).
struct SettingsSheetView: View {
    let appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var language: String

    init(appState: AppState) {
        self.appState = appState
        _language = State(initialValue: appState.language)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: RTheme.Spacing.lg) {
            Text("설정").font(RTheme.heading(20)).foregroundStyle(RTheme.ink)

            VStack(alignment: .leading, spacing: RTheme.Spacing.xs) {
                Text("전사 언어").font(.caption).foregroundStyle(RTheme.slate)
                Picker("", selection: $language) {
                    ForEach(AppState.supportedLanguages, id: \.id) { option in
                        Text(option.label).tag(option.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .onChange(of: language) { _, newValue in appState.language = newValue }
                Text("새 녹음부터 적용됩니다").font(.caption2).foregroundStyle(RTheme.slate.opacity(0.8))
            }
            .rCard()

            VStack(alignment: .leading, spacing: RTheme.Spacing.xs) {
                Text("저장 폴더").font(.caption).foregroundStyle(RTheme.slate)
                Text(appState.sessionStore.rootDirectory.path)
                    .font(.callout)
                    .textSelection(.enabled)
                Button("폴더 변경") { appState.changeStorageFolder() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            .rCard()

            Spacer()
            Button("닫기") { dismiss() }
                .buttonStyle(.borderedProminent)
                .tint(RTheme.remote)
        }
        .padding(RTheme.Spacing.xl)
        .frame(minWidth: 380, minHeight: 280)
    }
}

/// Step 5: playback with independent me/remote gain (Q4) and the
/// transcript, if step 3/4 have produced one yet.
struct SessionDetailView: View {
    let appState: AppState
    let session: Session

    @State private var meGain: Double
    @State private var remoteGain: Double
    @State private var transcript: String?
    @State private var displayName: String

    init(appState: AppState, session: Session) {
        self.appState = appState
        self.session = session
        _meGain = State(initialValue: session.gains.me)
        _remoteGain = State(initialValue: session.gains.remote)
        _displayName = State(initialValue: session.displayName)
    }

    private var isPlayingThis: Bool { appState.playingSessionID == session.id }
    private var isTranscribingThis: Bool { appState.transcribingSessionID == session.id }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: RTheme.Spacing.lg) {
                TextField("세션 이름", text: $displayName)
                    .font(RTheme.heading(20))
                    .foregroundStyle(RTheme.ink)
                    .textFieldStyle(.plain)
                    .onSubmit { appState.rename(session, to: displayName) }
                Text("\(session.targetDisplayName) · \(Int(session.durationSeconds))초 · \(session.language)")
                    .font(.caption)
                    .foregroundStyle(RTheme.slate)

                HStack(spacing: RTheme.Spacing.md) {
                    Button {
                        if isPlayingThis { appState.stopPlayback() } else { appState.play(session) }
                    } label: {
                        Label(isPlayingThis ? "정지" : "재생", systemImage: isPlayingThis ? "stop.fill" : "play.fill")
                            .frame(minWidth: 64)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(isPlayingThis ? RTheme.record : RTheme.remote)
                }

                VStack(alignment: .leading, spacing: RTheme.Spacing.md) {
                    GainSlider(label: "나", tint: RTheme.me, value: $meGain) {
                        appState.setGains(for: session, me: meGain, remote: remoteGain)
                    }
                    GainSlider(label: "상대", tint: RTheme.remote, value: $remoteGain) {
                        appState.setGains(for: session, me: meGain, remote: remoteGain)
                    }
                }
                .rCard()

                VStack(alignment: .leading, spacing: RTheme.Spacing.sm) {
                    HStack(spacing: RTheme.Spacing.sm) {
                        Button(transcript == nil ? "전사하기" : "다시 전사하기") {
                            appState.transcribeSession(session)
                        }
                        .buttonStyle(.bordered)
                        .disabled(isTranscribingThis)
                        if isTranscribingThis {
                            ProgressView().controlSize(.small)
                            if let progress = appState.transcribeProgress {
                                Text(progress).font(.caption).foregroundStyle(RTheme.slate)
                            }
                        }
                    }

                    if let transcript {
                        TranscriptView(text: transcript)
                    } else {
                        Text("아직 전사되지 않음").font(.caption).foregroundStyle(RTheme.slate)
                    }
                }
            }
            .padding(RTheme.Spacing.xl)
        }
        .onAppear { loadTranscript() }
        .onChange(of: appState.transcribingSessionID) { _, newValue in
            if newValue == nil { loadTranscript() } // just finished (this or another session)
        }
    }

    private func loadTranscript() {
        let path = appState.sessionStore.directory(for: session).appendingPathComponent("transcript.txt")
        transcript = try? String(contentsOf: path, encoding: .utf8)
    }
}

/// Each line is `startMs|speaker|text` — the speaker letter gets its
/// channel color (me=mint, remote=sky) so scanning a transcript reads the
/// same way the level meter and gain sliders do.
private struct TranscriptView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: RTheme.Spacing.xs) {
            ForEach(Array(text.split(separator: "\n").enumerated()), id: \.offset) { _, line in
                let parts = line.split(separator: "|", maxSplits: 2)
                if parts.count == 3 {
                    HStack(alignment: .top, spacing: RTheme.Spacing.sm) {
                        Text(parts[0]).font(RTheme.mono).foregroundStyle(RTheme.slate).frame(width: 56, alignment: .trailing)
                        Text(parts[1]).font(RTheme.mono.bold())
                            .foregroundStyle(parts[1] == "M" ? RTheme.me : RTheme.remote)
                        Text(parts[2]).font(.callout).foregroundStyle(RTheme.ink)
                    }
                } else {
                    Text(line).font(.callout).foregroundStyle(RTheme.ink)
                }
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(RTheme.Spacing.md)
        .background(RTheme.mist, in: RoundedRectangle(cornerRadius: RTheme.cornerRadius))
    }
}

private struct GainSlider: View {
    let label: String
    let tint: Color
    @Binding var value: Double
    let onChange: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Circle().fill(tint).frame(width: 8, height: 8)
                Text("\(label) 볼륨").font(.caption).foregroundStyle(RTheme.ink)
                Spacer()
                Text(String(format: "%.1fx", value)).font(.caption.monospacedDigit()).foregroundStyle(RTheme.slate)
            }
            Slider(value: $value, in: 0.25 ... 3.0, step: 0.05) { editing in
                if !editing { onChange() }
            }
            .tint(tint)
        }
    }
}

/// Q17's one-click flow, in the main window rather than just the menu bar —
/// last-used target if there is one (one click), or pick from apps
/// currently making sound.
private struct StartRecordingBar: View {
    let appState: AppState

    var body: some View {
        HStack {
            if let name = appState.lastTargetDisplayName {
                Button {
                    appState.startWithLastTarget()
                } label: {
                    Label("녹음 시작 — \(name)", systemImage: "record.circle")
                }
                .buttonStyle(.borderedProminent)
                .tint(RTheme.record)
            }
            let processes = appState.playingProcesses()
            if !processes.isEmpty {
                Menu(appState.lastTargetDisplayName == nil ? "녹음 시작" : "다른 앱 선택") {
                    ForEach(processes) { process in
                        Button(process.displayName) { appState.start(target: process) }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            } else if appState.lastTargetDisplayName == nil {
                Text("소리 내는 앱이 없음 — 녹음할 앱에서 소리를 먼저 재생해줘")
                    .font(.caption)
                    .foregroundStyle(RTheme.slate)
            }
            Spacer()
        }
        .padding(RTheme.Spacing.md)
    }
}

private struct RecordingBanner: View {
    let appState: AppState
    @State private var pulse = false

    var body: some View {
        VStack(alignment: .leading, spacing: RTheme.Spacing.sm) {
            HStack {
                Circle().fill(RTheme.record).frame(width: 8, height: 8)
                    .opacity(pulse ? 0.4 : 1)
                    .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
                    .onAppear { pulse = true }
                Text("녹음 중 — \(appState.lastTargetDisplayName ?? "")").foregroundStyle(RTheme.ink)
                Spacer()
                Button {
                    appState.stop()
                } label: {
                    Label("종료", systemImage: "stop.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(RTheme.record)
                .controlSize(.small)
            }
            HStack(spacing: RTheme.Spacing.lg) {
                LevelMeter(label: "나", tint: RTheme.me, db: appState.meLevelDB)
                LevelMeter(label: "상대", tint: RTheme.remote, db: appState.remoteLevelDB)
            }
            if let warning = appState.silenceWarning {
                Text(warning).font(.caption).foregroundStyle(RTheme.warning)
            }
        }
        .padding(RTheme.Spacing.md)
        .background(RTheme.mist)
    }
}

/// Q18's "소리 막대". me/remote get their channel color so the meter reads
/// the same way as the gain sliders and transcript speaker tags.
private struct LevelMeter: View {
    let label: String
    let tint: Color
    let db: Float

    private var normalized: Double {
        // -60dB (near silent) .. 0dB (clipping), clamped to [0, 1].
        Double(max(0, min(1, (db + 60) / 60)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(RTheme.slate)
            GeometryReader { geo in
                Capsule()
                    .fill(RTheme.slate.opacity(0.15))
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(tint)
                            .frame(width: max(3, geo.size.width * normalized))
                    }
            }
            .frame(height: 8)
        }
        .frame(width: 100)
    }
}
