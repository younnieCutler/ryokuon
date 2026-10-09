import AppKit
import AVFoundation
import SwiftUI

struct MainWindowView: View {
    let appState: AppState

    var body: some View {
        RyokuonSplitView(appState: appState)
        .frame(minWidth: 520, minHeight: 380)
        .onAppear {
            if !appState.permissions.allGranted { appState.isShowingPermissionSetup = true }
        }
        .toolbar {
            if !appState.permissions.allGranted {
                ToolbarItem {
                    Button { appState.isShowingPermissionSetup = true } label: {
                        Label(appState.t(.onboardingTitle), systemImage: "mic.badge.plus")
                    }
                }
            }
        }
        .sheet(isPresented: Binding(
            get: { appState.isShowingPermissionSetup },
            set: { appState.isShowingPermissionSetup = $0 }
        )) {
            OnboardingView(appState: appState)
                .frame(minWidth: 440, idealWidth: 520, minHeight: 440)
        }
        .onChange(of: appState.permissions.allGranted) { _, granted in
            if granted { appState.isShowingPermissionSetup = false }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            appState.permissions.refreshMicrophoneStatus()
        }
    }
}

// MARK: - Onboarding (System Settings-style permission list)

/// Q14: one permission at a time, each with a one-line explanation before
/// the system prompt appears.
struct OnboardingView: View {
    let appState: AppState
    @Environment(\.dismiss) private var dismiss

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

            HStack {
                Button(appState.t(.openSystemSettings)) {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
                }
                Button(appState.t(.settingsChangeFolder)) { appState.changeStorageFolder() }
            }
            Text(appState.t(.permissionRecoveryHint))
                .font(.caption).foregroundStyle(.secondary)

            Spacer()
            Button(appState.t(.continueWithoutRecording)) { dismiss() }
                .keyboardShortcut(.cancelAction)
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
    @State private var isEditing = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    private var selectedSession: Session? {
        guard let selection else { return nil }
        return appState.sessions.first { $0.relativePath == selection }
            ?? appState.session(forAudioPath: selection)
    }

    var body: some View {
        GeometryReader { _ in
            NavigationSplitView(columnVisibility: $columnVisibility) {
                SessionSidebar(appState: appState, selection: $selection, isEditing: $isEditing)
                    .navigationSplitViewColumnWidth(min: 190, ideal: 260, max: 340)
            } detail: {
                if let session = selectedSession {
                    SessionDetailPane(appState: appState, session: session)
                        .id(session.relativePath)
                } else if let selection, let node = appState.libraryNode(at: selection) {
                    if node.isFolder {
                        FolderDetailPane(appState: appState, node: node, selection: self.$selection)
                    } else {
                        ExternalAudioDetailPane(appState: appState, node: node)
                            .id(node.relativePath)
                    }
                } else {
                    ContentUnavailableView {
                        Label(appState.t(.detailNoSelection), systemImage: "waveform")
                    } description: {
                        Text(appState.t(.detailNoSelectionHint))
                    } actions: {
                        Button { appState.presentImportPanel() } label: {
                            Label(appState.t(.importButton), systemImage: "square.and.arrow.down")
                        }
                    }
                }
            }
            .onAppear {
                appState.reloadSessions()
            }
            .onChange(of: appState.libraryRevision) { _, _ in
                if let selection, appState.libraryNode(at: selection) == nil,
                   appState.sessions.allSatisfy({ $0.relativePath != selection }) { self.selection = nil }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                appState.refreshLibrary()
            }
            .toolbar {
                ToolbarItem {
                    Button { appState.presentImportPanel() } label: {
                        Label(appState.t(.importButton), systemImage: "square.and.arrow.down")
                            .labelStyle(.iconOnly)
                    }
                    .help(appState.t(.importHelp))
                    .keyboardShortcut("o", modifiers: .command)
                }
                ToolbarSpacer(.fixed)
                ToolbarItem {
                    Button { appState.isShowingSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                    .help(appState.t(.settingsTitle))
                }
            }
            .sheet(isPresented: Binding(get: { appState.isShowingSettings }, set: { appState.isShowingSettings = $0 })) {
                SettingsSheetView(appState: appState)
            }
        }
    }

}

private struct SessionSidebar: View {
    let appState: AppState
    @Binding var selection: String?
    @Binding var isEditing: Bool
    @State private var searchText = ""
    @State private var selectedIDs: Set<String> = []
    @State private var showDeleteConfirm = false
    @State private var pendingDeleteIDs: Set<String> = []
    @State private var isDropTargeted = false
    @State private var expandedFolders: Set<String> = []

    private struct VisibleNode: Identifiable {
        let node: AudioLibraryNode
        let depth: Int
        var id: String { node.relativePath }
    }

    private var filteredNodes: [AudioLibraryNode] {
        AudioLibrarySearch.filter(appState.libraryNodes, sessions: appState.sessions, query: searchText)
    }

