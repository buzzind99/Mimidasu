import CoreAudio
import Foundation
@testable import Mimi

/// Owns a synthesized `AudioBufferList` and its `AudioStreamBasicDescription`
/// for exercising `SystemAudioCapture`'s data path without the audio HAL
/// (`handleAudioBufferList(box.pointer, asbd: box.asbd)`). The memory lives
/// until the box deinits; the data path reads it synchronously.
///
/// Payload values are deterministic so tests can compute expected downmix and
/// resample results exactly: channel `c`, frame `f` holds `f + c * 10_000`.
/// float32 represents integers exactly up to 2^24, so `.float32` values are
/// exact while `f + c * 10_000 < 16_777_216`; `.int16` writes the same value
/// via `truncatingIfNeeded`, exact only while `f + c * 10_000 <= 32_767`
/// (c ≤ 3 for the usual frame counts, above that it wraps). A stereo
/// deinterleaved downmix of frame `f` is therefore `f + 5_000`, a mono
/// buffer is just `f`.
final class SynthesizedAudioBufferList: @unchecked Sendable {
    let pointer: UnsafePointer<AudioBufferList>
    let asbd: AudioStreamBasicDescription

    private let listMemory: UnsafeMutableRawPointer
    private let payloadMemory: UnsafeMutableRawPointer

    init(
        pointer: UnsafePointer<AudioBufferList>,
        asbd: AudioStreamBasicDescription,
        listMemory: UnsafeMutableRawPointer,
        payloadMemory: UnsafeMutableRawPointer
    ) {
        self.pointer = pointer
        self.asbd = asbd
        self.listMemory = listMemory
        self.payloadMemory = payloadMemory
    }

    deinit {
        listMemory.deallocate()
        payloadMemory.deallocate()
    }
}

enum AudioBufferListSynthesis {

    /// Payload encodings, ordered by what the capture pipeline accepts.
    enum PayloadFormat {
        /// The supported input: float32 LinearPCM.
        case float32
        /// PCM but not float32 — drives `extractMono`'s unsupported-format
        /// branch → `onIOError(.formatUnavailable)`.
        case int16
        /// Non-LinearPCM format ID — drives the data path's non-PCM guard
        /// before any payload extraction.
        case nonPCM
    }

    /// Builds a buffer list with the requested layout.
    ///
    /// - Parameters:
    ///   - frames: sample frames per channel; `0` exercises the zero-frame
    ///     guard in the data path.
    ///   - channels: 1 for mono; ≥ 2 exercises the downmix in either layout.
    ///   - sampleRate: 16 kHz passes through `SystemAudioCapture` untouched;
    ///     any other rate drives its resample fallback.
    ///   - interleaved: one N-channel buffer vs N one-channel buffers.
    ///   - format: payload encoding (see `PayloadFormat`).
    ///   - nullData: leaves every buffer's `mData` nil, the start/stop-
    ///     transition IO cycle that must be ignored rather than treated as a
    ///     format failure.
    static func make(
        frames: Int,
        channels: Int = 1,
        sampleRate: Double = SystemAudioCapture.outputSampleRate,
        interleaved: Bool = true,
        format: PayloadFormat = .float32,
        nullData: Bool = false
    ) -> SynthesizedAudioBufferList {
        let nBuffers = interleaved ? 1 : max(channels, 1)
        let payload = makePayload(
            frames: frames, channels: channels, interleaved: interleaved, format: format
        )

        let payloadMemory = UnsafeMutableRawPointer.allocate(
            byteCount: max(payload.count, 1), alignment: 16
        )
        if !payload.isEmpty {
            payload.withUnsafeBytes { raw in
                payloadMemory.copyMemory(from: raw.baseAddress!, byteCount: payload.count)
            }
        }

        let listSize = MemoryLayout<AudioBufferList>.size
            + (nBuffers - 1) * MemoryLayout<AudioBuffer>.size
        let listMemory = UnsafeMutableRawPointer.allocate(
            byteCount: listSize, alignment: MemoryLayout<AudioBufferList>.alignment
        )
        memset(listMemory, 0, listSize)
        let list = listMemory.assumingMemoryBound(to: AudioBufferList.self)
        list.pointee.mNumberBuffers = UInt32(nBuffers)

        let buffers = UnsafeMutableAudioBufferListPointer(list)
        if nBuffers == 1 {
            buffers[0].mNumberChannels = UInt32(interleaved ? max(channels, 1) : 1)
            buffers[0].mDataByteSize = UInt32(payload.count)
            buffers[0].mData = nullData ? nil : payloadMemory
        } else {
            // Deinterleaved: one frames-wide slice per channel, channel-major
            // in the payload (see `makePayload`).
            let slice = frames * MemoryLayout<Float>.size
            for c in 0 ..< nBuffers {
                buffers[c].mNumberChannels = 1
                buffers[c].mDataByteSize = UInt32(slice)
                buffers[c].mData = nullData ? nil : payloadMemory.advanced(by: c * slice)
            }
        }

        return SynthesizedAudioBufferList(
            pointer: UnsafePointer(list),
            asbd: makeASBD(
                channels: channels, sampleRate: sampleRate, interleaved: interleaved,
                format: format
            ),
            listMemory: listMemory,
            payloadMemory: payloadMemory
        )
    }

