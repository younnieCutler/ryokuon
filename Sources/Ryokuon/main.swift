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
    let channels = CaptureDevice.isBuiltInMicActive() ? 1 : 2
    let capture = try AudioCapture(process: target, outputDirectory: outputDirectory, channels: channels)
    print(capture.diagnostics)

    capture.onLevel = { me, remote in
        print(String(format: "  me %6.1f dB   remote %6.1f dB", me, remote))
    }

    try capture.start()
    print("recording \(seconds)s from \(target.displayName) — talk into the mic")
    Thread.sleep(forTimeInterval: seconds)
    try capture.stop()

    print("\n\(capture.framesWritten) frames -> \(outputDirectory.appendingPathComponent(AudioCapture.fileName).path)")
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
    let channels = CaptureDevice.isBuiltInMicActive() ? 1 : 2
    let (_, directory) = try store.createSession(language: "ja-JP", targetBundleID: target.bundleID,
                                                 targetDisplayName: target.displayName, channels: channels)
    let capture = try AudioCapture(process: target, outputDirectory: directory, channels: channels)
    try capture.start()
    print("crash-simulating recording to \(directory.path) for \(seconds)s, then exiting uncleanly")
    Thread.sleep(forTimeInterval: seconds)
    // No capture.stop(), no session.state update — deliberately.
}

/// locale override lets this agent verify the pipeline against test audio
/// recorded in a language other than the session's stored default (Q7:
/// ja-JP default, but nothing stops recording/transcribing in ko-KR/en-US).
func transcribe(sessionDirectory: URL, locale: String?) async throws {
    let store = SessionStore(rootDirectory: sessionDirectory.deletingLastPathComponent())
    let session = try store.load(from: sessionDirectory)
    var resolved = locale ?? session.language
    if resolved == Transcriber.autoLanguage {
        resolved = try await Transcriber.detectLanguage(sessionDirectory: sessionDirectory) { print($0) }
        print("detected language: \(resolved)")
    }
    let words = try await Transcriber.transcribe(
        sessionDirectory: sessionDirectory, locale: resolved,
        meGain: session.gains.me, remoteGain: session.gains.remote
    ) { print($0) }
    print("\n\(words.count) words -> \(sessionDirectory.appendingPathComponent("raw.json").path)")
    for word in words {
        print("\(word.startMs)|\(word.speaker)|\(word.confidence < 0.5 ? "?" : "")\(word.text)")
    }

    // Q3: call.wav isn't needed once it's transcribed — convert to FLAC and
    // drop the original. Only if call.wav is actually still there (running
    // `transcribe` again on an already-converted session is a no-op here).
    if FileManager.default.fileExists(atPath: sessionDirectory.appendingPathComponent(AudioCapture.fileName).path) {
        let flacURL = try FLACConverter.convert(sessionDirectory: sessionDirectory)
        print("converted -> \(flacURL.path)")
    }
}

/// Reads raw.json (step 3's output) and writes transcript.txt (the compact
/// format AI reads). Separate from `transcribe` so re-tuning the merge
/// (gap threshold, confidence cutoff) doesn't require re-running STT.
func build(sessionDirectory: URL) throws {
    let data = try Data(contentsOf: sessionDirectory.appendingPathComponent("raw.json"))
    let words = try JSONDecoder().decode([TranscriptWord].self, from: data)
    let utterances = TranscriptBuilder.build(from: words)
    try TranscriptBuilder.writeTranscript(utterances, to: sessionDirectory.appendingPathComponent("transcript.txt"))
    print("\(utterances.count) utterances -> \(sessionDirectory.appendingPathComponent("transcript.txt").path)")
    for utterance in utterances {
        print(TranscriptBuilder.format(utterance))
    }
}

func recover(storageRoot: URL) throws {
    let store = SessionStore(rootDirectory: storageRoot)
    let recovered = store.recoverCrashedSessions()
    print("recovered \(recovered.count) session(s)")
    for session in recovered {
        print("  \(session.id): \(session.durationSeconds)s, state=\(session.state.rawValue)")
    }
}

// One writer process per user, including the developer commands. Read-only
// process listing can run alongside the GUI. Tests use isolated temporary roots.
var processLease: ProcessLease?
if arguments.first != "list" {
    do {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        processLease = try ProcessLease(directory: support.appendingPathComponent("Ryokuon"))
    } catch {
        FileHandle.standardError.write(Data("Ryokuon is already running or its process lock is unavailable: \(error)\n".utf8))
        exit(1)
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
    case "transcribe":
        guard arguments.count >= 2 else {
            print("usage: ryokuon transcribe <sessionDir> [locale]")
            exit(1)
        }
        // `dispatchMain()`, not a semaphore: Speech.framework delivers XPC
        // replies via the main dispatch queue, so blocking the main thread
        // with `DispatchSemaphore.wait()` starves that queue and deadlocks
        // forever (found by hanging + `sample` showing only 1 thread, i.e.
        // the Task never got to run at all).
        Task {
            do {
                try await transcribe(sessionDirectory: URL(fileURLWithPath: arguments[1]),
                                     locale: arguments.count >= 3 ? arguments[2] : nil)
                exit(0)
            } catch {
                FileHandle.standardError.write("error: \(error)\n".data(using: .utf8)!)
                exit(1)
            }
        }
        dispatchMain()
    case "build":
        guard arguments.count >= 2 else {
            print("usage: ryokuon build <sessionDir>")
            exit(1)
        }
        try build(sessionDirectory: URL(fileURLWithPath: arguments[1]))
    default:
        print("unknown command: \(arguments[0])")
        exit(1)
    }
}
