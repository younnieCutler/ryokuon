import Foundation

struct AudioFileStamp: Equatable, Sendable {
    let size: Int64
    let modifiedAt: Date?
}

struct AudioLibraryNode: Identifiable, Sendable {
    enum Kind: Sendable { case folder, audio }

    let relativePath: String
    let name: String
    let kind: Kind
    let children: [AudioLibraryNode]
    let stamp: AudioFileStamp?

    var id: String { relativePath }

    var isFolder: Bool { kind == .folder }
    var outlineChildren: [AudioLibraryNode]? { isFolder ? children : nil }

    func replacingChildren(_ replacement: [AudioLibraryNode]) -> AudioLibraryNode {
        AudioLibraryNode(relativePath: relativePath, name: name, kind: kind,
                         children: replacement, stamp: stamp)
    }
}

struct AudioLibrarySnapshot: Sendable {
    let nodes: [AudioLibraryNode]
    let sessions: [Session]
    let error: String?

    func audioNode(at relativePath: String) -> AudioLibraryNode? {
        func find(in nodes: [AudioLibraryNode]) -> AudioLibraryNode? {
            for node in nodes {
                if node.relativePath == relativePath && !node.isFolder { return node }
                if let found = find(in: node.children) { return found }
            }
            return nil
        }
        return find(in: nodes)
    }

    func audioStamp(at relativePath: String) -> AudioFileStamp? {
        audioNode(at: relativePath)?.stamp
    }

    func containsAudio(at relativePath: String) -> Bool {
        audioNode(at: relativePath) != nil
    }
}

/// A view of the actual files, never a second copy of the recordings.
/// Symlinked directories are skipped so an alias cannot make a cycle or
/// expose files outside the chosen root.
enum AudioLibraryScanner {
    static let audioExtensions: Set<String> = ["m4a", "mp3", "wav", "flac"]

    static func scan(root: URL) -> AudioLibrarySnapshot {
        let store = SessionStore(rootDirectory: root, createDirectory: false)
        let manager = FileManager.default
        var sessions: [Session] = []
        var firstError: String?

        func descend(_ directory: URL, relativePath: String) -> [AudioLibraryNode] {
            let urls: [URL]
            do {
                urls = try manager.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey,
                                                 .fileSizeKey, .contentModificationDateKey],
                    options: [.skipsHiddenFiles]
                )
            } catch {
                if firstError == nil { firstError = "\(directory.path): \(error.localizedDescription)" }
                return []
            }

            return urls.compactMap { url in
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey,
                                                                .fileSizeKey, .contentModificationDateKey])
                guard values?.isSymbolicLink != true else { return nil }
                let path = relativePath.isEmpty ? url.lastPathComponent : relativePath + "/" + url.lastPathComponent
                if values?.isDirectory == true {
                    if let session = try? store.load(from: url) { sessions.append(session) }
                    return AudioLibraryNode(relativePath: path, name: url.lastPathComponent,
                                            kind: .folder, children: descend(url, relativePath: path), stamp: nil)
                }
                guard audioExtensions.contains(url.pathExtension.lowercased()) else { return nil }
                return AudioLibraryNode(relativePath: path, name: url.lastPathComponent,
                                        kind: .audio, children: [],
                                        stamp: AudioFileStamp(size: Int64(values?.fileSize ?? 0),
                                                              modifiedAt: values?.contentModificationDate))
            }
            .sorted {
                if $0.isFolder != $1.isFolder { return $0.isFolder }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        }

        let nodes = descend(root, relativePath: "")
        sessions.sort { $0.createdAt > $1.createdAt }
        return AudioLibrarySnapshot(nodes: nodes, sessions: sessions, error: firstError)
    }
}