    // MARK: - Pieces

    private static func makeASBD(
        channels: Int, sampleRate: Double, interleaved: Bool, format: PayloadFormat
    ) -> AudioStreamBasicDescription {
        switch format {
        case .float32, .int16:
            let bytesPerSample = format == .float32 ? 4 : 2
            var flags = format == .float32
                ? kAudioFormatFlagIsFloat
                : kAudioFormatFlagIsSignedInteger
            flags |= kAudioFormatFlagIsPacked
            if !interleaved {
                flags |= kAudioFormatFlagIsNonInterleaved
            }
            return AudioStreamBasicDescription(
                mSampleRate: sampleRate,
                mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: flags,
                mBytesPerPacket: UInt32(bytesPerSample * channels),
                mFramesPerPacket: 1,
                mBytesPerFrame: UInt32(interleaved ? bytesPerSample * channels : bytesPerSample),
                mChannelsPerFrame: UInt32(channels),
                mBitsPerChannel: UInt32(bytesPerSample * 8),
                mReserved: 0
            )
        case .nonPCM:
            return AudioStreamBasicDescription(
                mSampleRate: sampleRate,
                mFormatID: kAudioFormatMPEG4AAC,
                mFormatFlags: 0,
                mBytesPerPacket: 16,
                mFramesPerPacket: 1,
                mBytesPerFrame: 16,
                mChannelsPerFrame: UInt32(channels),
                mBitsPerChannel: 0,
                mReserved: 0
            )
        }
    }

    /// Payload bytes laid out the way CoreAudio reads the format: frame-major
    /// (L R L R …) when interleaved, channel-major (L L L … R R R …) when
    /// deinterleaved. Empty for zero-frame buffers; opaque filler for non-PCM
    /// (its payload is never extracted — the format ID trips first).
    private static func makePayload(
        frames: Int, channels: Int, interleaved: Bool, format: PayloadFormat
    ) -> [UInt8] {
        let bytesPerSample: Int
        switch format {
        case .float32: bytesPerSample = 4
        case .int16: bytesPerSample = 2
        case .nonPCM: return [UInt8](repeating: 0xA5, count: max(frames, 1) * 16)
        }

        var payload = [UInt8](repeating: 0, count: frames * channels * bytesPerSample)
        payload.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            for c in 0 ..< channels {
                for f in 0 ..< frames {
                    let index = interleaved ? f * channels + c : c * frames + f
                    if format == .int16 {
                        let dst = base.assumingMemoryBound(to: Int16.self)
                        dst[index] = Int16(truncatingIfNeeded: f + c * 10000)
                    } else {
                        let dst = base.assumingMemoryBound(to: Float.self)
                        dst[index] = Float(f + c * 10000)
                    }
                }
            }
        }
        return payload
    }
}
