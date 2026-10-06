import Foundation

/// One recording: a directory under the storage root holding session.json,
/// call.wav (call.flac after step 5's post-transcription conversion), and
/// raw.json + transcript.txt (step 3/4). The folder name is the stable ID
/// (Q10) — `displayName` is what the user sees and can rename without
/// touching any file paths.
struct Session: Codable, Sendable {
    enum State: String, Codable, Sendable {
        case recording
        case finished
        /// Header was 0-byte on launch (crash) and has been repaired from
        /// the file's actual size.
        case recovered
    }

    struct Gains: Codable, Sendable {
        var me: Double = 1.0
        var remote: Double = 1.0
    }

    let id: String
    /// In-memory location below the selected storage root. It is deliberately
    /// not stored in session.json: moving a folder in Finder must not rewrite
    /// the recording or make its metadata point at an old location.
    var relativePath: String
    var displayName: String
    var language: String // BCP-47, e.g. "ja-JP" — Q7
    var targetBundleID: String?
    var targetDisplayName: String
    let createdAt: Date
    var state: State
    var durationSeconds: Double
    var gains: Gains
    /// 1 (mono, no headset — echo leak means ME/REMOTE separation isn't
    /// worth keeping) or 2 (stereo, L=me/R=remote). Custom-decoded below so
    /// pre-existing session.json files without this key still load — they
    /// were all recorded stereo, so 2 is the correct default for them.
    var channels: Int = 2

    init(id: String, displayName: String, language: String, targetBundleID: String?,
         targetDisplayName: String, createdAt: Date, state: State, durationSeconds: Double,
         gains: Gains, channels: Int = 2) {
        self.id = id
        self.relativePath = id
        self.displayName = displayName
        self.language = language
        self.targetBundleID = targetBundleID
        self.targetDisplayName = targetDisplayName
        self.createdAt = createdAt
        self.state = state
        self.durationSeconds = durationSeconds
        self.gains = gains
        self.channels = channels
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        relativePath = id
        displayName = try container.decode(String.self, forKey: .displayName)
        language = try container.decode(String.self, forKey: .language)
        targetBundleID = try container.decodeIfPresent(String.self, forKey: .targetBundleID)
        targetDisplayName = try container.decode(String.self, forKey: .targetDisplayName)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        state = try container.decode(State.self, forKey: .state)
        durationSeconds = try container.decode(Double.self, forKey: .durationSeconds)
        gains = try container.decode(Gains.self, forKey: .gains)
        channels = try container.decodeIfPresent(Int.self, forKey: .channels) ?? 2
    }

    private enum CodingKeys: String, CodingKey {
        case id, displayName, language, targetBundleID, targetDisplayName
        case createdAt, state, durationSeconds, gains, channels
    }
}

enum SessionError: Error {
    case notFound(URL)
    case invalidMetadata(URL)
}

/// Owns the storage root (Q9, user-configurable) and the on-disk session
/// directories underneath it.
final class SessionStore {
    static let defaultRoot = FileManager.default
        .urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("ryokuon", isDirectory: true)

    private static let rootDefaultsKey = "dev.ryokuon.storageRootPath"

    private(set) var rootDirectory: URL

    init(rootDirectory: URL? = nil, createDirectory: Bool = true) {
        self.rootDirectory = rootDirectory ?? Self.loadConfiguredRoot()
        if createDirectory {
            try? FileManager.default.createDirectory(at: self.rootDirectory, withIntermediateDirectories: true)
        }
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

    /// Folder name = timestamp, `_1`, `_2`… on collision (Q10) — kept short
    /// because `bin/ryokuon show <session>` takes it as typed input.
    func createSession(language: String, targetBundleID: String?, targetDisplayName: String,
                       channels: Int = 2) throws -> (session: Session, directory: URL) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmm"
        let base = formatter.string(from: Date())

        // Imports run off the main actor and may overlap recording creation.
        // `withIntermediateDirectories: false` makes mkdir itself the claim:
        // it fails atomically if the name is taken, so two creators can never
        // share a folder (no check-then-create window) — just try the next suffix.
        var id = base
        var directory = rootDirectory.appendingPathComponent(id, isDirectory: true)
        for suffix in 1... {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                break
            } catch CocoaError.fileWriteFileExists {
                id = "\(base)_\(suffix)"
                directory = rootDirectory.appendingPathComponent(id, isDirectory: true)
            }
        }

