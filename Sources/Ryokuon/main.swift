import Foundation
import SwiftUI

// Single entry point. No arguments -> the real menu bar app (RyokuonApp).
// Arguments present -> the dev CLI from steps 0-1, kept because it's the
// only way this agent can drive and verify capture end-to-end — there's no
// way to click a native macOS permission dialog or menu bar item here, so
// verification stays on this path even after the GUI exists.

let arguments = Array(CommandLine.arguments.dropFirst())

func listProcesses() throws {
    print("obj    pid    out  bundleID / name")
    for process in try listAudioProcesses().sorted(by: { $0.pid < $1.pid }) {
        print(String(format: "%-6d %-6d %-4@ %@",
                     process.objectID, process.pid,
                     (process.isPlaying ? "♪" : "-") as NSString,
                     process.bundleID ?? "(no bundle) \(process.displayName)"))
    }
    print("\nusage: ryokuon record <bundleID|pid:N> <seconds> <outputDir>")
    print("       ryokuon recover <storageRoot>")
}

func record(selector: String, seconds: Double, outputDirectory: URL) throws {
    let processes = try listAudioProcesses()
    let target: AudioProcess?
    if selector.hasPrefix("pid:"), let pid = pid_t(selector.dropFirst(4)) {
        target = processes.first { $0.pid == pid }
    } else {
        target = processes.first { $0.bundleID == selector }
    }
    guard let target else {
        print("no audio process matching \(selector)")
        exit(1)
    }

    try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    let capture = try AudioCapture(process: target, outputDirectory: outputDirectory)
    print(capture.diagnostics)

    capture.onLevel = { me, remote in
        print(String(format: "  me %6.1f dB   remote %6.1f dB", me, remote))
    }

    try capture.start()
    print("recording \(seconds)s from \(target.displayName) — talk into the mic")
    Thread.sleep(forTimeInterval: seconds)
    try capture.stop()

    print("\nme:     \(capture.meFramesWritten) frames -> \(outputDirectory.appendingPathComponent("me.wav").path)")
    print("remote: \(capture.remoteFramesWritten) frames -> \(outputDirectory.appendingPathComponent("remote.wav").path)")
}

/// Simulates the exact scenario Q11 exists for: create a session, write
/// audio, and exit WITHOUT calling capture.stop() — i.e. without patching
/// the WAV header or setting state to .finished. A real crash (kill -9)
/// looks identical from SessionStore's point of view.
func crashDuring(selector: String, seconds: Double, storageRoot: URL) throws {
    let processes = try listAudioProcesses()
    guard let target = processes.first(where: { $0.bundleID == selector || "pid:\(($0.pid))" == selector })
    else {
        print("no audio process matching \(selector)")
        exit(1)
    }
    let store = SessionStore(rootDirectory: storageRoot)
    let (_, directory) = try store.createSession(language: "ja-JP", target: target)
    let capture = try AudioCapture(process: target, outputDirectory: directory)
    try capture.start()
    print("crash-simulating recording to \(directory.path) for \(seconds)s, then exiting uncleanly")
    Thread.sleep(forTimeInterval: seconds)
    // No capture.stop(), no session.state update — deliberately.
}

func recover(storageRoot: URL) throws {
    let store = SessionStore(rootDirectory: storageRoot)
    let recovered = store.recoverCrashedSessions()
    print("recovered \(recovered.count) session(s)")
    for session in recovered {
        print("  \(session.id): \(session.durationSeconds)s, state=\(session.state.rawValue)")
    }
}

if arguments.isEmpty {
    RyokuonApp.main()
} else {
    switch arguments[0] {
    case "list":
        try listProcesses()
    case "record":
        guard arguments.count >= 4 else {
            print("usage: ryokuon record <bundleID|pid:N> <seconds> <outputDir>")
            exit(1)
        }
        try record(selector: arguments[1], seconds: Double(arguments[2]) ?? 5,
                  outputDirectory: URL(fileURLWithPath: arguments[3]))
    case "crash-during":
        guard arguments.count >= 4 else {
            print("usage: ryokuon crash-during <bundleID|pid:N> <seconds> <storageRoot>")
            exit(1)
        }
        try crashDuring(selector: arguments[1], seconds: Double(arguments[2]) ?? 5,
                        storageRoot: URL(fileURLWithPath: arguments[3]))
    case "recover":
        guard arguments.count >= 2 else {
            print("usage: ryokuon recover <storageRoot>")
            exit(1)
        }
        try recover(storageRoot: URL(fileURLWithPath: arguments[1]))
    default:
        print("unknown command: \(arguments[0])")
        exit(1)
    }
}
