import Testing

@testable import Ryokuon

// Real coverage (TranscriptBuilder, WAV header repair) lands in step 4.
// This keeps the test target non-empty so `swift build`/`swift test` don't
// warn about a target with no sources.
@Test func packageBuilds() {
    #expect(WAVWriter.sampleRate == 16000)
}
