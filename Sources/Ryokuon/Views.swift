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
        .frame(minWidth: 420, minHeight: 360)
    }
}

/// Q14: one permission at a time, each with a one-line explanation before
/// the system prompt appears.
struct OnboardingView: View {
    let appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Ryokuon 시작하기").font(.title2.bold())

            PermissionRow(
                title: "마이크",
                explanation: "내 목소리를 녹음하기 위해 마이크를 사용합니다.",
                status: appState.permissions.microphone
            ) {
                Task { await appState.permissions.requestMicrophone() }
            }

            PermissionRow(
                title: "오디오 캡처",
                explanation: "상대방 목소리를 녹음하기 위해 선택한 앱의 소리를 가져옵니다.",
                status: appState.permissions.audioCapture
            ) {
                appState.permissions.requestAudioCapture()
            }

            PermissionRow(
                title: "저장 폴더",
                explanation: "녹음 파일을 \(appState.sessionStore.rootDirectory.path)에 저장합니다.",
                status: appState.permissions.documentsFolder
            ) {
                appState.permissions.requestDocumentsAccess(root: appState.sessionStore.rootDirectory)
            }

            Spacer()
        }
        .padding(24)
    }
}

private struct PermissionRow: View {
    let title: String
    let explanation: String
    let status: PermissionsManager.Status
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                statusLabel
            }
            Text(explanation).font(.callout).foregroundStyle(.secondary)
            if status != .granted {
                Button("허용 요청") { action() }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch status {
        case .granted: Label("허용됨", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .denied: Label("거부됨", systemImage: "xmark.circle.fill").foregroundStyle(.red)
        case .notDetermined: Label("대기중", systemImage: "circle.dashed").foregroundStyle(.secondary)
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
                        .foregroundStyle(.orange)
                        .padding(8)
                }
                List(appState.sessions, id: \.id) { session in
                    NavigationLink(value: session.id) {
                        VStack(alignment: .leading) {
                            HStack {
                                Text(session.displayName).font(.headline)
                                if session.state == .recovered {
                                    Label("복구됨", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                                }
                            }
                            Text("\(session.targetDisplayName) · \(Int(session.durationSeconds))초 · \(session.language)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .onAppear { appState.reloadSessions() }
            }
            .navigationDestination(for: String.self) { sessionID in
                if let session = appState.sessions.first(where: { $0.id == sessionID }) {
                    SessionDetailView(appState: appState, session: session)
                }
            }
            .toolbar {
                ToolbarItem { Button("설정") { showingSettings = true } }
            }
            .sheet(isPresented: $showingSettings) {
                SettingsSheetView(appState: appState)
            }
        }
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
        VStack(alignment: .leading, spacing: 16) {
            Text("설정").font(.title2.bold())

            VStack(alignment: .leading, spacing: 4) {
                Text("전사 언어 (새 녹음부터 적용)").font(.caption).foregroundStyle(.secondary)
                Picker("", selection: $language) {
                    ForEach(AppState.supportedLanguages, id: \.id) { option in
                        Text(option.label).tag(option.id)
                    }
                }
                .labelsHidden()
                .onChange(of: language) { _, newValue in appState.language = newValue }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("저장 폴더").font(.caption).foregroundStyle(.secondary)
                Text(appState.sessionStore.rootDirectory.path)
                    .font(.callout)
                    .textSelection(.enabled)
                Button("폴더 변경") { appState.changeStorageFolder() }
            }

            Spacer()
            Button("닫기") { dismiss() }
        }
        .padding(24)
        .frame(minWidth: 360, minHeight: 260)
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
        VStack(alignment: .leading, spacing: 16) {
            TextField("세션 이름", text: $displayName)
                .font(.title2.bold())
                .textFieldStyle(.plain)
                .onSubmit { appState.rename(session, to: displayName) }
            Text("\(session.targetDisplayName) · \(Int(session.durationSeconds))초 · \(session.language)")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button(isPlayingThis ? "정지" : "재생") {
                if isPlayingThis {
                    appState.stopPlayback()
                } else {
                    appState.play(session)
                }
            }

            GainSlider(label: "나", value: $meGain) { appState.setGains(for: session, me: meGain, remote: remoteGain) }
            GainSlider(label: "상대", value: $remoteGain) { appState.setGains(for: session, me: meGain, remote: remoteGain) }

            HStack {
                Button(transcript == nil ? "전사하기" : "다시 전사하기") { appState.transcribeSession(session) }
                    .disabled(isTranscribingThis)
                if isTranscribingThis, let progress = appState.transcribeProgress {
                    Text(progress).font(.caption).foregroundStyle(.secondary)
                }
            }

            if let transcript {
                ScrollView {
                    Text(transcript).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Text("아직 전사되지 않음").font(.caption).foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(24)
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

private struct GainSlider: View {
    let label: String
    @Binding var value: Double
    let onChange: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(label) 볼륨 \(String(format: "%.1fx", value))").font(.caption)
            Slider(value: $value, in: 0.25 ... 3.0, step: 0.05) { editing in
                if !editing { onChange() }
            }
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
                Button("녹음 시작 — \(name)") { appState.startWithLastTarget() }
            }
            let processes = appState.playingProcesses()
            if !processes.isEmpty {
                Menu(appState.lastTargetDisplayName == nil ? "녹음 시작" : "다른 앱 선택") {
                    ForEach(processes) { process in
                        Button(process.displayName) { appState.start(target: process) }
                    }
                }
            } else if appState.lastTargetDisplayName == nil {
                Text("소리 내는 앱이 없음 — 녹음할 앱에서 소리를 먼저 재생해줘")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .background(.quaternary.opacity(0.2))
    }
}

private struct RecordingBanner: View {
    let appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Circle().fill(.red).frame(width: 8, height: 8)
                Text("녹음 중 — \(appState.lastTargetDisplayName ?? "")")
                Spacer()
                Button("종료") { appState.stop() }
            }
            HStack {
                LevelMeter(label: "나", db: appState.meLevelDB)
                LevelMeter(label: "상대", db: appState.remoteLevelDB)
            }
            if let warning = appState.silenceWarning {
                Text(warning).font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.3))
    }
}

/// Q18's "소리 막대" — a plain dB bar, not full playback UI (that's step 5).
private struct LevelMeter: View {
    let label: String
    let db: Float

    private var normalized: Double {
        // -60dB (near silent) .. 0dB (clipping), clamped to [0, 1].
        Double(max(0, min(1, (db + 60) / 60)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2)
            GeometryReader { geo in
                RoundedRectangle(cornerRadius: 3)
                    .fill(.quaternary)
                    .overlay(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(.green)
                            .frame(width: geo.size.width * normalized)
                    }
            }
            .frame(height: 8)
        }
        .frame(width: 100)
    }
}
