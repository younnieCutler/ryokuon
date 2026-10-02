import Foundation
import Testing

@testable import Ryokuon

struct WaveformTests {
    @Test func quietHalfThenLoudHalf() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        let writer = try WAVWriter(url: url)
        try writer.append([Int16](repeating: 0, count: 16000) + [Int16](repeating: 8000, count: 16000))
        try writer.finish()

        let peaks = try Waveform.peaks(of: url, buckets: 10)
        #expect(peaks.count == 10)
        #expect(peaks[0 ..< 5].allSatisfy { $0 == 0 })
        #expect(peaks[5 ..< 10].allSatisfy { abs($0 - 1) < 0.001 }) // normalized to loudest
    }
}
