import AppKit
import SwiftUI

struct RyokuonApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Ryokuon", id: "main") {
            MainWindowView(appState: appDelegate.appState)
        }
        .defaultSize(width: 1040, height: 720)
        .commands {
            CommandGroup(after: .newItem) {
                Button(appDelegate.appState.t(.importButton)) { appDelegate.appState.presentImportPanel() }
                    .keyboardShortcut("i", modifiers: .command)
                Button(appDelegate.appState.t(.addBookmark)) { appDelegate.appState.bookmarkCurrentRecording() }
                    .keyboardShortcut("b", modifiers: [.command, .shift])
                    .disabled(!appDelegate.appState.isRecording)
            }
        }
    }
}

/// SwiftUI's `MenuBarExtra` renders nothing on this build (macOS 26.6): the
/// status item shows up correctly in the accessibility tree with the right
/// frame, both with a `Text` label and an `Image(systemName:)` label, but
/// paints zero pixels — confirmed by screenshot at 3x contrast/2x
/// brightness, reproduced across two clean relaunches. Plain `NSStatusItem`
/// is the fallback: mature API, not dependent on whatever `MenuBarExtra`'s
/// hosting is doing wrong here.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = Self.statusImage(symbol: "waveform")
        item.button?.toolTip = "Ryokuon"
        item.menu = buildMenu()
        statusItem = item

        withObservationTracking {
            _ = appState.isRecording
            _ = appState.silenceWarning
            _ = appState.transcribingSessionID
            _ = appState.importingFileName
            _ = appState.exportingSessionIDs
        } onChange: { [weak self] in
            Task { @MainActor in self?.refreshStatusItem() }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if appState.importingFileName != nil || !appState.exportingSessionIDs.isEmpty {
            let alert = NSAlert()
            alert.messageText = appState.t(.quitBusyTitle)
            alert.informativeText = appState.t(.quitBusyHint)
            alert.addButton(withTitle: appState.t(.confirmButton))
            alert.runModal()
            return .terminateCancel
        }
        if appState.isRecording {
            let alert = NSAlert()
            alert.messageText = appState.t(.quitRecordingTitle)
            alert.informativeText = appState.t(.quitRecordingHint)
            alert.addButton(withTitle: appState.t(.cancelButton))
            alert.addButton(withTitle: appState.t(.quitSave))
            guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
            appState.stop(automaticallyTranscribe: false)
        }
        return .terminateNow
    }

    @objc private func willSleep() {
        guard appState.isRecording else { return }
        appState.stop(automaticallyTranscribe: false)
        appState.lastError = appState.t(.errorSleepStopped)
    }

    private func refreshStatusItem() {
        let symbol: String
        switch appState.runState {
        case .recording: symbol = "record.circle.fill"
        case .processing: symbol = "arrow.triangle.2.circlepath"
        case .ready: symbol = appState.silenceWarning != nil ? "exclamationmark.triangle.fill" : "waveform"
        }
        statusItem?.button?.image = Self.statusImage(symbol: symbol)
        statusItem?.menu = buildMenu()

        // Observation tracking only fires once per registration — re-arm it.
        withObservationTracking {
            _ = appState.isRecording
            _ = appState.silenceWarning
            _ = appState.transcribingSessionID
            _ = appState.importingFileName
            _ = appState.exportingSessionIDs
        } onChange: { [weak self] in
            Task { @MainActor in self?.refreshStatusItem() }
        }
    }

    /// `NSImage(systemSymbolName:accessibilityDescription:)` does not set
    /// `isTemplate` — without it the glyph renders in its default color
    /// (black) instead of adapting to the menu bar, which on a dark menu bar
    /// is black-on-black. This was the actual cause of the "invisible status
    /// item" — not a SwiftUI bug, not a screenshot pipeline issue.
    private static func statusImage(symbol: String) -> NSImage? {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Ryokuon")
        image?.isTemplate = true
        return image
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        // Status panel: state, elapsed time, ME/REMOTE meters, current
        // mic/capture target. A custom NSMenuItem view (NSHostingView) is
        // the only way to get live SwiftUI content — plain menu items are
        // static text, and MenuBarExtra doesn't render on this OS build.
        let panelItem = NSMenuItem()
        panelItem.view = NSHostingView(rootView: MenuBarPanelView(appState: appState).frame(width: 220))
        menu.addItem(panelItem)
        menu.addItem(.separator())

        if appState.isRecording {
            menu.addItem(withTitle: appState.t(.recordingStop), action: #selector(stopRecording), keyEquivalent: "")
                .target = self
        } else if let name = appState.lastTargetDisplayName {
            menu.addItem(withTitle: appState.t(.startRecordingWithName, name),
                        action: #selector(startWithLastTarget), keyEquivalent: "")
                .target = self
        }

        let pickerItem = NSMenuItem(title: appState.t(.pickAnotherApp), action: nil, keyEquivalent: "")
        pickerItem.isEnabled = !appState.isRecording
        let submenu = NSMenu()
        let processes = appState.playingProcesses()
        if processes.isEmpty {
            submenu.addItem(withTitle: appState.t(.menuNoSoundApps), action: nil, keyEquivalent: "")
        } else {
            for process in processes {
                let entry = submenu.addItem(withTitle: process.displayName,
                                            action: #selector(startWithPicked(_:)), keyEquivalent: "")
                entry.target = self
                entry.representedObject = process
            }
        }
        pickerItem.submenu = submenu
        menu.addItem(pickerItem)

        menu.addItem(.separator())

        menu.addItem(withTitle: appState.t(.menuOpenSessions), action: #selector(openSessionWindow), keyEquivalent: "")
            .target = self

        menu.addItem(.separator())
        menu.addItem(withTitle: appState.t(.menuQuit), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        return menu
    }

    @objc private func stopRecording() { appState.stop() }
    @objc private func startWithLastTarget() { appState.startWithLastTarget() }

    @objc private func startWithPicked(_ sender: NSMenuItem) {
        guard let process = sender.representedObject as? AudioProcess else { return }
        appState.start(target: process)
    }

    @objc private func openSessionWindow() {
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.identifier?.rawValue == "main" {
            window.makeKeyAndOrderFront(nil)
        }
    }
}

/// Menu bar status panel — state / duration / ME·REMOTE meters / current
/// mic & capture target, all in one glance without opening the main
/// window, per the brief's menu bar spec.
private struct MenuBarPanelView: View {
    let appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if appState.runState == .recording { RecordingDot() }
                Text(appState.runStateText()).font(.headline)
                Spacer()
                if appState.isRecording {
                    Text(formattedDuration(appState.recordingElapsed))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            if appState.isRecording {
                HStack(spacing: 12) {
                    LevelMeter(label: appState.t(.gainMe), tint: .accentColor, db: appState.meLevelDB)
                    LevelMeter(label: appState.t(.gainRemote), tint: .secondary, db: appState.remoteLevelDB)
                }
            }

            Divider()

            HStack(spacing: 4) {
                Image(systemName: "mic").foregroundStyle(.secondary)
                Text(appState.t(.currentMicLabel)).foregroundStyle(.secondary)
                Spacer()
                Text(appState.currentMicrophoneName).lineLimit(1).truncationMode(.middle)
            }
            .font(.caption)

            HStack(spacing: 4) {
                Image(systemName: "app.badge").foregroundStyle(.secondary)
                Text(appState.t(.currentAppLabel)).foregroundStyle(.secondary)
                Spacer()
                Text(appState.lastTargetDisplayName ?? "—").lineLimit(1).truncationMode(.middle)
            }
            .font(.caption)
        }
        .padding(10)
    }
}
