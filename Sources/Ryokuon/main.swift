import Foundation

// Temporary CLI entry point for step 1 verification only. Step 2 replaces
// this file with RyokuonApp.swift (SwiftUI MenuBarExtra) — the capture
// engine underneath (AudioCapture, WAVWriter, CaptureDevice) doesn't change.

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

guard !arguments.isEmpty else {
    try listProcesses()
    exit(0)
}

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
default:
    print("unknown command: \(arguments[0])")
    exit(1)
}
