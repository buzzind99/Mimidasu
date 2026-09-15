import AVFoundation
import Foundation
import ScreenCaptureKit
import Synchronization

/// Emitted mono 16 kHz chunk (160 ms = 2,560 samples). `samples` is a value
/// type; safe to hand across queues.
struct AudioChunk: Sendable {
    let samples: [Float]
    /// Session-relative sample offset of the first sample.
    let startSample: Int
}

/// Errors surfaced by the capture pipeline.
enum CaptureError: LocalizedError {
    case permissionDenied
    case noDisplayFound
    case streamSetupFailed(String)
    case formatUnavailable

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            "Screen Recording access is required to capture system audio. Grant it "
                + "in System Settings → Privacy & Security → Screen Recording, then restart Mimi."
        case .noDisplayFound:
            "No display available to attach the audio stream to."
        case let .streamSetupFailed(detail):
            "Failed to start system audio capture: \(detail)"
        case .formatUnavailable:
            "Could not process the captured audio format."
        }
    }
}

/// The capture surface `SessionController` drives. `SystemAudioCapture`
/// conforms as-is; tests inject a scripted double so `begin()` and the
/// chunk path run without ScreenCaptureKit.
protocol AudioCapturing: AnyObject, Sendable {
    var onChunk: ((AudioChunk) -> Void)? { get set }
    var onIOError: ((CaptureError) -> Void)? { get set }
    func start() async throws
    func stop()
}

/// Teardown-vs-callback state. Sample callbacks run on `outputQueue`, but
/// `stop()` can be called from any thread — the capture's mutex is what
/// fences an in-flight callback against teardown: one that passed the cheap
/// entry check re-checks under the mutex before touching state or calling
/// `onChunk`, so no chunk can land after `stop()` returns.
private struct CaptureState {
    var isRunning = false
    var accumulated: [Float] = []
    /// Read cursor into `accumulated`: consumed chunks compact once per
    /// callback instead of a `removeFirst` memmove per chunk.
    var accumulatedStart = 0
    var emittedSamples = 0
}

