import CoreAudio
import Foundation

// MARK: - PCM extraction

extension SystemAudioCapture {

    /// Pulls float32 PCM out of the buffer list and downmixes to mono.
    /// Handles both interleaved (one buffer, N channels) and deinterleaved
    /// (N one-channel buffers) layouts. Returns `nil` only for formats the
    /// pipeline can't read; an IO cycle that simply carries no data (a null
    /// `mData`, a zero-frame buffer) returns an empty array so the caller
    /// ignores that cycle instead of ending the session.
    func extractMono(
        from abl: UnsafePointer<AudioBufferList>, format: AudioStreamBasicDescription
    ) -> [Float]? {
        onExtractionEntered?()
        guard MemoryLayout<Float>.size == 4, format.mBitsPerChannel == 32,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0
        else {
            print("unsupported tap audio format: \(format)")
            return nil
        }

        let buffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: abl)
        )
        let nBuffers = Int(abl.pointee.mNumberBuffers)
        // No buffers / null data happens on start-stop transitions; it is not
        // an unsupported format, so treat it like the zero-frame case below.
        guard nBuffers >= 1, buffers[0].mData != nil else { return [] }

        var channels = 0
        var interleaved = false
        var frames = 0
        if nBuffers == 1 {
            channels = max(1, Int(buffers[0].mNumberChannels))
            interleaved = channels > 1
            frames = Int(buffers[0].mDataByteSize) / MemoryLayout<Float>.size / channels
        } else {
            channels = nBuffers
            interleaved = false
            frames = Int(buffers[0].mDataByteSize) / MemoryLayout<Float>.size
        }
        guard frames > 0, channels > 0 else { return [] }

        return downmixToMono(
            buffers: buffers, frames: frames, channels: channels, interleaved: interleaved
        )
    }

    /// Averages all channels to mono. `buffers` must stay valid (its backing
    /// memory is owned by the HAL for the duration of the IO block).
    private func downmixToMono(
        buffers: UnsafeMutableAudioBufferListPointer,
        frames: Int,
        channels: Int,
        interleaved: Bool
    ) -> [Float] {
        let firstData = buffers[0].mData!

        var mono = [Float](repeating: 0, count: frames)
        let scale = 1.0 / Float(channels)
        for f in 0 ..< frames {
            var sum: Float = 0
            for ch in 0 ..< channels {
                let ptr: UnsafeMutablePointer<Float>
                if interleaved {
                    ptr = firstData.assumingMemoryBound(to: Float.self)
                    sum += ptr[f * channels + ch]
                } else {
                    guard let data = buffers[ch].mData else { continue }
                    ptr = data.assumingMemoryBound(to: Float.self)
                    sum += ptr[f]
                }
            }
            mono[f] = channels > 1 ? sum * scale : sum
        }
        return mono
    }
}
