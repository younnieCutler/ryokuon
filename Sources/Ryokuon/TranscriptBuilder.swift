import Foundation

/// One merged utterance — the unit `transcript.txt` (the file AI reads) is
/// made of. `raw.json` (step 3's word-level output) is the input.
struct Utterance {
    let speaker: String // "M" or "R"
    let startMs: Int
    let text: String
    let confidence: Double // average over the words that merged into this utterance
}

/// Merges same-speaker words into utterances (Q12: 2s+ silence starts a new
/// utterance), marks low-confidence ones (Q13: avg < 0.5 gets a leading
/// `?`), and formats the compact line AI reads: `12400|M|text`.
///
/// Pure functions — no CoreAudio/Speech dependency, so this is the one part
/// of the pipeline that's actually unit-testable (see the honest note in
/// the plan about coverage).
enum TranscriptBuilder {
    static let gapThresholdMs = 2000
    static let lowConfidenceThreshold = 0.5

    /// Merges within each speaker's own chronological word list first, then
    /// interleaves both speakers' utterances by start time — a silence gap
    /// on one track isn't broken by the other speaker talking, so this
    /// can't just walk the combined, already-sorted `words` in one pass.
    static func build(from words: [TranscriptWord]) -> [Utterance] {
        let bySpeaker = Dictionary(grouping: words, by: \.speaker)
        let utterances = bySpeaker.values.flatMap {
            mergeConsecutive($0.sorted { $0.startMs < $1.startMs })
        }
        return utterances.sorted { $0.startMs < $1.startMs }
    }

    static func format(_ utterance: Utterance) -> String {
        let prefix = utterance.confidence < lowConfidenceThreshold ? "?" : ""
        return "\(utterance.startMs)|\(utterance.speaker)|\(prefix)\(utterance.text)"
    }

    static func writeTranscript(_ utterances: [Utterance], to url: URL) throws {
        let text = utterances.map(format).joined(separator: "\n")
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Reads `transcript.txt` back (`12400|M|text`). Confidence isn't in the
    /// file — a low-confidence line just keeps its leading `?` in `text`.
    static func parse(_ text: String) -> [Utterance] {
        text.split(separator: "\n").compactMap { rawLine in
            let parts = rawLine.split(separator: "|", maxSplits: 2)
            guard parts.count == 3, let ms = Int(parts[0]) else { return nil }
            return Utterance(speaker: String(parts[1]), startMs: ms, text: String(parts[2]), confidence: 1)
        }
    }

    /// The "분석용 MD" export: a header plus one timestamped line per
    /// utterance, limited to `rangeMs` when exporting a trimmed section.
    /// Timestamps stay relative to the original recording so they still
    /// line up with the session's transcript and player.
    static func markdown(_ utterances: [Utterance], title: String, createdAt: Date, durationSeconds: Double,
                         language: String, rangeMs: ClosedRange<Int>? = nil) -> String {
        let date = createdAt.formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month().day())
        var meta = "\(date) · \(formattedDuration(durationSeconds)) · \(language)"
        if let rangeMs {
            meta += " · \(formattedDuration(Double(rangeMs.lowerBound) / 1000))–\(formattedDuration(Double(rangeMs.upperBound) / 1000))"
        }
        let lines = utterances
            .filter { rangeMs?.contains($0.startMs) ?? true }
            .map { "- [\(formattedDuration(Double($0.startMs) / 1000))] **\($0.speaker)** \($0.text)" }
        return (["# \(title)", "", meta, ""] + lines).joined(separator: "\n") + "\n"
    }

    private static func mergeConsecutive(_ words: [TranscriptWord]) -> [Utterance] {
        guard let first = words.first else { return [] }
        var result: [Utterance] = []
        var current = [first]

        for word in words.dropFirst() {
            let last = current[current.count - 1]
            let gap = word.startMs - (last.startMs + last.durationMs)
            if gap >= gapThresholdMs {
                result.append(makeUtterance(current))
                current = [word]
            } else {
                current.append(word)
            }
        }
        result.append(makeUtterance(current))
        return result
    }

    private static func makeUtterance(_ words: [TranscriptWord]) -> Utterance {
        let text = words.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        let averageConfidence = words.map(\.confidence).reduce(0, +) / Double(words.count)
        return Utterance(speaker: words[0].speaker, startMs: words[0].startMs,
                         text: text, confidence: averageConfidence)
    }
}