/// Captures the entirety of system audio with a ScreenCaptureKit audio-only
/// stream and delivers mono 16 kHz chunks.
///
/// Threading: sample buffers arrive on the dedicated SCK output queue; the
/// delegate downmixes/resamples when needed, slices 160 ms chunks, and calls
/// `onChunk` on that queue. Silence suppression (VAD + RMS backstop) is the
/// engine's job.
///
/// Sendable by locking contract: `state` (a `Mutex`) guards `isRunning` and
/// the chunk accumulator (`accumulated`, `accumulatedStart`,
/// `emittedSamples`) — see the comment there. Two deliberate exemptions,
/// both single-owner: `stream` is only touched after winning the locked
/// `isRunning` handoff (the setter in `start()`, or the one teardown winner
/// between `stop()` and `handleStreamStopped`), and the resample caches
/// (`converter`, `inBuffer`, `outBuffer`) live only on the serial
/// sample-callback path.
final class SystemAudioCapture: NSObject, AudioCapturing, @unchecked Sendable,
    SCStreamDelegate, SCStreamOutput
{
    static let outputSampleRate: Double = 16000
    static let chunkSamples = Int(outputSampleRate * 0.16)
    /// Rate requested from SCK: the system mix's native rate. The 16 kHz
    /// conversion for ASR happens locally (AVAudioConverter), where its
    /// quality is controlled — SCK's internal sample-rate conversion is
    /// opaque, so we avoid asking it to downsample.
    static let captureSampleRate = 48000

    var onChunk: ((AudioChunk) -> Void)?
    var onIOError: ((CaptureError) -> Void)?

    private let outputQueue = DispatchQueue(
        label: "mimi.capture.sck", qos: .userInteractive
    )

    private let state = Mutex(CaptureState())

    private var stream: SCStream?
    private var converter: AVAudioConverter?
    private var cachedConverterRate: Double = 0

    var isRunning: Bool {
        state.withLock { current in current.isRunning }
    }

    // MARK: - Permission

    /// Triggers the TCC prompt when undetermined. Returns false if Screen
    /// Recording has not been granted (granting requires an app restart).
    static func ensurePermission() async -> Bool {
        if CGPreflightScreenCaptureAccess() {
            return true
        }
        // The shareable-content query triggers the system prompt.
        _ = try? await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: false
        )
        return CGPreflightScreenCaptureAccess()
    }

    // MARK: - Lifecycle

    func start() async throws {
        guard !isRunning else { return }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true
            )
        } catch {
            throw CaptureError.streamSetupFailed(error.localizedDescription)
        }
        guard let display = content.displays.first else {
            throw CaptureError.noDisplayFound
        }

        // Whole-system audio: one display-scoped filter with Mimi's own app
        // removed; the stream config excludes this process's audio as well.
        let apps = content.applications.filter { app in
            app.bundleIdentifier != Bundle.main.bundleIdentifier
        }
        let filter = SCContentFilter(
            display: display, excludingApplications: apps, exceptingWindows: []
        )

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = Self.captureSampleRate
        config.channelCount = 1
        // Audio-only stream: keep the (unused) video track as cheap as possible.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 10)
        config.queueDepth = 3

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        self.stream = stream
        do {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: outputQueue)
            try await stream.startCapture()
        } catch {
            self.stream = nil
            throw CaptureError.streamSetupFailed(error.localizedDescription)
        }

        state.withLock { current in current.isRunning = true }
        #if DEBUG
            print("[capture] SCK system-audio stream started (target: 48 kHz mono in, 16 kHz out)")
        #endif
    }

    func stop() {
        let wasRunning = state.withLock { current -> Bool in
            guard current.isRunning else { return false }
            current.isRunning = false
            current.accumulated.removeAll(keepingCapacity: true)
            current.accumulatedStart = 0
            return true
        }
        guard wasRunning else { return }

        let stream = stream
        self.stream = nil
        Task {
            try? await stream?.stopCapture()
            try? stream?.removeStreamOutput(self, type: .audio)
        }
    }

    // MARK: - Test seam

    /// Marks the capture as running without a live SCK stream so the delegate
    /// data path can be exercised directly via `handleSampleBuffer`.
    /// Production reaches the same state through `start()`.
    func setRunningForTesting(_ value: Bool) {
        state.withLock { current in current.isRunning = value }
    }

    /// Invoked at the top of `extractMono` — before the buffer-list copy and
    /// downmix — so tests can park an in-flight callback past every entry
    /// guard and fence teardown against it deterministically. Nil in
    /// production.
    var onExtractionEntered: (() -> Void)?

    // MARK: - SCStreamDelegate

    /// Forwards to the internal seam — tests drive `handleStreamStopped`
    /// directly instead of constructing an `SCStream`.
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        handleStreamStopped(error)
    }

    /// `SCStreamDelegate` seam: teardown of a dead stream. Mirrors `stop()`'s
    /// state reset so a dead stream never leaves stale accumulator state
    /// behind.
    func handleStreamStopped(_ error: Error) {
        let wasRunning = state.withLock { current -> Bool in
            guard current.isRunning else { return false }
            current.isRunning = false
            current.accumulated.removeAll(keepingCapacity: true)
            current.accumulatedStart = 0
            return true
        }
        guard wasRunning else { return }
        stream = nil
        onIOError?(.streamSetupFailed(error.localizedDescription))
    }

    // MARK: - SCStreamOutput

    /// Forwards to the internal seam — tests drive `handleSampleBuffer`
    /// directly with synthesized sample buffers.
    func stream(
        _ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        handleSampleBuffer(sampleBuffer, type: type)
    }

    /// `SCStreamOutput` seam: the sample callback data path (guards, downmix,
    /// resample, chunking). Synchronous, so tests get a deterministic stop
    /// fence.
    func handleSampleBuffer(_ sampleBuffer: CMSampleBuffer, type: SCStreamOutputType) {
        guard type == .audio, isRunning, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
        guard let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else {
            return
        }
        let asbd = asbdPtr.pointee
        guard asbd.mFormatID == kAudioFormatLinearPCM else { return }
        let deliveredFrames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard deliveredFrames > 0 else { return }

        guard let mono = extractMono(sampleBuffer: sampleBuffer, asbd: asbd) else {
            onIOError?(.formatUnavailable)
            return
        }
        guard !mono.isEmpty else { return }

        // The entry `isRunning` check is only a pre-filter; `stop()` may have
        // fenced teardown while this callback was extracting. The locked
        // re-check makes teardown vs. in-flight-callback mutually exclusive.
        var formatUnavailable = false
        state.withLock { current in
            guard current.isRunning else { return }
            guard appendToAccumulator(mono, asbd: asbd, into: &current) else {
                formatUnavailable = true
                return
            }
            emitFixedChunks(&current)
        }
        if formatUnavailable {
            onIOError?(.formatUnavailable)
        }
    }

    /// Caller holds the state mutex. Appends `mono` to the accumulator,
    /// resampling when the source rate differs from 16 kHz; false when the
    /// format can't be converted.
    private func appendToAccumulator(
        _ mono: [Float], asbd: AudioStreamBasicDescription, into current: inout CaptureState
    ) -> Bool {
        if asbd.mSampleRate == Self.outputSampleRate {
            current.accumulated.append(contentsOf: mono)
            return true
        }
        guard let converted = resample(mono, from: asbd.mSampleRate) else {
            return false
        }
        current.accumulated.append(contentsOf: converted)
        return true
    }

    // MARK: - Resample (primary path: SCK delivers the native 48 kHz mix)

    private lazy var outputFormat: AVAudioFormat = .init(
        standardFormatWithSampleRate: Self.outputSampleRate, channels: 1
    )!

    /// PCM buffers reused across chunks (reallocated only if a future
    /// source rate/duration needs more capacity).
    private var cachedInputFormat: AVAudioFormat?
    private var inBuffer: AVAudioPCMBuffer?
    private var outBuffer: AVAudioPCMBuffer?

    private func resample(_ mono: [Float], from rate: Double) -> [Float]? {
        if cachedConverterRate != rate {
            guard let inFormat = AVAudioFormat(
                standardFormatWithSampleRate: rate, channels: 1
            ),
                let newConverter = AVAudioConverter(from: inFormat, to: outputFormat)
            else {
                print("AVAudioConverter creation failed: \(rate) → \(outputFormat)")
                return nil
            }
            converter = newConverter
            cachedInputFormat = inFormat
            cachedConverterRate = rate
            inBuffer = nil
            outBuffer = nil
        }
        guard let converter, let inFormat = cachedInputFormat else { return nil }

        if inBuffer == nil || inBuffer!.frameCapacity < AVAudioFrameCount(mono.count) {
            inBuffer = AVAudioPCMBuffer(
                pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(mono.count)
            )
        }
        guard let inBuffer, inBuffer.floatChannelData != nil else { return nil }
        inBuffer.frameLength = AVAudioFrameCount(mono.count)
        if let dst = inBuffer.floatChannelData?[0] {
            mono.withUnsafeBufferPointer { src in
                dst.update(from: src.baseAddress!, count: mono.count)
            }
        }

        // The converter carries a priming backlog, so a single `convert` can
        // fill the output buffer and still report `.haveData`; size it with
        // headroom and keep draining until it reports `.inputRanDry` (below),
        // or the tail of each callback's samples would be clipped.
        let ratio = Self.outputSampleRate / rate
        let outCapacity = AVAudioFrameCount(Double(mono.count) * ratio) + AVAudioFrameCount(mono.count) + 32
        if outBuffer == nil || outBuffer!.frameCapacity < outCapacity {
            outBuffer = AVAudioPCMBuffer(
                pcmFormat: outputFormat, frameCapacity: outCapacity
            )
        }
        guard let outBuffer else { return nil }

        return drain(inBuffer, through: converter, into: outBuffer)
    }

    /// Drains `input` through `converter`, accumulating every output frame.
    /// Loops while the converter reports `.haveData` (output buffer full,
    /// more pending) instead of converting once, so its priming backlog is
    /// never clipped. Returns `nil` on conversion failure.
    ///
    /// The converter's input block is `@Sendable`: `input` is captured by
    /// value and its single feed gated with a Mutex (the block is invoked
    /// serially, but the compiler can't see that). `nonisolated(unsafe)`
    /// suppresses the `AVAudioPCMBuffer` sendability diagnostic — the buffer
    /// only escapes into the converter, which serially drains it. The input
    /// status is `.noDataNow`, never `.endOfStream`: the latter is terminal,
    /// latching the converter into an ended state so every later callback
    /// converts to zero frames. `.noDataNow` just says this callback has no
    /// more input, keeping a persistent converter usable across the stream.
    private func drain(
        _ input: AVAudioPCMBuffer,
        through converter: AVAudioConverter,
        into outBuffer: AVAudioPCMBuffer
    ) -> [Float]? {
        nonisolated(unsafe) let inputBuffer = input
        let fed = Mutex(false)
        var output: [Float] = []
        var status: AVAudioConverterOutputStatus = .haveData
        repeat {
            outBuffer.frameLength = 0
            var conversionError: NSError?
            status = converter.convert(to: outBuffer, error: &conversionError) { _, inputStatus in
                if fed.withLock({ fed in fed }) {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                inputStatus.pointee = .haveData
                fed.withLock { fed in fed = true }
                return inputBuffer
            }
            guard status != .error, conversionError == nil,
                  let src = outBuffer.floatChannelData?[0]
            else { return nil }

            let n = Int(outBuffer.frameLength)
            output.append(contentsOf: UnsafeBufferPointer(start: src, count: n))
        } while status == .haveData
        return output
    }

    // MARK: - Chunking

    /// Slice the accumulator into 160 ms chunks and deliver. Caller holds
    /// the state mutex (`withLock` scope); `onChunk` fires under it (handlers
    /// never re-enter capture state, so this cannot deadlock).
    private func emitFixedChunks(_ current: inout CaptureState) {
        let chunkSize = Self.chunkSamples
        while current.accumulated.count - current.accumulatedStart >= chunkSize {
            let chunk = Array(
                current.accumulated[current.accumulatedStart ..< current.accumulatedStart + chunkSize]
            )
            current.accumulatedStart += chunkSize

            let chunkObj = AudioChunk(
                samples: chunk, startSample: current.emittedSamples
            )
            current.emittedSamples += chunkSize
            onChunk?(chunkObj)
        }
        // One compaction per callback (not per chunk): amortizes the
        // memmove when several chunks arrive together.
        if current.accumulatedStart > 0 {
            current.accumulated.removeFirst(current.accumulatedStart)
            current.accumulatedStart = 0
        }
    }
}

