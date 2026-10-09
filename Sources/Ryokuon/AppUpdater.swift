import AppKit
import CryptoKit
import Foundation

enum UpdateError: LocalizedError {
    case invalidRelease
    case invalidDownload
    case invalidSignature
    case unsupportedInstallLocation
    case commandFailed(String)
    case busy

    var errorDescription: String? {
        switch self {
        case .invalidRelease: "The GitHub release has no valid Ryokuon.zip asset."
        case .invalidDownload: "The downloaded app did not match the GitHub release."
        case .invalidSignature: "The downloaded app's signature does not match this installation."
        case .unsupportedInstallLocation: "Install Ryokuon in /Applications or ~/Applications to update it here."
        case .commandFailed(let message): message
        case .busy: "Finish the current recording or conversion before updating."
        }
    }
}

struct AppVersion: Comparable, Sendable {
    let components: [Int]

    init?(_ text: String) {
        let trimmed = text.hasPrefix("v") ? String(text.dropFirst()) : text
        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              parts.count <= 4 else { return nil }
        var numbers = parts.compactMap { Int($0) }
        guard numbers.count == parts.count else { return nil }
        while numbers.count > 1 && numbers.last == 0 { numbers.removeLast() }
        components = numbers
    }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        for index in 0 ..< max(lhs.components.count, rhs.components.count) {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }
}

struct GitHubRelease: Decodable, Sendable {
    struct Asset: Decodable, Sendable {
        let name: String
        let size: Int
        let digest: String?
        let browserDownloadURL: URL

        enum CodingKeys: String, CodingKey {
            case name, size, digest
            case browserDownloadURL = "browser_download_url"
        }
    }

    let tagName: String
    let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case assets
    }

    var version: String { tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName }

    var installAsset: Asset? {
        assets.first {
            $0.name == "Ryokuon.zip" && $0.size > 0 && $0.size < 200_000_000
                && Self.validDigest($0.digest)
                && $0.browserDownloadURL.scheme == "https"
                && $0.browserDownloadURL.host == "github.com"
                && $0.browserDownloadURL.path.hasPrefix(
                    "/younnieCutler/ryokuon/releases/download/\(tagName)/")
        }
    }

    private static func validDigest(_ digest: String?) -> Bool {
        guard let digest, digest.hasPrefix("sha256:") else { return false }
        let hex = digest.dropFirst(7)
        return hex.count == 64 && hex.allSatisfy { "0123456789abcdefABCDEF".contains($0) }
    }
}

@MainActor
@Observable
final class AppUpdater {
    enum State: Equatable {
        case idle
        case checking
        case upToDate(String)
        case available(String)
        case preparing(String)
        case failed(String)
    }

    private(set) var state: State = .idle
    private var release: GitHubRelease?

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    var isBusy: Bool {
        if case .checking = state { return true }
        if case .preparing = state { return true }
        return false
    }

    func check() async {
        state = .checking
        do {
            var request = URLRequest(url: URL(string: "https://api.github.com/repos/younnieCutler/ryokuon/releases/latest")!)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 15
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
                throw UpdateError.invalidRelease
            }
            let found = try JSONDecoder().decode(GitHubRelease.self, from: data)
            guard let latest = AppVersion(found.tagName), let current = AppVersion(currentVersion),
                  found.installAsset != nil else { throw UpdateError.invalidRelease }
            release = found
            state = latest > current ? .available(found.version) : .upToDate(currentVersion)
        } catch {
            release = nil
            state = .failed(error.localizedDescription)
        }
    }

    func install(appState: AppState) async {
        guard !appState.hasActiveWork else {
            state = .failed(UpdateError.busy.localizedDescription)
            return
        }
        guard let release, let asset = release.installAsset,
              let currentTeam = try? Self.teamIdentifier(of: Bundle.main.bundleURL),
              let destination = Self.installedApplicationURL() else {
            state = .failed(UpdateError.unsupportedInstallLocation.localizedDescription)
            return
        }
        state = .preparing(release.version)
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("ryokuon-update-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false)
            let (downloaded, response) = try await URLSession.shared.download(from: asset.browserDownloadURL)
            guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
                throw UpdateError.invalidDownload
            }
            let archive = work.appendingPathComponent("Ryokuon.zip")
            try FileManager.default.moveItem(at: downloaded, to: archive)
            let prepared = try await Task.detached(priority: .utility) {
                try Self.prepare(archive: archive, in: work, release: release, team: currentTeam)
            }.value
            guard !appState.hasActiveWork else { throw UpdateError.busy }
            let bundledHelper = Bundle.main.resourceURL?.appendingPathComponent("update-helper.sh")
            guard let bundledHelper else { throw UpdateError.invalidSignature }
            let helper = work.appendingPathComponent("update-helper.sh")
            try FileManager.default.copyItem(at: bundledHelper, to: helper)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [helper.path, String(ProcessInfo.processInfo.processIdentifier),
                                 destination.path, prepared.path, currentTeam, release.version,
                                 work.path]
            try process.run()
            NSApp.terminate(nil)
        } catch {
            try? FileManager.default.removeItem(at: work)
            state = .failed(error.localizedDescription)
        }
    }

    static func installedApplicationURL(bundleURL: URL = Bundle.main.bundleURL,
                                         home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        let path = bundleURL.standardizedFileURL.path
        let accepted = ["/Applications/Ryokuon.app",
                        home.appendingPathComponent("Applications/Ryokuon.app").path]
        return accepted.contains(path) ? bundleURL : nil
    }

    nonisolated private static func prepare(archive: URL, in work: URL, release: GitHubRelease,
                                team: String) throws -> URL {
        guard let asset = release.installAsset,
              let expected = asset.digest?.dropFirst("sha256:".count), expected.count == 64 else {
            throw UpdateError.invalidRelease
        }
        let actual = SHA256.hash(data: try Data(contentsOf: archive))
            .map { String(format: "%02x", $0) }.joined()
        guard actual == expected.lowercased() else { throw UpdateError.invalidDownload }
        let unpacked = work.appendingPathComponent("unpacked", isDirectory: true)
        try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: false)
        try run("/usr/bin/ditto", ["-x", "-k", archive.path, unpacked.path])
        let app = unpacked.appendingPathComponent("Ryokuon.app", isDirectory: true)
        let values = try app.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard values.isDirectory == true, values.isSymbolicLink != true,
              let bundle = Bundle(url: app),
              bundle.bundleIdentifier == "dev.ryokuon.app",
              bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == release.version,
              try teamIdentifier(of: app) == team else { throw UpdateError.invalidSignature }
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        try run("/usr/sbin/spctl", ["--assess", "--type", "execute", app.path])
        return app
    }

    nonisolated private static func teamIdentifier(of app: URL) throws -> String {
        let output = try run("/usr/bin/codesign", ["-dv", "--verbose=4", app.path])
        guard let team = output.split(separator: "\n").first(where: { $0.hasPrefix("TeamIdentifier=") })?
            .split(separator: "=").last.map(String.init), !team.isEmpty else {
            throw UpdateError.invalidSignature
        }
        return team
    }

    @discardableResult
    nonisolated private static func run(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UpdateError.commandFailed(output) }
        return output
    }
}
