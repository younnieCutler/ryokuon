import Foundation
import Testing

@testable import Ryokuon

struct RingBufferTests {
    // Only one producer and one consumer use this ring, per its contract.
    private final class SharedRing: @unchecked Sendable {
        let ring = RingBuffer(capacity: 512)
    }

    @Test func overflowRetainsNewestSamplesAndCountsUnreadLoss() {
        let ring = RingBuffer(capacity: 4)
        [Float(1), 2].withUnsafeBufferPointer { ring.write($0.baseAddress!, count: $0.count) }
        [Float(3), 4, 5, 6, 7].withUnsafeBufferPointer { ring.write($0.baseAddress!, count: $0.count) }
        var output: [Float] = []
        ring.drain(into: &output)
        #expect(output == [4, 5, 6, 7])
        #expect(ring.droppedSamples == 3)
    }

    @Test func repeatedDrainsDoNotReplayOldSamples() {
        let ring = RingBuffer(capacity: 4)
        var output: [Float] = []
        for value in 0 ..< 10 {
            [Float(value)].withUnsafeBufferPointer { ring.write($0.baseAddress!, count: 1) }
            ring.drain(into: &output)
            ring.drain(into: &output)
        }
        #expect(output == (0 ..< 10).map(Float.init))
    }

    // Run with --sanitize=thread on macOS as well as the ordinary test suite.
    @Test func concurrentDrainPreservesOrderEvenWhenProducerWraps() async {
        let shared = SharedRing()
        let producer = Task.detached {
            for batch in 0 ..< 400 {
                let samples = (0 ..< 256).map { Float(batch * 256 + $0) }
                samples.withUnsafeBufferPointer { shared.ring.write($0.baseAddress!, count: $0.count) }
            }
        }
        let consumer = Task.detached {
            var output: [Float] = []
            for _ in 0 ..< 1000 { shared.ring.drain(into: &output) }
            return output
        }
        await producer.value
        var output = await consumer.value
        shared.ring.drain(into: &output)
        #expect(!output.isEmpty)
        #expect(zip(output, output.dropFirst()).allSatisfy { $0 < $1 })
    }
}
