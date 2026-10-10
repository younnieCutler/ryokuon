import Foundation

enum ExportBatchError: Error {
    case invalidDestination
    case destinationExists
    case missingStagedFile
    case recoveryRequired(URL)
}

/// Prepare all outputs before touching existing exports. Failed publication
/// restores the previous files. If restoration itself fails, retain backups
/// and report their location instead of deleting the last recoverable copy.
struct ExportBatch {
    let destinations: [URL]
    let stagingDirectory: URL
    private let allowOverwrite: Bool
    private var preserveRecoveryFiles = false

    init(destinations: [URL], allowOverwrite: Bool) throws {
        guard let parent = destinations.first?.deletingLastPathComponent(),
              Set(destinations).count == destinations.count,
              destinations.allSatisfy({ $0.deletingLastPathComponent() == parent })
        else { throw ExportBatchError.invalidDestination }
        self.destinations = destinations
        self.allowOverwrite = allowOverwrite
        stagingDirectory = parent.appendingPathComponent(".ryokuon-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: false)
    }

    func stagedURL(for destination: URL) throws -> URL {
        guard let index = destinations.firstIndex(of: destination) else { throw ExportBatchError.invalidDestination }
        return stagingDirectory.appendingPathComponent("\(index).\(destination.pathExtension)")
    }

    func cleanup() {
        if !preserveRecoveryFiles { try? FileManager.default.removeItem(at: stagingDirectory) }
    }

    mutating func commit(move: (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) }) throws {
        let manager = FileManager.default
        // Validate every output before the first rename, including collisions
        // that appeared while a long MP3 encode was running.
        for destination in destinations {
            guard manager.fileExists(atPath: try stagedURL(for: destination).path) else { throw ExportBatchError.missingStagedFile }
            var isDirectory: ObjCBool = false
            if manager.fileExists(atPath: destination.path, isDirectory: &isDirectory) {
                guard !isDirectory.boolValue else { throw ExportBatchError.invalidDestination }
                guard allowOverwrite else { throw ExportBatchError.destinationExists }
            }
        }
        let recoveryNames = Dictionary(uniqueKeysWithValues: destinations.enumerated().map {
            ("\($0.offset).previous", $0.element.lastPathComponent)
        })
        try JSONEncoder().encode(recoveryNames).write(to: stagingDirectory.appendingPathComponent("recovery.json"), options: .atomic)
        var backups: [(original: URL, backup: URL)] = []
        var published: [URL] = []
        do {
            for (index, destination) in destinations.enumerated() {
                if manager.fileExists(atPath: destination.path) {
                    let backup = stagingDirectory.appendingPathComponent("\(index).previous")
                    try move(destination, backup)
                    backups.append((destination, backup))
                }
                try move(stagedURL(for: destination), destination)
                published.append(destination)
            }
        } catch {
            var recoveryFailed = false
            for destination in published.reversed() {
                do { try manager.removeItem(at: destination) } catch { recoveryFailed = true }
            }
            for pair in backups.reversed() {
                do { try move(pair.backup, pair.original) } catch { recoveryFailed = true }
            }
            if recoveryFailed {
                preserveRecoveryFiles = true
                throw ExportBatchError.recoveryRequired(stagingDirectory)
            }
            throw error
        }
    }
}
