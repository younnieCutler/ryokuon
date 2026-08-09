import Foundation

/// Fixed-capacity single-producer/single-consumer ring buffer for Float
/// samples. The IOProc callback (producer) must never allocate or block for
/// long, so this uses a short `os_unfair_lock` critical section around a
/// pre-allocated buffer instead of growing an array — an hour-long recording
/// must not trigger a reallocation on the audio thread.
final class RingBuffer {
    private let storage: UnsafeMutablePointer<Float>
    private let capacity: Int
    private var writeIndex = 0
    private var count = 0
    private var lock = os_unfair_lock()
    private(set) var droppedSamples = 0

    init(capacity: Int) {
        self.capacity = capacity
        storage = .allocate(capacity: capacity)
    }

    deinit {
        storage.deallocate()
    }

    /// Called from the real-time IOProc thread. Drops the oldest unread
    /// samples on overflow rather than blocking — losing audio is bad, but
    /// stalling the audio callback is worse (it can glitch every other
    /// stream on the device).
    func write(_ samples: UnsafePointer<Float>, count writeCount: Int) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }

        if writeCount >= capacity {
            // Pathological case: single write bigger than the whole buffer.
            let tail = writeCount - capacity
            for i in 0 ..< capacity { storage[i] = samples[tail + i] }
            writeIndex = 0
            count = capacity
            droppedSamples += writeCount - capacity
            return
        }

        for i in 0 ..< writeCount {
            storage[writeIndex] = samples[i]
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
        count = 0
        os_unfair_lock_unlock(&lock)

        guard available > 0 else { return }
        output.reserveCapacity(output.count + available)
        for i in 0 ..< available {
            output.append(storage[(readStart + i) % capacity])
        }
    }
}
