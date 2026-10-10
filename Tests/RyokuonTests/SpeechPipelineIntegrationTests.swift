import AVFoundation
import Foundation
import Testing
@testable import Ryokuon

/// Explicit opt-in: installs Apple's speech assets and uses only synthetic
/// audio inside a temporary folder. No microphone, TCC prompt or user library.
@Suite(.serialized)
struct SpeechPipelineIntegrationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["RYOKUON_SPEECH_E2E"] == "1"),
          arguments: ["en-US", "ja-JP", "ko-KR"])
    func syntheticSpeechReachesTranscriptAndExports(locale: String) async throws {
        let fixtures = [
            "en-US": ("Samantha", "Today we will review the project schedule. The next meeting is on Monday. Please prepare the report before the meeting."),
            "ja-JP": ("Kyoko", "今日はプロジェクトの予定を確認します。次の会議は月曜日です。会議の前に報告書を準備してください。"),
            "ko-KR": ("Yuna", "오늘은 프로젝트 일정을 확인하겠습니다. 다음 회의는 월요일입니다. 회의 전에 보고서를 준비해 주세요.")
        ]
        let fixture = try #require(fixtures[locale])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("fixture.aiff")
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-v", fixture.0, "-r", "150", "-o", source.path, fixture.1]
        try say.run()
        say.waitUntilExit()
        try #require(say.terminationStatus == 0)
        let store = SessionStore(rootDirectory: root.appendingPathComponent("sessions"))
        let session = try AudioImporter.importFile(source, store: store, language: locale)
        let directory = store.directory(for: session)
        let words = try await Transcriber.transcribe(sessionDirectory: directory, locale: locale)
        try #require(!words.isEmpty, "Speech model returned no words for \(locale)")
        #expect(words.allSatisfy { $0.startMs >= 0 && $0.durationMs >= 0 && Double($0.startMs) <= session.durationSeconds * 1000 })
        let utterances = TranscriptBuilder.build(from: words)
        try #require(!utterances.isEmpty)
        let transcript = directory.appendingPathComponent("transcript.txt")
        try TranscriptBuilder.writeTranscript(utterances, to: transcript)
        #expect(!TranscriptBuilder.parse(try String(contentsOf: transcript, encoding: .utf8)).isEmpty)
        let flac = try FLACConverter.convert(sessionDirectory: directory)
        let exported = directory.appendingPathComponent("meeting.mp3")
        try MP3Exporter.export(from: flac, range: 0...session.durationSeconds, gains: session.gains,
                               bitrate: 128, mono: true, to: exported)
        #expect(try AVAudioFile(forReading: exported).length > 0)
        let markdown = TranscriptBuilder.markdown(utterances, title: session.displayName, createdAt: session.createdAt,
                                                  durationSeconds: session.durationSeconds, language: locale)
        #expect(markdown.contains(locale))
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("call.wav").path))
        print("Speech pipeline passed: \(locale), \(words.count) words, \(session.durationSeconds) seconds")
    }
}
