import CoreServices
import Foundation

/// FSEvents observes descendants as well as the root itself. It only signals
/// that something changed; the scanner builds a fresh, consistent snapshot.
final class AudioLibraryWatcher {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "dev.ryokuon.audio-library-events")
    private let onChange: @Sendable () -> Void

    init(onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
    }

    func start(root: URL) {
        stop()
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents
                                             | kFSEventStreamCreateFlagWatchRoot
                                             | kFSEventStreamCreateFlagNoDefer)
        guard let created = FSEventStreamCreate(
            nil, { _, info, _, _, _, _ in
                guard let info else { return }
                Unmanaged<AudioLibraryWatcher>.fromOpaque(info).takeUnretainedValue().onChange()
            }, &context, [root.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.2, flags
        ) else { return }
        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            return
        }
        stream = created
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit { stop() }
}
