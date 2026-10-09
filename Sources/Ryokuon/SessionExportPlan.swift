import Foundation

/// One naming and validation path for preview, overwrite confirmation and export.
struct SessionExportPlan {
    let mp3URL: URL?
    let markdownURL: URL?

    var urls: [URL] { [mp3URL, markdownURL].compactMap { $0 } }
    var existingURLs: [URL] { urls.filter { FileManager.default.fileExists(atPath: $0.path) } }

    init(session: Session, range: ClosedRange<Double>, directory: URL, mp3: Bool, markdown: Bool) throws {
        guard mp3 || markdown, range.lowerBound.isFinite, range.upperBound.isFinite,
              range.lowerBound >= 0, range.upperBound > range.lowerBound,
              range.upperBound <= session.durationSeconds,
              range.upperBound < Double(Int.max) / 1000 else { throw MP3ExporterError.invalidRange }
        let isFull = range.lowerBound == 0 && range.upperBound >= session.durationSeconds
        let suffix = isFull ? "" : "_\(Self.fileTime(range.lowerBound))-\(Self.fileTime(range.upperBound))"
        var title = session.displayName.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty || title == "." || title == ".." { title = "Recording" }
        let base = directory.appendingPathComponent(title + suffix)
        mp3URL = mp3 ? base.appendingPathExtension("mp3") : nil
        markdownURL = markdown ? base.appendingPathExtension("md") : nil
    }

    private static func fileTime(_ seconds: Double) -> String {
        let milliseconds = Int(seconds * 1000)
        let total = milliseconds / 1000
        return String(format: "%02d%02d_%03d", total / 60, total % 60, milliseconds % 1000)
    }
}