        let session = Session(id: id, displayName: base, language: language,
                              targetBundleID: targetBundleID, targetDisplayName: targetDisplayName,
                              createdAt: Date(), state: .recording, durationSeconds: 0, gains: .init(),
                              channels: channels)
        do {
            try save(session, in: directory)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
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
        try encoder.encode(session).write(to: directory.appendingPathComponent("session.json"), options: .atomic)
    }

    func load(from directory: URL) throws -> Session {
        let url = directory.appendingPathComponent("session.json")
        guard let data = try? Data(contentsOf: url) else { throw SessionError.notFound(url) }
        let box = DateFormatterBox()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            let legacy = ISO8601DateFormatter()
            guard let date = box.formatter.date(from: string) ?? legacy.date(from: string) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "bad ISO8601 date: \(string)")
            }
            return date
        }
        var session = try decoder.decode(Session.self, from: data)
        // Folder identity is authoritative. Never let edited metadata redirect
        // playback, export, or recursive deletion outside this folder.
        let root = rootDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let resolvedDirectory = directory.standardizedFileURL.resolvingSymlinksInPath()
        guard resolvedDirectory.path.hasPrefix(root.path + "/"),
              session.id == directory.lastPathComponent,
              session.id != ".", session.id != "..", !session.id.contains("/"),
              (1 ... 2).contains(session.channels),
              session.durationSeconds.isFinite, session.durationSeconds >= 0,
              session.gains.me.isFinite, session.gains.remote.isFinite
        else { throw SessionError.invalidMetadata(url) }
        session.relativePath = String(directory.standardizedFileURL.path.dropFirst(rootDirectory.standardizedFileURL.path.count + 1))
        return session
    }

    /// Folder name is the session ID (Q10) — this is the one place that
    /// fact turns into a path, so callers (Player, Transcriber CLI hookup)
    /// don't each reconstruct it themselves.
    func directory(for session: Session) -> URL {
        rootDirectory.appendingPathComponent(session.relativePath, isDirectory: true)
    }

    func listSessions() -> [Session] {
        AudioLibraryScanner.scan(root: rootDirectory).sessions
    }

    /// Q11: on launch, find every session still marked "recording" — that
    /// only happens if the process died before `finish()` ran — and repair
    /// its WAV headers from the files' actual sizes. Returns what it fixed
    /// so the caller can surface it to the user.
    @discardableResult
    func recoverCrashedSessions() -> [Session] {
        var recovered: [Session] = []
        for found in listSessions() where found.state == .recording {
            var session = found
            let directory = directory(for: session)

            let callURL = directory.appendingPathComponent(AudioCapture.fileName)
            do {
                try WAVWriter.repairHeader(at: callURL, channels: UInt16(session.channels))
                session.state = .recovered
                session.durationSeconds = wavDuration(at: callURL, channels: UInt16(session.channels))
                try save(session, in: directory)
                recovered.append(session)
            } catch {
                // Keep recording state so a later launch can retry recovery.
                continue
            }
        }
        return recovered
    }

    /// Permanently removes the session's directory and everything in it.
    func delete(_ session: Session) throws {
        let directory = directory(for: session).standardizedFileURL
        let parts = session.relativePath.split(separator: "/", omittingEmptySubsequences: false)
        let root = rootDirectory.standardizedFileURL.resolvingSymlinksInPath()
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              parts.last == Substring(session.id),
              directory.resolvingSymlinksInPath().path.hasPrefix(root.path + "/")
        else { throw SessionError.invalidMetadata(directory) }
        try FileManager.default.removeItem(at: directory)
    }

    private func wavDuration(at url: URL, channels: UInt16) -> Double {
        guard let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64,
              size > 44
        else { return 0 }
        let dataBytes = size - 44
        return Double(dataBytes) / 2 / Double(channels) / Double(WAVWriter.sampleRate)
    }
}