    private var visibleNodes: [VisibleNode] {
        var result: [VisibleNode] = []
        func append(_ nodes: [AudioLibraryNode], depth: Int) {
            for node in nodes {
                result.append(VisibleNode(node: node, depth: depth))
                if node.isFolder && (expandedFolders.contains(node.relativePath) || !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                    append(node.children, depth: depth + 1)
                }
            }
        }
        append(filteredNodes, depth: 0)
        return result
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: RTheme.Spacing.sm) {
                Text(appState.sessionStore.rootDirectory.lastPathComponent)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(appState.sessionStore.rootDirectory.path)
                Spacer(minLength: 0)
                Button { appState.refreshLibrary() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help(appState.t(.libraryRefresh))
                Button {
                    isEditing.toggle()
                } label: {
                    Image(systemName: isEditing ? "checkmark" : "square.and.pencil")
                }
                .buttonStyle(.plain)
                .help(appState.t(isEditing ? .doneButton : .editButton))
            }
            .padding(.horizontal, RTheme.Spacing.md)
            .padding(.vertical, RTheme.Spacing.sm)
            if appState.libraryNodes.isEmpty && !appState.isRecording {
                ContentUnavailableView(appState.t(.emptyTitle), systemImage: "waveform",
                                       description: Text(appState.t(.emptySubtitle)))
            } else {
                List(selection: $selection) {
                    ForEach(visibleNodes) { visible in
                        let node = visible.node
                        let session = node.isFolder
                            ? appState.sessions.first { $0.relativePath == node.relativePath }
                            : nil
                        LibraryNodeRow(
                            appState: appState, node: node, session: session,
                            depth: visible.depth,
                            isEditing: isEditing, isSelected: selection == node.relativePath,
                            isExpanded: expandedFolders.contains(node.relativePath) || !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                            isMarkedForDeletion: selectedIDs.contains(node.relativePath),
                            onToggleExpand: {
                                if expandedFolders.contains(node.relativePath) {
                                    expandedFolders.remove(node.relativePath)
                                } else {
                                    expandedFolders.insert(node.relativePath)
                                }
                            },
                            onToggleDelete: { toggleSelection(node.relativePath) },
                            onDelete: {
                                pendingDeleteIDs = [node.relativePath]
                                showDeleteConfirm = true
                            }
                        )
                        .tag(node.relativePath)
                    }
                }
                .listStyle(.sidebar)
                .onMoveCommand { moveSelection($0) }
                .onDeleteCommand {
                    guard let selection, let session = appState.sessions.first(where: { $0.relativePath == selection }),
                          appState.canDelete(session) else { return }
                    pendingDeleteIDs = [session.relativePath]
                    showDeleteConfirm = true
                }
                .searchable(text: $searchText, placement: .sidebar, prompt: appState.t(.searchPlaceholder))
                .overlay {
                    if visibleNodes.isEmpty {
                        ContentUnavailableView.search(text: searchText)
                    }
                }
            }
            if isEditing && !selectedIDs.isEmpty {
                Button(role: .destructive) { pendingDeleteIDs = selectedIDs; showDeleteConfirm = true } label: {
                    Text("\(appState.t(.deleteButton)) (\(selectedIDs.count))")
                        .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, RTheme.Spacing.md)
                .padding(.top, RTheme.Spacing.sm)
            }
            if let fileName = appState.importingFileName {
                HStack(spacing: RTheme.Spacing.sm) {
                    ProgressView().controlSize(.small)
                    Text(appState.t(.importingFile, fileName)).lineLimit(1).truncationMode(.middle)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(RTheme.Spacing.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let error = appState.lastError {
                HStack(alignment: .top) {
                    Text(error).textSelection(.enabled)
                    Spacer(minLength: 0)
                    Button { appState.lastError = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain)
                        .accessibilityLabel(appState.t(.dismissError))
                }
                .font(.caption)
                .foregroundStyle(.orange)
                .padding(RTheme.Spacing.sm)
            }
            if let error = appState.libraryError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                    .padding(RTheme.Spacing.sm)
            }
            Divider()
            RecordingControlBar(appState: appState)
        }
        .onChange(of: isEditing) { _, newValue in if !newValue { selectedIDs.removeAll() } }
        .onChange(of: selection) { _, path in
            guard let path else { return }
            var parent = (path as NSString).deletingLastPathComponent
            while !parent.isEmpty {
                expandedFolders.insert(parent)
                parent = (parent as NSString).deletingLastPathComponent
            }
        }
        .onChange(of: appState.libraryRevision) { _, _ in
            selectedIDs.formIntersection(Set(appState.sessions.filter { appState.canDelete($0) }.map(\.relativePath)))
        }
        .dropDestination(for: URL.self) { urls, _ in
            let audio = urls.filter { AudioLibraryScanner.audioExtensions.contains($0.pathExtension.lowercased()) }
            appState.importAudio(audio)
            return !audio.isEmpty
        } isTargeted: { isDropTargeted = $0 }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                    .overlay {
                        Label(appState.t(.dropHint), systemImage: "square.and.arrow.down")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(Color.accentColor)
                            .padding(RTheme.Spacing.md)
                    }
                    .padding(RTheme.Spacing.sm)
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeOut(duration: 0.15), value: isDropTargeted)
        .confirmationDialog(
            appState.t(.deleteConfirmTitle, pendingDeleteIDs.count),
            isPresented: $showDeleteConfirm, titleVisibility: .visible
        ) {
            Button(appState.t(.deleteButton), role: .destructive) {
                guard appState.delete(pendingDeleteIDs) else { return }
                pendingDeleteIDs.removeAll()
                selectedIDs.removeAll()
                isEditing = false
            }
            Button(appState.t(.cancelButton), role: .cancel) {}
        } message: {
            Text(appState.t(.deleteConfirmMessage))
        }
    }

    private func toggleSelection(_ id: String) {
        if selectedIDs.contains(id) { selectedIDs.remove(id) } else { selectedIDs.insert(id) }
    }

    private func moveSelection(_ direction: MoveCommandDirection) {
        let rows = visibleNodes
        guard !rows.isEmpty else { return }
        guard let selection, let index = rows.firstIndex(where: { $0.id == selection }) else {
            self.selection = rows.first?.id
            return
        }
        let node = rows[index].node
        switch direction {
        case .up: self.selection = rows[max(0, index - 1)].id
        case .down: self.selection = rows[min(rows.count - 1, index + 1)].id
        case .right:
            guard node.isFolder else { return }
            if expandedFolders.contains(node.relativePath) { self.selection = node.children.first?.relativePath ?? selection }
            else { expandedFolders.insert(node.relativePath) }
        case .left:
            if node.isFolder && expandedFolders.contains(node.relativePath) {
                expandedFolders.remove(node.relativePath)
            } else {
                let parent = (selection as NSString).deletingLastPathComponent
                if !parent.isEmpty { self.selection = parent }
            }
        @unknown default: break
        }
    }
}

private struct LibraryNodeRow: View {
    let appState: AppState
    let node: AudioLibraryNode
    let session: Session?
    let depth: Int
    let isEditing: Bool
    let isSelected: Bool
    let isExpanded: Bool
    let isMarkedForDeletion: Bool
    let onToggleExpand: () -> Void
    let onToggleDelete: () -> Void
    let onDelete: () -> Void

    @State private var isRenaming = false
    @State private var renameText = ""
    @FocusState private var renameFieldFocused: Bool

    var body: some View {
        rowContent
        .contextMenu {
            Button(appState.t(.revealInFinder)) { revealInFinder() }
            if !isEditing, let session {
                Button(appState.t(.renameButton), action: startRenaming)
                Button(appState.t(.deleteButton), role: .destructive, action: onDelete)
                    .disabled(!appState.canDelete(session))
            }
        }
    }