// MARK: - PCM extraction

extension SystemAudioCapture {

    /// Pulls float32 PCM out of the sample buffer and downmixes to mono.
    /// Handles both interleaved (one buffer, N channels) and deinterleaved
    /// (N one-channel buffers) layouts.
    private func extractMono(sampleBuffer: CMSampleBuffer, asbd: AudioStreamBasicDescription) -> [Float]? {
        onExtractionEntered?()
        guard MemoryLayout<Float>.size == 4, asbd.mBitsPerChannel == 32,
              asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        else {
            print("unsupported SCK audio format: \(asbd)")
            return nil
        }

        guard let copy = audioBufferListCopy(from: sampleBuffer) else { return nil }
        defer { copy.cleanup() }
        return downmixToMono(
            buffers: copy.buffers,
            frames: copy.frames,
            channels: copy.channels,
            interleaved: copy.interleaved
        )
    }

    /// Raw copy of a sample buffer's `AudioBufferList` plus its PCM layout.
    /// `abl` points into memory owned by this struct; the caller must invoke
    /// `cleanup()` once the buffer pointers are no longer needed (the
    /// retained block buffer keeps the PCM payload alive until then).
    private struct AudioBufferListCopy {
        let abl: UnsafeMutablePointer<AudioBufferList>
        let blockBuffer: CMBlockBuffer
        let buffers: UnsafeMutableAudioBufferListPointer
        let frames: Int
        let channels: Int
        let interleaved: Bool

