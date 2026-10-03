import AVFoundation
import Testing

@testable import Ryokuon

struct AudioTrackMixerTests {
    @Test(arguments: [false, true])
    func stereoMicAndMonoTapRemainFrameAligned(interleaved: Bool) throws {
        // >2 channels needs an explicit layout — the channels: initializer returns nil for 3.
        let layout = try #require(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 3))
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000,
                                   interleaved: interleaved, channelLayout: layout)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
        buffer.frameLength = 4
        let buffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let values: [Float] = [0.2, 0.6, 0.9]
        var channelBase = 0
        for audio in buffers {
            let count = Int(audio.mNumberChannels)
            let samples = try #require(audio.mData).assumingMemoryBound(to: Float.self)
            for frame in 0 ..< 4 {
                for channel in 0 ..< count { samples[frame * count + channel] = values[channelBase + channel] }
            }
            channelBase += count
        }
        let mic = RingBuffer(capacity: 16)
        let tap = RingBuffer(capacity: 16)
        AudioTrackMixer.write(buffers, channels: 0 ..< 2, into: mic)
        AudioTrackMixer.write(buffers, channels: 2 ..< 3, into: tap)
        var me: [Float] = []
        var remote: [Float] = []
        mic.drain(into: &me)
        tap.drain(into: &remote)
        #expect(me.count == 4)
        #expect(remote.count == 4)
        #expect(me.allSatisfy { abs($0 - 0.4) < 0.0001 })
        #expect(remote.allSatisfy { abs($0 - 0.9) < 0.0001 })
    }
}
