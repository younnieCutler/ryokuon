import Foundation

/// Publish only a finished sibling file. An encoder failure must not truncate
/// an existing export; callers clean up their staging file on every exit.
enum AtomicFile {
    static func publish(_ staged: URL, to destination: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: staged)
        } else {
            try FileManager.default.moveItem(at: staged, to: destination)
        }
    }
}
