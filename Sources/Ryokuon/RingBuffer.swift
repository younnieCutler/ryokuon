import Foundation

/// Fixed-capacity single-producer/single-consumer ring buffer for Float
/// samples. The IOProc callback (producer) must never allocate or block for
/// long, so this uses a short `os_unfair_lock` critical section around a
/// pre-allocated buffer instead of growing an array — an hour-long recording
/// must not trigger a reallocation on the audio thread.
final class RingBuffer {
    private var storage: UnsafeMutablePointer<Float>
    private var drainStorage: UnsafeMutablePointer<Float>
    private let capacity: Int
    private var writeIndex = 0
    private var count = 0
    private var lock = os_unfair_lock()
    private(set) var droppedSamples = 0

    init(capacity: Int) {
        self.capacity = capacity
        storage = .allocate(capacity: capacity)
        drainStorage = .allocate(capacity: capacity)
    }

    deinit {
        storage.deallocate()
        drainStorage.deallocate()
    }

    /// Called from the real-time IOProc thread. Drops the oldest unread
    /// samples on overflow rather than blocking — losing audio is bad, but
    /// stalling the audio callback is worse (it can glitch every other
    /// stream on the device).
    func write(_ samples: UnsafePointer<Float>, count writeCount: Int) {
        write(count: writeCount) { samples[$0] }
    }

    /// Synchronous, nonescaping producer for channel mixdown without allocating.
    func write(count writeCount: Int, sampleAt: (Int) -> Float) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }

        if writeCount >= capacity {
            // Pathological case: single write bigger than the whole buffer.
            let tail = writeCount - capacity
            for i in 0 ..< capacity { storage[i] = sampleAt(tail + i) }
            writeIndex = 0
            droppedSamples += count + writeCount - capacity
            count = capacity
            return
        }

        for i in 0 ..< writeCount {
            storage[writeIndex] = sampleAt(i)
            writeIndex = (writeIndex + 1) % capacity
        }

        let newCount = count + writeCount
        if newCount > capacity {
            droppedSamples += newCount - capacity
            count = capacity
        } else {
            count = newCount
        }
    }

    /// Called from the writer queue (consumer). Drains everything currently
    /// available and appends it to `output`.
    func drain(into output: inout [Float]) {
        os_unfair_lock_lock(&lock)
        let available = count
        let readStart = (writeIndex - count + capacity) % capacity
        // Transfer ownership of the snapshot in constant time. The producer
        // can immediately reuse its new buffer without overwriting our copy.
        swap(&storage, &drainStorage)
        count = 0
        writeIndex = 0
        os_unfair_lock_unlock(&lock)

        guard available > 0 else { return }
        output.reserveCapacity(output.count + available)
        for i in 0 ..< available {
            output.append(drainStorage[(readStart + i) % capacity])
        }
    }
}
