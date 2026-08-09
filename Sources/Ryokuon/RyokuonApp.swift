import AppKit
import SwiftUI

struct RyokuonApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Ryokuon", id: "main") {
            MainWindowView(appState: appDelegate.appState)
        }
        .windowResizability(.contentSize)
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
        NSApp.setActivationPolicy(.accessory) // menu bar utility, no Dock icon

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = Self.statusImage(symbol: "waveform")
        item.menu = buildMenu()
        statusItem = item

        withObservationTracking {
            _ = appState.isRecording
            _ = appState.silenceWarning
        } onChange: { [weak self] in
            Task { @MainActor in self?.refreshStatusItem() }
        }
    }

    private func refreshStatusItem() {
        let symbol: String
        if appState.isRecording {
            symbol = "record.circle.fill"
        } else if appState.silenceWarning != nil {
            symbol = "exclamationmark.triangle.fill"
        } else {
            symbol = "waveform"
        }
        statusItem?.button?.image = Self.statusImage(symbol: symbol)
        statusItem?.menu = buildMenu()

        // Observation tracking only fires once per registration — re-arm it.
        withObservationTracking {
            _ = appState.isRecording
            _ = appState.silenceWarning
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

        if appState.isRecording {
            menu.addItem(withTitle: "녹음 종료", action: #selector(stopRecording), keyEquivalent: "")
                .target = self
        } else if let name = appState.lastTargetDisplayName {
            menu.addItem(withTitle: "녹음 시작 — \(name)", action: #selector(startWithLastTarget), keyEquivalent: "")
                .target = self
        }

        let pickerItem = NSMenuItem(title: "다른 앱 선택", action: nil, keyEquivalent: "")
        pickerItem.isEnabled = !appState.isRecording
        let submenu = NSMenu()
        let processes = appState.playingProcesses()
        if processes.isEmpty {
            submenu.addItem(withTitle: "지금 소리 내는 앱 없음", action: nil, keyEquivalent: "")
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

        if let warning = appState.silenceWarning {
            menu.addItem(withTitle: warning, action: nil, keyEquivalent: "")
        }

        menu.addItem(withTitle: "세션 목록 열기", action: #selector(openSessionWindow), keyEquivalent: "")
            .target = self

        menu.addItem(.separator())
        menu.addItem(withTitle: "종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

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
