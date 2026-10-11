import Foundation
import Testing

@testable import Ryokuon

struct TranscriptBuilderTests {
    private func word(_ speaker: String, start: Int, duration: Int = 300,
                       text: String, confidence: Double = 1.0) -> TranscriptWord {
        TranscriptWord(speaker: speaker, text: text, startMs: start, durationMs: duration, confidence: confidence)
    }

    @Test func mergesWordsUnderTwoSecondGap() throws {
        // 1.9s gap between word ends and next word start -> same utterance (Q12).
        let words = [
            word("M", start: 0, duration: 300, text: "안녕"),
            word("M", start: 2200, duration: 300, text: "하세요"), // gap = 2200-300 = 1900ms
        ]
        let utterances = TranscriptBuilder.build(from: words)
        #expect(utterances.count == 1)
        #expect(utterances[0].text == "안녕하세요")
        #expect(utterances[0].startMs == 0)
    }

    @Test func splitsOnTwoSecondOrLongerGap() throws {
        let words = [
            word("M", start: 0, duration: 300, text: "안녕"),
            word("M", start: 2300, duration: 300, text: "하세요"), // gap = 2000ms exactly -> new utterance
        ]
        let utterances = TranscriptBuilder.build(from: words)
        #expect(utterances.count == 2)
        #expect(utterances[0].text == "안녕")
        #expect(utterances[1].text == "하세요")
        #expect(utterances[1].startMs == 2300)
    }

    @Test func speakerCrossingDoesNotBreakSameSpeakerMerge() throws {
        // R talks in the middle of M's utterance (interruption/overlap) —
        // M's own words are still <2s apart, so they must stay merged
        // regardless of what R said in between.
        let words = [
            word("M", start: 0, duration: 300, text: "저는"),
            word("R", start: 400, duration: 300, text: "네"),
            word("M", start: 800, duration: 300, text: "생각합니다"),
        ]
        let utterances = TranscriptBuilder.build(from: words)
        #expect(utterances.count == 2)
        let m = utterances.first { $0.speaker == "M" }!
        #expect(m.text == "저는생각합니다")
        let r = utterances.first { $0.speaker == "R" }!
        #expect(r.text == "네")
    }

    @Test func marksLowAverageConfidenceUtterance() throws {
        let words = [
            word("M", start: 0, duration: 300, text: "잘안들림", confidence: 0.3),
        ]
        let utterances = TranscriptBuilder.build(from: words)
        #expect(TranscriptBuilder.format(utterances[0]) == "0|M|?잘안들림")
    }

    @Test func doesNotMarkHighAverageConfidenceUtterance() throws {
        let words = [
            word("M", start: 0, duration: 300, text: "잘들림", confidence: 0.9),
        ]
        let utterances = TranscriptBuilder.build(from: words)
        #expect(TranscriptBuilder.format(utterances[0]) == "0|M|잘들림")
    }

    @Test func averagesConfidenceAcrossMergedWords() throws {
        // (0.9 + 0.3) / 2 = 0.6 -> above 0.5 threshold, no marker.
        let words = [
            word("M", start: 0, duration: 300, text: "안녕", confidence: 0.9),
            word("M", start: 500, duration: 300, text: "하세요", confidence: 0.3),
        ]
        let utterances = TranscriptBuilder.build(from: words)
        #expect(utterances.count == 1)
        #expect(abs(utterances[0].confidence - 0.6) < 0.0001)
        #expect(!TranscriptBuilder.format(utterances[0]).contains("?"))
    }

    @Test func emptyInputProducesNoUtterances() throws {
        #expect(TranscriptBuilder.build(from: []).isEmpty)
    }

    @Test func emptyTrackForOneSpeakerIsFine() throws {
        // Only R spoke -> M produces zero utterances, not a crash or a
        // spurious empty entry.
        let words = [word("R", start: 0, duration: 300, text: "혼자말함")]
        let utterances = TranscriptBuilder.build(from: words)
        #expect(utterances.count == 1)
        #expect(utterances[0].speaker == "R")
    }

    @Test func sortsFinalUtterancesAcrossSpeakersByStartTime() throws {
        let words = [
            word("R", start: 5000, duration: 300, text: "나중에"),
            word("M", start: 0, duration: 300, text: "먼저"),
        ]
        let utterances = TranscriptBuilder.build(from: words)
        #expect(utterances.map(\.text) == ["먼저", "나중에"])
    }

    @Test func markdownRoundTripsTranscriptAndFiltersRange() throws {
        let parsed = TranscriptBuilder.parse("0|U|はじめ\n65000|U|?まんなか\nbroken line\n130000|U|おわり")
        #expect(parsed.count == 3)
        #expect(parsed[1].text == "?まんなか")

        let md = TranscriptBuilder.markdown(parsed, title: "memo", createdAt: Date(), durationSeconds: 140,
                                            language: "ja-JP", rangeMs: 60000 ... 120000)
        #expect(md.hasPrefix("# memo\n"))
        #expect(md.contains("1:00–2:00"))
        #expect(md.contains("- [1:05] **U** ?まんなか"))
        #expect(!md.contains("はじめ"))
        #expect(!md.contains("おわり"))
    }
}

struct TranscriptContractTests {
    @Test func formatKeepsEachUtteranceOnOnePhysicalLine() {
        let text = TranscriptBuilder.format(.init(speaker: "M", startMs: 1000, text: "a\nb\rc|d", confidence: 1))
        #expect(text == "1000|M|a b c|d")
        #expect(TranscriptBuilder.parse(text).first?.text == "a b c|d")
        #expect(TranscriptBuilder.parse("-1|M|bad timestamp").isEmpty)
    }
}