        func cleanup() {
            abl.deallocate()
        }
    }

    /// Copies the buffer list out of the sample buffer (two-pass: query the
    /// exact required size first — it includes the PCM payload, not just the
    /// list struct — then fill the list) and analyzes its layout. On failure
    /// the copy is freed and `nil` returned.
    private func audioBufferListCopy(from sampleBuffer: CMSampleBuffer) -> AudioBufferListCopy? {
        var listSize = 0
        var status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: &listSize,
            bufferListOut: nil, bufferListSize: 0,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: nil
        )
        guard status == noErr, listSize > 0 else {
            print("CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer (size): \(status)")
            return nil
        }

        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: listSize, alignment: MemoryLayout<AudioBufferList>.alignment
        )
        let abl = raw.assumingMemoryBound(to: AudioBufferList.self)
        var copy: AudioBufferListCopy?
        defer {
            if copy == nil {
                raw.deallocate()
            }
        }
        memset(abl, 0, listSize)

        var blockBuffer: CMBlockBuffer?
        status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: nil,
            bufferListOut: abl, bufferListSize: listSize,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else {
            print("CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer: \(status)")
            return nil
        }
        // The payload lives in the retained block buffer; it must outlive
        // the reads of the buffer list pointers below.
        guard let blockBuffer, blockBuffer.dataLength > 0 else { return nil }

        let buffers = UnsafeMutableAudioBufferListPointer(abl)
        let nBuffers = Int(abl.pointee.mNumberBuffers)
        guard nBuffers >= 1, buffers[0].mData != nil else { return nil }

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
        guard frames > 0, channels > 0 else { return nil }

        copy = AudioBufferListCopy(
            abl: abl, blockBuffer: blockBuffer, buffers: buffers,
            frames: frames, channels: channels, interleaved: interleaved
        )
        return copy
    }

    /// Averages all channels to mono. `buffers` must stay valid (its backing
    /// memory is freed by the caller after this returns).
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
