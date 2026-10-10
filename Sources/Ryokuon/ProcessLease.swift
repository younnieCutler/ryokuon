import Darwin
import Foundation

/// The OS releases this lock even after SIGKILL. A second app instance must
/// never repair a WAV that the first instance is still recording into.
final class ProcessLease {
    private let descriptor: Int32
    init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        descriptor = Darwin.open(directory.appendingPathComponent("process.lock").path,
                                 O_RDWR | O_CREAT | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(descriptor)
            throw POSIXError(.EWOULDBLOCK)
        }
    }
    deinit { flock(descriptor, LOCK_UN); Darwin.close(descriptor) }
}
