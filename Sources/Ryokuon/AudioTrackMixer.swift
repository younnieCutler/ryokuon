import AudioToolbox

/// Aggregate inputs can be planar or interleaved. Average each track's
/// channels per frame: concatenating channels doubles duration for stereo mics.
/// The IOProc calls this synchronously; it allocates no sample arrays.
enum AudioTrackMixer {
    static func write(_ buffers: UnsafeMutableAudioBufferListPointer,
                      channels selected: Range<Int>, into ring: RingBuffer) {
        guard !selected.isEmpty else { return }
        var frames = 0
        for buffer in buffers where buffer.mNumberChannels > 0 {
            frames = max(frames, Int(buffer.mDataByteSize) / MemoryLayout<Float>.size / Int(buffer.mNumberChannels))
        }
        ring.write(count: frames) { frame in
            var channelBase = 0
            var sum: Float = 0
            var count = 0
            for buffer in buffers {
                let channels = Int(buffer.mNumberChannels)
                defer { channelBase += channels }
                guard channels > 0, let raw = buffer.mData else { continue }
                let available = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size / channels
                guard frame < available else { continue }
                let samples = raw.assumingMemoryBound(to: Float.self)
                for channel in 0 ..< channels where selected.contains(channelBase + channel) {
                    sum += samples[frame * channels + channel]
                    count += 1
                }
            }
            return count > 0 ? sum / Float(count) : 0
        }
    }
}