    private var rowContent: some View {
        HStack(spacing: RTheme.Spacing.sm) {
            if node.isFolder {
                Button(action: onToggleExpand) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .frame(width: 12)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(node.name)
                .accessibilityValue(appState.t(isExpanded ? .libraryExpanded : .libraryCollapsed))
            } else {
                Color.clear.frame(width: 12, height: 12)
            }
            if isEditing, let session {
                Button(action: onToggleDelete) {
                    Image(systemName: isMarkedForDeletion ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isMarkedForDeletion ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
                .disabled(!appState.canDelete(session))
                .accessibilityLabel(appState.t(.deleteButton) + ": " + session.displayName)
            }
            Image(systemName: node.isFolder ? "folder" : "waveform")
                .foregroundStyle(node.isFolder ? Color.secondary : Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                if isRenaming, let session {
                        TextField(appState.t(.sessionNamePlaceholder), text: $renameText)
                            .textFieldStyle(.plain)
                            .focused($renameFieldFocused)
                            .onSubmit { commitRename() }
                            .onExitCommand { isRenaming = false }
                            .onChange(of: renameFieldFocused) { _, focused in
                                if !focused && isRenaming { commitRename() }
                            }
                            .help(session.displayName)
                } else {
                    Text(session?.displayName ?? node.name).lineLimit(1).truncationMode(.middle)
                }
                if let session {
                    Text("\(session.targetDisplayName) · \(formattedDuration(session.durationSeconds))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if !isEditing, session != nil {
                Menu {
                    Button(appState.t(.revealInFinder)) { revealInFinder() }
                    Button(appState.t(.renameButton), action: startRenaming)
                    Button(appState.t(.deleteButton), role: .destructive, action: onDelete)
                        .disabled(session.map { !appState.canDelete($0) } ?? true)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 2)
        .padding(.leading, CGFloat(depth) * 16)
        .contentShape(Rectangle())
        .background(isSelected ? Color.accentColor.opacity(0.15) : .clear)
    }

    private func startRenaming() {
        guard let session else { return }
        renameText = session.displayName
        isRenaming = true
        renameFieldFocused = true
    }

    private func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([
            appState.sessionStore.rootDirectory.appendingPathComponent(node.relativePath)
        ])
    }

    private func commitRename() {
        guard let session else { return }
        if appState.rename(session, to: renameText) { isRenaming = false }
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
struct RecordingControlBar: View {
    let appState: AppState
    /// The app picked in the idle picker; nil = last recorded app, else the first playing one.

    var body: some View {
        VStack(alignment: .leading, spacing: RTheme.Spacing.sm) {
            if appState.isRecording {
                HStack(spacing: RTheme.Spacing.sm) {
                    RecordingDot()
                    Text(appState.t(.statusRecording)).font(.callout.weight(.medium))
                    Text(formattedDuration(appState.recordingElapsed)).font(.caption.monospacedDigit())
                    Spacer()
                    Text(appState.lastTargetDisplayName ?? "")
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                HStack(spacing: RTheme.Spacing.xs) {
                    Image(systemName: "mic").foregroundStyle(.secondary)
                    MicDeviceMenu(appState: appState)
                    Spacer()
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
                    MicDeviceMenu(appState: appState)
                    Spacer()
                }
                // Re-queried every 2s: which apps are playing sound changes
                // while the window sits idle (the list used to be read once,
                // so starting Zoom after opening Ryokuon never showed up).
                TimelineView(.periodic(from: .now, by: 2)) { _ in
                    // Real apps first, menu-bar audio utilities last (stable order otherwise).
                    let processes = appState.playingProcesses()
                    idleControls(processes: processes.filter { !$0.isMenuBarUtility }
                                 + processes.filter(\.isMenuBarUtility))
                }
            }
        }
        .padding(RTheme.Spacing.md)
    }

    /// Always one big, obvious start button (it used to be a dropdown on
    /// first launch, and picking an app from it started recording — easy
    /// to trigger by accident). The app to record is a separate, labelled
    /// picker; the button names it so there's no doubt what gets recorded.
    @ViewBuilder
    private func idleControls(processes: [AudioProcess]) -> some View {
        let target = appState.recordingTarget(in: processes)
        VStack(alignment: .leading, spacing: RTheme.Spacing.sm) {
            Label(appState.t(.recordTargetLabel), systemImage: "app.badge")
                .foregroundStyle(.secondary)
            if processes.isEmpty {
                Text(appState.t(.recordTargetNone)).foregroundStyle(.tertiary)
            } else {
                Menu {
                    ForEach(processes) { process in
                        Button { appState.selectedRecordingProcessID = process.pid } label: {
                            if process.pid == target?.pid {
                                Label(process.displayName, systemImage: "checkmark")
                            } else {
                                Text(process.displayName)
                            }
                        }
                    }
                } label: {
                    Text(target?.displayName ?? appState.t(.recordTargetChoose))
                        .lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .menuStyle(.borderlessButton)
            }
            Button {
                if let target { appState.start(target: target) }
            } label: {
                Label(target.map { appState.t(.startRecordingWithName, $0.displayName) } ?? appState.t(.startRecording),
                      systemImage: "record.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.large)
            .disabled(target == nil)

            if target == nil {
                Text(appState.t(appState.selectedRecordingProcessID == nil ? .noSoundApps : .recordTargetUnavailable))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Quick mic picker shown bottom-left on the main screen, both idle and
/// while recording — setting `selectedMicDeviceUID` mid-recording switches
/// the live capture's mic immediately (`AppState.selectedMicDeviceUID`'s
/// setter), not just the next recording's.
private struct MicDeviceMenu: View {
    let appState: AppState

    var body: some View {
        Menu {
            Button {
                appState.selectedMicDeviceUID = ""
            } label: {
                if appState.selectedMicDeviceUID.isEmpty {
                    Label(appState.t(.deviceSystemDefault), systemImage: "checkmark")
                } else {
                    Text(appState.t(.deviceSystemDefault))
                }
            }
            ForEach(appState.availableInputDevices()) { device in
                Button {
                    appState.selectedMicDeviceUID = device.uid
                } label: {
                    if appState.selectedMicDeviceUID == device.uid {
                        Label(device.name, systemImage: "checkmark")
                    } else {
                        Text(device.name)
                    }
                }
            }
        } label: {
            Text(appState.currentMicrophoneName)
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
        }
        .menuStyle(.borderlessButton)
        .frame(maxWidth: .infinity, alignment: .leading)
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
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Settings (separate sheet, kept off the main screen — priority #6)

/// Q7(전사 언어) + 앱 언어 + Q9(저장 폴더) — 전부 System Settings 스타일 Form.
struct SettingsSheetView: View {
    let appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var transcriptionLanguage: String
    @State private var appLanguage: String
    @State private var micDeviceUID: String
    @State private var outputDeviceUID: String
    @State private var updater = AppUpdater()

    init(appState: AppState) {
        self.appState = appState
        _transcriptionLanguage = State(initialValue: appState.language)
        _appLanguage = State(initialValue: appState.appLanguage)
        _micDeviceUID = State(initialValue: appState.selectedMicDeviceUID)
        _outputDeviceUID = State(initialValue: appState.selectedOutputDeviceUID)
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
                    Picker(appState.t(.settingsInputDevice), selection: $micDeviceUID) {
                        Text(appState.t(.deviceSystemDefault)).tag("")
                        ForEach(appState.availableInputDevices()) { device in
                            Text(device.name).tag(device.uid)
                        }
                    }
                    .onChange(of: micDeviceUID) { _, newValue in appState.selectedMicDeviceUID = newValue }

                    Picker(appState.t(.settingsOutputDevice), selection: $outputDeviceUID) {
                        Text(appState.t(.deviceSystemDefault)).tag("")
                        ForEach(appState.availableOutputDevices()) { device in
                            Text(device.name).tag(device.uid)
                        }
                    }
                    .onChange(of: outputDeviceUID) { _, newValue in appState.selectedOutputDeviceUID = newValue }
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
                        .disabled(!appState.canChangeStorageFolder)
                    if !appState.canChangeStorageFolder {
                        Text(appState.t(.errorOperationBusy)).font(.caption).foregroundStyle(.secondary)
                    }
                }

                Section(appState.t(.settingsUpdates)) {
                    LabeledContent(appState.t(.updateCurrentVersion)) {
                        Text(updater.currentVersion)
                    }
                    Button(appState.t(.updateCheck)) {
                        Task { await updater.check() }
                    }
                    .disabled(updater.isBusy)
                    switch updater.state {
                    case .idle: EmptyView()
                    case .checking:
                        ProgressView(appState.t(.updateChecking))
                    case .upToDate(let version):
                        Text(appState.t(.updateUpToDate, version)).foregroundStyle(.secondary)
                    case .available(let version):
                        Button(appState.t(.updateInstall, version)) {
                            Task { await updater.install(appState: appState) }
                        }
                        .disabled(!appState.canChangeStorageFolder)
                    case .preparing:
                        ProgressView(appState.t(.updatePreparing))
                    case .failed(let message):
                        Text(message).foregroundStyle(.red).textSelection(.enabled)
                    }
                }
                Section {
                    Link(appState.t(.reportIssue), destination: URL(string: "https://github.com/younnieCutler/ryokuon/issues/new/choose")!)
                    Text(appState.t(.privacySummary)).font(.caption).foregroundStyle(.secondary)
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
        .frame(minWidth: 360, idealWidth: 460, maxWidth: 620,
               minHeight: 380, idealHeight: 560, maxHeight: 720)
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
    @State private var query = ""
    @State private var showingExport = false
    @State private var showingRename = false
    @State private var followsPlayback = true
    /// transcript.txt exists — with `lines` empty this means a run finished
    /// but found no speech (nearly always the wrong language).
    @State private var hasTranscriptFile = false

    init(appState: AppState, session: Session) {
        self.appState = appState
        self.session = session
        _meGain = State(initialValue: session.gains.me)
        _remoteGain = State(initialValue: session.gains.remote)
    }

    private var isPlayingThis: Bool {
        appState.playingAudioPath?.hasPrefix(session.relativePath + "/") == true
    }
    private var isTranscribingThis: Bool { appState.transcribingSessionID == session.relativePath }
    private var isQueued: Bool { appState.isQueuedForTranscription(session.relativePath) }
    private var hasText: Bool { !lines.isEmpty }

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
                        TranscriptRow(line: line, query: query, isCurrent: line.id == currentLineID) {
                            appState.seekPlayback(session, toSeconds: line.startSeconds)
                        }
                            .id(line.id)
                            .contentShape(Rectangle())
                            .accessibilityAction { appState.seekPlayback(session, toSeconds: line.startSeconds) }
                    }
                    .listStyle(.plain)
                    .searchable(text: $query, prompt: appState.t(.searchPlaceholder))
                    .overlay {
                        if filteredLines.isEmpty { ContentUnavailableView.search(text: query) }
                    }
                    .onChange(of: currentLineID) { _, newValue in
                        guard followsPlayback, query.isEmpty, !appState.isPlaybackPaused, let newValue else { return }
                        withAnimation { proxy.scrollTo(newValue, anchor: .center) }
                    }
                }
            }

            Divider()
            CompactPlayerBar(appState: appState, session: session, meGain: $meGain, remoteGain: $remoteGain)
        }
        .onAppear { loadTranscript() }
        .onChange(of: appState.transcribingSessionID) { oldValue, _ in
            if oldValue == session.relativePath { loadTranscript() }
        }
        .onChange(of: appState.libraryRevision) { _, _ in loadTranscript() }
        .onChange(of: session.gains.me) { _, newValue in meGain = newValue }
        .onChange(of: session.gains.remote) { _, newValue in remoteGain = newValue }
        // Rename is explicit: typing a draft must not rewrite metadata on every keystroke.
        .navigationTitle(session.displayName)
        .toolbar {
            ToolbarItem {
                Button { showingRename = true } label: { Image(systemName: "pencil") }
                    .help(appState.t(.renameButton))
                    .accessibilityLabel(appState.t(.renameButton))
            }
            if hasText {
                ToolbarItem {
                    Button {
                        let text = filteredLines.map { "\(formattedDuration($0.startSeconds)) \($0.speaker): \($0.text)" }.joined(separator: "\n")
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    } label: { Image(systemName: "doc.on.doc") }
                    .help(appState.t(.copyTranscript))
                    .accessibilityLabel(appState.t(.copyTranscript))
                    .disabled(filteredLines.isEmpty)
                }
            }
            // Exactly one prominent button: the next step. No text yet ->
            // convert; text exists -> export. The other stays plain.
            ToolbarItem {
                transcribeMenu
                    .labelStyle(.titleAndIcon)
                    .modifier(ProminentIf(isOn: !hasText))
                    .disabled(isTranscribingThis || isQueued || session.state == .recording
                              || appState.exportingSessionIDs.contains(session.relativePath))
            }
            ToolbarItem {
                Button { showingExport = true } label: {
                    Label(appState.t(.exportButton), systemImage: "square.and.arrow.up")
                        .labelStyle(.titleAndIcon)
                }
                .modifier(ProminentIf(isOn: hasText))
                .disabled(!appState.canExport(session))
                .help(appState.t(.exportHelp))
                .keyboardShortcut("e", modifiers: [.command, .shift])
            }
        }
        .sheet(isPresented: $showingExport) {
            ExportSheet(appState: appState, session: session, utteranceStarts: lines.map(\.startSeconds))
        }
        .sheet(isPresented: $showingRename) {
            RenameSessionSheet(appState: appState, session: session)
        }
    }

    private var header: some View {
        HStack(spacing: RTheme.Spacing.sm) {
            Text("\(session.targetDisplayName) · \(formattedDuration(session.durationSeconds)) · \(appState.languageName(session.language))")
                .font(.caption)
                .foregroundStyle(.secondary)
            if session.state == .recovered {
                Label(appState.t(.recoveredBadge), systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            Spacer()
            if hasText {
                Toggle(appState.t(.followPlayback), isOn: $followsPlayback)
                    .toggleStyle(.button)
                    .font(.caption)
            }
            // Without text the centered empty state already shows progress.
            if isTranscribingThis, hasText, let progress = appState.transcribeProgress {
                Text(progress).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, RTheme.Spacing.lg)
        .padding(.vertical, RTheme.Spacing.sm)
    }

    /// Click = convert in the session's language; the menu picks another
    /// language and converts right away (and remembers it for the session).
    private var transcribeMenu: some View {
        Menu {
            Section(appState.t(.transcribeLanguageSection)) {
                ForEach(AppState.supportedLanguages, id: \.id) { option in
                    Button {
                        appState.transcribeSession(session, language: option.id)
                    } label: {
                        if option.id == session.language {
                            Label(appState.t(option.labelKey), systemImage: "checkmark")
                        } else {
                            Text(appState.t(option.labelKey))
                        }
                    }
                }
            }
        } label: {
            Label(hasText ? appState.t(.retranscribeButton) : appState.t(.transcribeButton),
                  systemImage: "captions.bubble")
        } primaryAction: {
            appState.transcribeSession(session)
        }
        .help(appState.t(.transcribeHelp))
    }

    @ViewBuilder
    private var emptyTranscriptState: some View {
        if isTranscribingThis || isQueued {
            VStack(spacing: RTheme.Spacing.md) {
                ProgressView()
                Text(isQueued ? appState.t(.transcribeQueued) : appState.t(.transcribeRunning))
                    .font(.headline)
                if isTranscribingThis, let progress = appState.transcribeProgress {
                    Text(progress).font(.callout).foregroundStyle(.secondary).monospacedDigit()
                }
                if isQueued {
                    Button(appState.t(.cancelQueued)) { appState.cancelQueuedTranscription(session) }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let foundNothing = hasTranscriptFile
            ContentUnavailableView {
                Label(foundNothing ? appState.t(.transcribeNoSpeechTitle) : appState.t(.notTranscribedYet),
                      systemImage: foundNothing ? "waveform.badge.exclamationmark" : "captions.bubble")
            } description: {
                Text(foundNothing
                     ? appState.t(.transcribeNoSpeechHint, appState.languageName(session.language))
                     : appState.t(.transcribeEmptyHint))
            } actions: {
                HStack(spacing: RTheme.Spacing.sm) {
                    Picker(appState.t(.transcribeLanguageSection), selection: Binding(
                        get: { session.language },
                        set: { appState.setLanguage(for: session, to: $0) }
                    )) {
                        ForEach(AppState.supportedLanguages, id: \.id) { option in
                            Text(appState.t(option.labelKey)).tag(option.id)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    Button {
                        appState.transcribeSession(session)
                    } label: {
                        Label(foundNothing ? appState.t(.retranscribeButton) : appState.t(.transcribeButton),
                              systemImage: "captions.bubble")
                    }
                    .buttonStyle(.borderedProminent)
                }
                .controlSize(.large)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func loadTranscript() {
        let path = appState.sessionStore.directory(for: session).appendingPathComponent("transcript.txt")
        guard let text = try? String(contentsOf: path, encoding: .utf8) else {
            lines = []
            hasTranscriptFile = false
            return
        }
        hasTranscriptFile = true
        lines = TranscriptBuilder.parse(text).enumerated().map { index, utterance in
            TranscriptLine(id: index, startMs: utterance.startMs, speaker: utterance.speaker, text: utterance.text)
        }
    }
}

private struct FolderDetailPane: View {
    let appState: AppState
    let node: AudioLibraryNode
    @Binding var selection: String?

    var body: some View {
        VStack(alignment: .leading, spacing: RTheme.Spacing.md) {
            Label(node.name, systemImage: "folder").font(.title2.bold())
            Text(node.relativePath).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            List(node.children) { child in
                Button { selection = child.relativePath } label: {
                    Label(appState.sessions.first { $0.relativePath == child.relativePath }?.displayName ?? child.name,
                          systemImage: child.isFolder ? "folder" : "waveform")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
            .overlay {
                if node.children.isEmpty {
                    ContentUnavailableView(appState.t(.emptyTitle), systemImage: "folder")
                }
            }
            Button(appState.t(.revealInFinder)) {
                NSWorkspace.shared.activateFileViewerSelecting([
                    appState.sessionStore.rootDirectory.appendingPathComponent(node.relativePath)
                ])
            }
        }
        .padding(RTheme.Spacing.lg)
        .navigationTitle(node.name)
    }
}

private struct RenameSessionSheet: View {
    let appState: AppState
    let session: Session
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var saveError: String?
    @FocusState private var isFocused: Bool

    init(appState: AppState, session: Session) {
        self.appState = appState
        self.session = session
        _name = State(initialValue: session.displayName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: RTheme.Spacing.md) {
            Text(appState.t(.renameButton)).font(.headline)
            TextField(appState.t(.sessionNamePlaceholder), text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)
            if let saveError { Text(saveError).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button(appState.t(.cancelButton)) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(appState.t(.confirmButton)) {
                    if appState.rename(session, to: name) { dismiss() }
                    else { saveError = appState.lastError }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(RTheme.Spacing.xl)
        .frame(minWidth: 320, idealWidth: 400)
        .onAppear { isFocused = true }
    }
}

/// Files that are not a Ryokuon session stay where Finder put them. Playback
/// reads the original bytes; importing into a transcribable session is explicit.
private struct ExternalAudioDetailPane: View {
    let appState: AppState
    let node: AudioLibraryNode
    @State private var duration: Double?
    @State private var fileError: String?
    @State private var isScrubbing = false
    @State private var scrubTime = 0.0

    private var isPlaying: Bool { appState.playingAudioPath == node.relativePath }
    private var isRunning: Bool { isPlaying && !appState.isPlaybackPaused }
    private var displayedTime: Double { isScrubbing ? scrubTime : (isPlaying ? appState.playbackTime : 0) }

    var body: some View {
        VStack(alignment: .leading, spacing: RTheme.Spacing.lg) {
            Label(node.name, systemImage: "waveform")
                .font(.title2.weight(.semibold))
                .lineLimit(2)
            Text(node.relativePath)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if let fileError {
                ContentUnavailableView(fileError, systemImage: "waveform.badge.exclamationmark")
            } else if let duration {
                HStack(spacing: RTheme.Spacing.sm) {
                    Button {
                        appState.toggleExternalPlayback(at: node.relativePath)
                    } label: {
                        Label(appState.t(isRunning ? .sessionPause : .sessionPlay),
                              systemImage: isRunning ? "pause.fill" : "play.fill")
                    }
                    Text(formattedDuration(displayedTime)).font(.caption.monospacedDigit())
                    Slider(value: Binding(
                        get: { min(displayedTime, duration) },
                        set: { scrubTime = $0 }
                    ), in: 0 ... max(duration, 0.01), onEditingChanged: { editing in
                        isScrubbing = editing
                        if !editing, duration > 0.05 {
                            appState.seekExternalPlayback(at: node.relativePath, toSeconds: scrubTime, duration: duration)
                        }
                    })
                    Text(formattedDuration(duration)).font(.caption.monospacedDigit())
                }
            } else {
                ProgressView()
            }
            Button {
                let url = appState.sessionStore.rootDirectory.appendingPathComponent(node.relativePath)
                appState.importAudio([url])
            } label: {
                Label(appState.t(.libraryImportForTranscription), systemImage: "square.and.arrow.down")
            }
            .disabled(appState.importingFileName != nil)
            Spacer(minLength: 0)
        }
        .padding(RTheme.Spacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle(node.name)
        .task(id: node.relativePath) { await loadDuration() }
        .onChange(of: node.stamp?.modifiedAt) { _, _ in Task { await loadDuration() } }
    }

    private func loadDuration() async {
        let url = appState.sessionStore.rootDirectory.appendingPathComponent(node.relativePath)
        do {
            let measured = try await Task.detached(priority: .utility) {
                let file = try AVAudioFile(forReading: url)
                return Double(file.length) / file.processingFormat.sampleRate
            }.value
            duration = measured
            fileError = nil
        } catch {
            duration = nil
            fileError = error.localizedDescription
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
    let onSeek: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: RTheme.Spacing.sm) {
            Button(action: onSeek) {
                Text(timestamp(line.startMs))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 44, alignment: .trailing)
            }
            .buttonStyle(.plain)
            Text(line.speaker)
                .font(.caption.bold())
                .foregroundStyle(line.speaker == "M" ? Color.accentColor : Color.secondary)
                .frame(width: 16)
            highlightedText
                .font(.callout)
                .textSelection(.enabled)
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

    private var isPlayingThis: Bool {
        appState.playingAudioPath?.hasPrefix(session.relativePath + "/") == true
    }
    private var duration: Double { max(session.durationSeconds, 0.01) }
    private var isRunning: Bool { isPlayingThis && !appState.isPlaybackPaused }

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
                    appState.togglePlayback(session)
                } label: {
                    Image(systemName: isRunning ? "pause.fill" : "play.fill")
                }
                .controlSize(.regular)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(session.state == .recording)
                .accessibilityLabel(appState.t(isRunning ? .sessionPause : .sessionPlay))
                .help(appState.t(isRunning ? .sessionPause : .sessionPlay))

                Button { appState.seekPlayback(session, toSeconds: displayTime - 10) } label: {
                    Image(systemName: "gobackward.10")
                }
                .disabled(session.state == .recording)
                .accessibilityLabel(appState.t(.skipBackward))
                .help(appState.t(.skipBackward))

                Button { appState.seekPlayback(session, toSeconds: displayTime + 10) } label: {
                    Image(systemName: "goforward.10")
                }
                .disabled(session.state == .recording)
                .accessibilityLabel(appState.t(.skipForward))
                .help(appState.t(.skipForward))

                Text(formattedDuration(displayTime)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Slider(value: Binding(
                    get: { min(displayTime, duration) }, // file can run a few ms past session.durationSeconds
                    set: { scrubTime = $0 }
                ), in: 0 ... duration, onEditingChanged: { editing in
                    isScrubbing = editing
                    if !editing { appState.seekPlayback(session, toSeconds: scrubTime) }
                })
                .disabled(session.state == .recording)
                .accessibilityLabel(appState.t(.playbackPosition))
                Text(formattedDuration(duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }

            // ME/REMOTE gain only exists for stereo — Player, Transcriber and
            // MP3Exporter all ignore it on mono, so the sliders would do nothing.
            if session.channels == 2 {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: RTheme.Spacing.lg) {
                        gainControls
                    }
                    VStack(spacing: RTheme.Spacing.sm) { gainControls }
                }
            }
        }
        .padding(RTheme.Spacing.md)
    }

    @ViewBuilder private var gainControls: some View {
        GainControl(label: appState.t(.gainMe), tint: .accentColor, value: $meGain) {
            appState.setGains(for: session, me: meGain, remote: remoteGain)
        }
        GainControl(label: appState.t(.gainRemote), tint: .secondary, value: $remoteGain) {
            appState.setGains(for: session, me: meGain, remote: remoteGain)
        }
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

/// The M4A-to-MP3.html workflow, per session: tick MP3 and/or MD, drag a
/// range on the waveform (default: all), export. Files land in the
/// session folder and Finder opens on them.
struct ExportSheet: View {
    let appState: AppState
    let session: Session
    /// Transcript line start times — empty means "not transcribed yet".
    let utteranceStarts: [Double]
    @Environment(\.dismiss) private var dismiss
    @State private var start: Double = 0
    @State private var end: Double
    @State private var bitrate = 64
    @State private var exportMP3: Bool
    @State private var exportMD: Bool
    @State private var peaks: [Float]?
    @State private var isExporting = false
    @State private var isPreviewing = false
    @State private var exportError: String?
    @State private var outputDirectory: URL
    @State private var showingOverwrite = false

    init(appState: AppState, session: Session, utteranceStarts: [Double], peaks: [Float]? = nil) {
        self.appState = appState
        self.session = session
        self.utteranceStarts = utteranceStarts
        _end = State(initialValue: session.durationSeconds)
        _exportMP3 = State(initialValue: MP3Exporter.lameURL != nil)
        _exportMD = State(initialValue: !utteranceStarts.isEmpty)
        _peaks = State(initialValue: peaks)
        _outputDirectory = State(initialValue: appState.sessionStore.directory(for: session))
    }

    private var hasTranscript: Bool { !utteranceStarts.isEmpty }
    private var hasLame: Bool { MP3Exporter.lameURL != nil }
    private var isFullRange: Bool { start <= 0 && end >= session.durationSeconds }
    private var utterancesInRange: Int { utteranceStarts.filter { $0 >= start && $0 <= end }.count }
    private var playhead: Double? {
        appState.playingAudioPath?.hasPrefix(session.relativePath + "/") == true
            ? appState.playbackTime : nil
    }

    /// `bitrate * seconds / 8` — what lame's CBR output actually comes to.
    private var estimatedSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(Double(bitrate * 1000) * (end - start) / 8), countStyle: .file)
    }

    private var runTitle: String {
        let formats = [exportMP3 ? "MP3" : nil, exportMD ? "MD" : nil].compactMap { $0 }
        return formats.isEmpty ? appState.t(.exportRun) : appState.t(.exportRunFormats, formats.joined(separator: " + "))
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: RTheme.Spacing.lg) {
                    VStack(alignment: .leading, spacing: RTheme.Spacing.xs) {
                        Text(appState.t(.exportTitle)).font(.title3.bold())
                        Text(session.displayName).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    }

                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: RTheme.Spacing.md) { formatCards }
                        VStack(spacing: RTheme.Spacing.sm) { formatCards }
                    }

                    rangeEditor

                    VStack(alignment: .leading, spacing: RTheme.Spacing.xs) {
                        Text(appState.t(.exportFolder)).font(.caption).foregroundStyle(.secondary)
                        Text(outputDirectory.path).font(.caption).lineLimit(2).textSelection(.enabled)
                        Button(appState.t(.chooseExportFolder)) { chooseOutputDirectory() }
                    }

                    if exportMP3 {
                        ViewThatFits(in: .horizontal) {
                            HStack { qualityControls }
                            VStack(alignment: .leading) { qualityControls }
                        }
                    }

                    if !hasLame {
                        Label(appState.t(.lameMissing), systemImage: "info.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }

                    if let exportError {
                        Text(exportError).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                    }
                }
                .padding(RTheme.Spacing.xl)
            }
            .disabled(isExporting)
            Divider()
            HStack {
                if isExporting { ProgressView().controlSize(.small) }
                Spacer()
                Button(appState.t(.cancelButton)) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isExporting)
                Button(runTitle) { requestExport() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(isExporting || end - start < 0.5 || !(exportMP3 || exportMD))
            }
            .padding(RTheme.Spacing.md)
        }
        .frame(minWidth: 360, idealWidth: 500, maxWidth: 720,
               minHeight: 360, idealHeight: 540, maxHeight: 760)
        .interactiveDismissDisabled(isExporting)
        .confirmationDialog(appState.t(.overwriteTitle), isPresented: $showingOverwrite, titleVisibility: .visible) {
            Button(appState.t(.overwriteConfirm), role: .destructive) { runExport(allowOverwrite: true) }
            Button(appState.t(.cancelButton), role: .cancel) {}
        } message: {
            Text(appState.t(.overwriteMessage))
        }
        .animation(.easeOut(duration: 0.15), value: exportMP3)
        .task {
            guard peaks == nil, let url = AudioCapture.audioFileURL(in: appState.sessionStore.directory(for: session))
            else { return }
            peaks = (try? await Task.detached { try Waveform.peaks(of: url, buckets: 160) }.value) ?? []
        }
        // Preview stops itself at the range end instead of playing on.
        .onChange(of: appState.playbackTime) { _, time in
            if isPreviewing && time >= end { stopPreview() }
        }
        .onChange(of: appState.isPlaybackPaused) { _, paused in
            if paused { isPreviewing = false }
        }
        .onDisappear { if isPreviewing { stopPreview() } }
    }

    @ViewBuilder private var formatCards: some View {
        FormatCard(title: "MP3", subtitle: appState.t(.formatMP3Subtitle), systemImage: "waveform",
                   detail: hasLame ? estimatedSize : appState.t(.formatNeedsLame),
                   isOn: $exportMP3, isAvailable: hasLame)
        FormatCard(title: "MD", subtitle: appState.t(.formatMDSubtitle), systemImage: "doc.text",
                   detail: hasTranscript ? appState.t(.formatUtterances, utterancesInRange)
                                         : appState.t(.formatNeedsTranscript),
                   isOn: $exportMD, isAvailable: hasTranscript)
    }

    @ViewBuilder private var qualityControls: some View {
        Text(appState.t(.exportQuality))
        Picker(appState.t(.exportQuality), selection: $bitrate) {
            Text(appState.t(.qualityVoice)).tag(64)
            Text(appState.t(.qualityCompact)).tag(96)
            Text(appState.t(.qualityStandard)).tag(128)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    private var rangeEditor: some View {
        VStack(alignment: .leading, spacing: RTheme.Spacing.sm) {
            Text(appState.t(.exportRangeHint)).font(.caption).foregroundStyle(.secondary)
            Group {
                if let peaks {
                    WaveformRangeView(peaks: peaks, duration: session.durationSeconds,
                                      start: $start, end: $end, playhead: playhead)
                } else {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(height: 72)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))

            HStack(spacing: RTheme.Spacing.sm) {
                Text("\(formattedDuration(start)) – \(formattedDuration(end))")
                    .font(.callout.monospacedDigit())
                Text(appState.t(.exportLength, formattedDuration(end - start)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: RTheme.Spacing.md) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(appState.t(.rangeStart)).font(.caption).foregroundStyle(.secondary)
                    TextField(appState.t(.rangeStart), value: Binding(
                        get: { start },
                        set: { value in
                            guard value.isFinite else { return }
                            start = min(max(value, 0), max(0, end - 0.5))
                        }
                    ), format: .number.precision(.fractionLength(0...2)))
                    .textFieldStyle(.roundedBorder)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(appState.t(.rangeEnd)).font(.caption).foregroundStyle(.secondary)
                    TextField(appState.t(.rangeEnd), value: Binding(
                        get: { end },
                        set: { value in
                            guard value.isFinite else { return }
                            end = min(max(value, start + 0.5), session.durationSeconds)
                        }
                    ), format: .number.precision(.fractionLength(0...2)))
                    .textFieldStyle(.roundedBorder)
                }
            }
            HStack {
                Spacer(minLength: 0)
                Button(appState.t(.exportAll)) {
                    start = 0
                    end = session.durationSeconds
                }
                .disabled(isFullRange)
                Button {
                    if isPreviewing { stopPreview() } else { startPreview() }
                } label: {
                    Label(isPreviewing ? appState.t(.sessionStop) : appState.t(.exportPreview),
                          systemImage: isPreviewing ? "stop.fill" : "play.fill")
                }
                .disabled(end - start < 0.5)
            }
            .controlSize(.small)
        }
    }

    private func startPreview() {
        appState.play(session, from: start)
        isPreviewing = appState.playingAudioPath?.hasPrefix(session.relativePath + "/") == true
            && !appState.isPlaybackPaused
    }

    private func stopPreview() {
        appState.stopPlayback()
        isPreviewing = false
    }

    private func chooseOutputDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = outputDirectory
        if panel.runModal() == .OK, let url = panel.url { outputDirectory = url }
    }

    private func requestExport() {
        guard let plan = try? SessionExportPlan(session: session, range: start ... end, directory: outputDirectory,
                                               mp3: exportMP3, markdown: exportMD) else { return }
        if plan.existingURLs.isEmpty { runExport() }
        else { showingOverwrite = true }
    }

    private func runExport(allowOverwrite: Bool = false) {
        isExporting = true
        exportError = nil
        if isPreviewing { stopPreview() }
        Task {
            let succeeded = await appState.export(session, range: start ... end, bitrate: bitrate,
                                  mono: bitrate < 128 || session.channels == 1,
                                  mp3: exportMP3, markdown: exportMD,
                                  destination: outputDirectory, allowOverwrite: allowOverwrite)
            isExporting = false
            if succeeded { dismiss() } else { exportError = appState.lastError }
        }
    }
}

/// One tappable format tile — checked = accent border + tint, like the
/// selectable tiles in System Settings. Unavailable tiles stay visible
/// (greyed, with the reason as the detail line) instead of disappearing.
private struct FormatCard: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let detail: String
    @Binding var isOn: Bool
    let isAvailable: Bool

    var body: some View {
        Button { isOn.toggle() } label: {
            HStack(alignment: .top, spacing: RTheme.Spacing.sm) {
                Image(systemName: systemImage)
                    .font(.title2)
                    .foregroundStyle(isOn ? Color.accentColor : .secondary)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    Text(detail).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isOn ? Color.accentColor : Color.secondary.opacity(0.5))
            }
            .padding(RTheme.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isOn ? Color.accentColor.opacity(0.1) : Color.secondary.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isOn ? Color.accentColor : Color.secondary.opacity(0.2), lineWidth: isOn ? 2 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(!isAvailable)
        .opacity(isAvailable ? 1 : 0.55)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// Voice Memos-style trim strip: bars inside the range in the accent
/// color, outside dimmed. Drag near an edge to move it, drag anywhere else
/// to draw a new range.
struct WaveformRangeView: View {
    let peaks: [Float]
    let duration: Double
    @Binding var start: Double
    @Binding var end: Double
    let playhead: Double?

    private enum DragTarget { case start, end, new(anchor: Double) }
    @State private var dragTarget: DragTarget?
    private let handleHitWidth: CGFloat = 22

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let x = { (time: Double) in CGFloat(time / max(duration, 0.01)) * width }

            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Color.accentColor.opacity(0.1))
                    .frame(width: max(0, x(end) - x(start)))
                    .offset(x: x(start))

                Canvas { context, size in
                    guard !peaks.isEmpty else { return }
                    let step = size.width / CGFloat(peaks.count)
                    for (index, peak) in peaks.enumerated() {
                        let time = (Double(index) + 0.5) / Double(peaks.count) * duration
                        let height = max(2, CGFloat(peak) * (size.height - 12))
                        let bar = CGRect(x: CGFloat(index) * step + step * 0.2, y: (size.height - height) / 2,
                                         width: max(1, step * 0.6), height: height)
                        let inRange = time >= start && time <= end
                        context.fill(Path(roundedRect: bar, cornerRadius: bar.width / 2),
                                     with: .color(inRange ? .accentColor : .secondary.opacity(0.35)))
                    }
                }

                // Clamped so a full-range handle isn't half cut off at the edge.
                handle.offset(x: min(max(x(start) - 1.5, 0), width - 3))
                handle.offset(x: min(max(x(end) - 1.5, 0), width - 3))

                if let playhead {
                    Rectangle().fill(.primary).frame(width: 1).offset(x: x(playhead))
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                guard width > 0, duration > 0 else { return }
                let time = min(max(Double(value.location.x / width) * duration, 0), duration)
                if dragTarget == nil {
                    let startX = value.startLocation.x
                    if abs(startX - x(start)) <= handleHitWidth { dragTarget = .start }
                    else if abs(startX - x(end)) <= handleHitWidth { dragTarget = .end }
                    else { dragTarget = .new(anchor: Double(startX / width) * duration) }
                }
                switch dragTarget {
                case .start: start = min(time, max(0, end - 0.5))
                case .end: end = min(duration, max(time, start + 0.5))
                case .new(let anchor):
                    start = min(anchor, time)
                    end = max(anchor, time)
                case nil: break
                }
            }.onEnded { _ in dragTarget = nil })
        }
        .accessibilityElement()
        .accessibilityLabel(Text("\(formattedDuration(start)) – \(formattedDuration(end))"))
    }

    private var handle: some View {
        Capsule().fill(Color.accentColor).frame(width: 3)
            .padding(.vertical, 4)
    }
}

/// Toolbar emphasis that moves with the workflow — `.glassProminent` is the
/// macOS 26 primary-action style; everything else keeps the default glass.
private struct ProminentIf: ViewModifier {
    let isOn: Bool
    func body(content: Content) -> some View {
        if isOn { content.buttonStyle(.glassProminent) } else { content }
    }
}
