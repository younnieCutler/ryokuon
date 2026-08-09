import Foundation

/// One recording: a directory under the storage root holding session.json,
/// call.wav (call.flac after step 5's post-transcription conversion), and
/// raw.json + transcript.txt (step 3/4). The folder name is the stable ID
/// (Q10) — `displayName` is what the user sees and can rename without
/// touching any file paths.
struct Session: Codable {
    enum State: String, Codable {
        case recording
        case finished
        /// Header was 0-byte on launch (crash) and has been repaired from
        /// the file's actual size.
        case recovered
    }

    struct Gains: Codable {
        var me: Double = 1.0
        var remote: Double = 1.0
    }

    let id: String
    var displayName: String
    var language: String // BCP-47, e.g. "ja-JP" — Q7
    var targetBundleID: String?
    var targetDisplayName: String
    let createdAt: Date
    var state: State
    var durationSeconds: Double
    var gains: Gains
}

enum SessionError: Error {
    case notFound(URL)
}

/// Owns the storage root (Q9, user-configurable) and the on-disk session
/// directories underneath it.
final class SessionStore {
    static let defaultRoot = FileManager.default
        .urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("ryokuon", isDirectory: true)

    private static let rootDefaultsKey = "dev.ryokuon.storageRootPath"

    private(set) var rootDirectory: URL

    init(rootDirectory: URL? = nil) {
        self.rootDirectory = rootDirectory ?? Self.loadConfiguredRoot()
        try? FileManager.default.createDirectory(at: self.rootDirectory, withIntermediateDirectories: true)
    }

    static func loadConfiguredRoot() -> URL {
        if let path = UserDefaults.standard.string(forKey: rootDefaultsKey), !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        return defaultRoot
    }

    /// Changes where new sessions are created. Existing sessions stay where
    /// they are — this does not move anything (Q9: "저장 폴더 바꾸기").
    func setRootDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        rootDirectory = url
        UserDefaults.standard.set(url.path, forKey: Self.rootDefaultsKey)
    }

    /// Folder name is the stable ID (Q10): a timestamp, collision-suffixed
    /// if two recordings start in the same minute.
    func createSession(language: String, target: AudioProcess) throws -> (session: Session, directory: URL) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmm"
        let base = formatter.string(from: Date())

        var id = base
        var directory = rootDirectory.appendingPathComponent(id, isDirectory: true)
        var suffix = 1
        while FileManager.default.fileExists(atPath: directory.path) {
            id = "\(base)_\(suffix)"
            directory = rootDirectory.appendingPathComponent(id, isDirectory: true)
            suffix += 1
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let session = Session(id: id, displayName: id, language: language,
                              targetBundleID: target.bundleID, targetDisplayName: target.displayName,
                              createdAt: Date(), state: .recording, durationSeconds: 0, gains: .init())
        try save(session, in: directory)
        return (session, directory)
    }

    /// `JSONEncoder`'s built-in `.iso8601` strategy truncates to whole
    /// seconds. Two sessions created in the same second (fully possible —
    /// crash recovery on launch, or a fast test) would then tie on
    /// `createdAt`, and `listSessions()`'s sort would silently fall back to
    /// filesystem enumeration order instead of creation order. Millisecond
    /// precision avoids that.
    /// `ISO8601DateFormatter` isn't `Sendable`; this box lets it cross into
    /// the `@Sendable` closures `JSONEncoder`/`JSONDecoder` require without
    /// disabling concurrency checking — safe because each box is created
    /// fresh per `save`/`load` call and never shared across threads.
    private final class DateFormatterBox: @unchecked Sendable {
        let formatter: ISO8601DateFormatter
        init() {
            formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        }
    }

    func save(_ session: Session, in directory: URL) throws {
        let box = DateFormatterBox()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(box.formatter.string(from: date))
        }
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(session).write(to: directory.appendingPathComponent("session.json"))
    }

    func load(from directory: URL) throws -> Session {
        let url = directory.appendingPathComponent("session.json")
        guard let data = try? Data(contentsOf: url) else { throw SessionError.notFound(url) }
        let box = DateFormatterBox()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            guard let date = box.formatter.date(from: string) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "bad ISO8601 date: \(string)")
            }
            return date
        }
        return try decoder.decode(Session.self, from: data)
    }

    /// Folder name is the session ID (Q10) — this is the one place that
    /// fact turns into a path, so callers (Player, Transcriber CLI hookup)
    /// don't each reconstruct it themselves.
    func directory(for session: Session) -> URL {
        rootDirectory.appendingPathComponent(session.id, isDirectory: true)
    }

    func listSessions() -> [Session] {
        let directories = (try? FileManager.default.contentsOfDirectory(
            at: rootDirectory, includingPropertiesForKeys: nil)) ?? []
        return directories
            .compactMap { try? load(from: $0) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// Q11: on launch, find every session still marked "recording" — that
    /// only happens if the process died before `finish()` ran — and repair
    /// its WAV headers from the files' actual sizes. Returns what it fixed
    /// so the caller can surface it to the user.
    @discardableResult
    func recoverCrashedSessions() -> [Session] {
        var recovered: [Session] = []
        let directories = (try? FileManager.default.contentsOfDirectory(
            at: rootDirectory, includingPropertiesForKeys: nil)) ?? []

        for directory in directories {
            guard var session = try? load(from: directory), session.state == .recording else { continue }

            let callURL = directory.appendingPathComponent(AudioCapture.fileName)
            try? WAVWriter.repairHeader(at: callURL, channels: 2)

            session.state = .recovered
            session.durationSeconds = wavDuration(at: callURL, channels: 2)
            try? save(session, in: directory)
            recovered.append(session)
        }
        return recovered
    }

    private func wavDuration(at url: URL, channels: UInt16) -> Double {
        guard let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64,
              size > 44
        else { return 0 }
        let dataBytes = size - 44
        return Double(dataBytes) / 2 / Double(channels) / Double(WAVWriter.sampleRate)
    }
}
