import AVFoundation
import CoreAudio
import Foundation
import Synchronization

/// Emitted mono 16 kHz chunk (160 ms = 2,560 samples). `samples` is a value
/// type; safe to hand across queues.
struct AudioChunk: Sendable {
    let samples: [Float]
    /// Session-relative sample offset of the first sample.
    let startSample: Int
}

/// Errors surfaced by the capture pipeline.
enum CaptureError: LocalizedError, Equatable {
    /// The system refused tap capture: the system-audio recording permission
    /// (a TCC category separate from Microphone) is missing or denied. Carries
    /// the raw HAL status because both statuses it is built from also arise
    /// without a permission problem (`'!hog'` from a hog-mode conflict,
    /// `'nope'` from any illegal operation); keeping the code in the message
    /// lets support tell the cases apart.
    case audioCaptureDenied(OSStatus)
    /// The capture stream died after it started — output device removed, tap
    /// revoked, aggregate reconfigured. Distinct from `.setupFailed` so
    /// the mid-session card doesn't misreport a loss as a failed start.
    case captureLost(String)
    case setupFailed(String)
    case formatUnavailable

    var errorDescription: String? {
        switch self {
        case let .audioCaptureDenied(status):
            "System audio recording is not permitted. Grant it in System Settings → "
                + "Privacy & Security → Screen & System Audio Recording, then start again. "
                + "(HAL status \(status))"
        case let .captureLost(detail):
            "System audio capture stopped: \(detail)"
        case let .setupFailed(detail):
            "Failed to start system audio capture: \(detail)"
        case .formatUnavailable:
            "Could not process the captured audio format."
        }
    }

    /// Classifies a failed `AudioDeviceStart`. The HAL refuses unpermitted
    /// capture with its generic `'nope'` (kAudioHardwareIllegalOperationError)
    /// or `'!hog'` (kAudioDevicePermissionsError) — there is no TCC-specific
    /// status, so the raw status is carried into the `.audioCaptureDenied`
    /// message. Only `AudioDeviceStart` maps to `.audioCaptureDenied`: it is
    /// the aggregate's first IO that triggers the TCC prompt, so
    /// tap/aggregate creation succeeds while unpermitted and a failure there
    /// is a real setup bug, not a denial.
    static func classifyStartStatus(_ status: OSStatus) -> CaptureError {
        let refused = status == kAudioHardwareIllegalOperationError
            || status == kAudioDevicePermissionsError
        return refused
            ? .audioCaptureDenied(status)
            : .setupFailed("AudioDeviceStart: \(status)")
    }
}

/// The capture surface `SessionController` drives. `SystemAudioCapture`
/// conforms as-is; tests inject a scripted double so `begin()` and the
/// chunk path run without the audio HAL.
protocol AudioCapturing: AnyObject, Sendable {
    /// Chunks arrive on the capture's dedicated IO queue.
    var onChunk: ((AudioChunk) -> Void)? { get set }
    /// Errors arrive on the IO queue (data-path failures) or the listener
    /// queue (device death / tap removal) — not necessarily main.
    var onIOError: ((CaptureError) -> Void)? { get set }
    func start() async throws
    func stop()
}

/// Teardown-vs-callback state. Sample callbacks run on `ioQueue`, but
/// `stop()` can be called from any thread — the capture's mutex is what
/// fences an in-flight callback against teardown: one that passed the cheap
/// entry check re-checks under the mutex before touching state or calling
/// `onChunk`, so no chunk can land after `stop()` returns.
private struct CaptureState {
    var isRunning = false
    /// True for the whole of `start()`, so two concurrent starts can't both
    /// pass the `isRunning` guard and clobber each other's HAL objects.
    var isStarting = false
    var accumulated: [Float] = []
    /// Read cursor into `accumulated`: consumed chunks compact once per
    /// callback instead of a `removeFirst` memmove per chunk.
    var accumulatedStart = 0
    var emittedSamples = 0
}

/// Captures the entirety of system audio with a Core Audio process tap and
/// delivers mono 16 kHz chunks.
///
/// A global `CATapDescription` tap (excluding Mimi's own process) is attached
/// as the sole input of a private aggregate device; an IO block on that
/// device receives the system mix each IO cycle. The tap keeps playback
/// unmuted — audio still reaches the speakers.
///
/// Threading: IO blocks arrive on the dedicated `ioQueue`; the block extracts
/// and downmixes the PCM, slices 160 ms chunks, and calls `onChunk` on that
/// queue. Silence suppression (VAD + RMS backstop) is the engine's job.
///
/// Sendable by locking contract: `state` (a `Mutex`) guards `isRunning`, the
/// in-flight-start flag, and the chunk accumulator (`accumulated`,
/// `accumulatedStart`, `emittedSamples`) — see the comment there. `halRig`
/// (`AudioCaptureHAL`) owns the tap/aggregate/IOProc IDs, their property
/// listeners, and the live tap format; a single claim wins teardown, so a
/// concurrent `stop()`/`deinit`/`handleDeviceDied` can never double-destroy.
/// The resample caches (`converter`, `cachedConverterRate`, `cachedInputFormat`,
/// `inBuffer`, `outBuffer`) are touched only while holding `state`: the IO path
/// resamples inside the locked append scope, and teardown clears them under the
/// same lock, so an in-flight callback can never use a half-reset converter.
final class SystemAudioCapture: NSObject, AudioCapturing, @unchecked Sendable {
    /// Target rate for the ASR mono chunks. The tap delivers the system mix at
    /// the output device's native rate (nominally 48 kHz); conversion to this
    /// rate happens locally (AVAudioConverter), where its quality is controlled.
    static let outputSampleRate: Double = 16000
    static let chunkSamples = Int(outputSampleRate * 0.16)
    /// Bound on `drain`'s converter passes. A healthy converter needs one or
    /// two; a pathological one reporting `.haveData` with zero frames forever
    /// must not hang the realtime IO thread.
    static let maxDrainPasses = 128

    var onChunk: ((AudioChunk) -> Void)?
    var onIOError: ((CaptureError) -> Void)?

    private let ioQueue = DispatchQueue(
        label: "mimi.capture.tap", qos: .userInteractive
    )
    private let listenerQueue = DispatchQueue(
        label: "mimi.capture.tap.listener", qos: .userInitiated
    )

    private let state = Mutex(CaptureState())

    /// Owns the tap, aggregate, IO proc, property listeners, and the live tap
    /// format; see `AudioCaptureHAL`.
    private let halRig = AudioCaptureHAL()

    /// Resample caches. Guarded by `state`: the IO path fills them inside the
    /// locked append scope, and teardown clears them under the same lock.
    private var converter: AVAudioConverter?
    private var cachedConverterRate: Double = 0

    var isRunning: Bool {
        state.withLock { current in current.isRunning }
    }

    // MARK: - Lifecycle

    func start() async throws {
        // The whole of start() runs under the `isStarting` claim so two
        // concurrent calls can't both pass the guard and overwrite each
        // other's HAL objects (which would orphan a tap and aggregate).
        let began = state.withLock { current -> Bool in
            guard !current.isRunning, !current.isStarting else { return false }
            current.isStarting = true
            return true
        }
        guard began else { return }
        defer { state.withLock { current in current.isStarting = false } }

        // Whole-system mix minus Mimi itself.
        let exclusions = try [NSNumber(value: ProcessTapFactory.currentProcessObject())]
        let tap = try ProcessTapFactory.createTap(excluding: exclusions)
        halRig.trackTap(tap.objectID)
        do {
            let asbd = try ProcessTapFactory.tapFormat(of: tap.objectID)
            halRig.storeTapFormat(asbd)
        } catch {
            teardownHALNow()
            throw error
        }

        let aggregate: AudioDeviceID
        do {
            aggregate = try ProcessTapFactory.createAggregateDevice(for: tap)
        } catch {
            teardownHALNow()
            throw error
        }
        halRig.trackAggregate(aggregate)

        // The block is Block_copy'd and outlives this call, so it reaches the
        // capture through a weak box — no retain cycle with the stored
        // IOProcID. It captures the rig strongly (the rig never retains the
        // capture). Its audio-buffer param is a non-optional C pointer.
        let box = WeakRef(self)
        var procID: AudioDeviceIOProcID?
        let procStatus = AudioDeviceCreateIOProcIDWithBlock(
            &procID, aggregate, ioQueue
        ) { [halRig = self.halRig] _, inputData, _, _, _ in
            guard let asbd = halRig.currentTapFormat, let capture = box.value else { return }
            capture.handleAudioBufferList(inputData, format: asbd)
        }
        guard procStatus == noErr, let procID else {
            // Defensive: status and procID are linked in practice, but a
            // non-nil procID returned alongside an error would leak — the
            // stored-ID teardown below can't see it.
            if let procID {
                AudioDeviceDestroyIOProcID(aggregate, procID)
            }
            teardownHALNow()
            throw CaptureError.setupFailed("AudioDeviceCreateIOProcIDWithBlock: \(procStatus)")
        }
        halRig.trackIOProc(procID)

        halRig.registerListeners(
            aggregate: aggregate, tap: tap.objectID, queue: listenerQueue
        ) { [weak self] error in
            self?.handleDeviceDied(error)
        }

        let startStatus = AudioDeviceStart(aggregate, procID)
        guard startStatus == noErr else {
            teardownHALNow()
            throw CaptureError.classifyStartStatus(startStatus)
        }

        state.withLock { current in
            current.isRunning = true
        }
        #if DEBUG
            let rate = halRig.currentTapFormat?.mSampleRate ?? 0
            print("[capture] process-tap system-audio IO started (tap format: \(rate) Hz, target: 16 kHz mono out)")
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

        // `AudioDeviceStop` waits for in-flight IO blocks to drain, so the
        // fence above plus the blocks' own locked re-check guarantee no chunk
        // lands after `stop()` returns. The HAL wait hops off the caller
        // thread (it can block for an IO period); the claim happens
        // synchronously so a deinit racing the task can't leak or double-free.
        halRig.teardownDetached(on: listenerQueue)
        resetResamplerCaches()
    }

    // MARK: - Test seam

    /// Marks the capture as running without a live tap so the data path can
    /// be exercised directly via `handleAudioBufferList`. Production reaches
    /// the same state through `start()`.
    func setRunningForTesting(_ value: Bool) {
        state.withLock { current in current.isRunning = value }
    }

    /// Invoked at the top of `extractMono` — before the downmix — so tests
    /// can park an in-flight callback past every entry guard and fence
    /// teardown against it deterministically. Nil in production.
    var onExtractionEntered: (() -> Void)?

    // MARK: - Dead-device recovery

    /// Forwards to the internal seam — tests drive `handleDeviceDied`
    /// directly instead of constructing HAL objects.
    func handleDeviceDied(_ error: Error) {
        let wasRunning = state.withLock { current -> Bool in
            guard current.isRunning else { return false }
            current.isRunning = false
            current.accumulated.removeAll(keepingCapacity: true)
            current.accumulatedStart = 0
            return true
        }
        guard wasRunning else { return }
        // Already off the main actor (listener queue / test thread), so the
        // HAL drain can run inline.
        teardownHALNow()
        onIOError?(.captureLost(error.localizedDescription))
    }

    /// Synchronous HAL teardown plus the resample-cache reset, for the
    /// `start()` failure arms and the dead-device path (both already off the
    /// caller's critical thread).
    private func teardownHALNow() {
        halRig.teardownBlocking(on: listenerQueue)
        resetResamplerCaches()
    }

    /// Drops the resampler's cached converter and buffers. Runs under the state
    /// lock so it is mutually exclusive with an in-flight callback resampling
    /// (the IO path holds the same lock around `append`).
    private func resetResamplerCaches() {
        state.withLock { _ in
            converter = nil
            cachedConverterRate = 0
            cachedInputFormat = nil
            inBuffer = nil
            outBuffer = nil
        }
    }

    deinit {
        // Never block the caller: `SessionController` nils the capture on the
        // main actor, and the HAL drain can wait an IO period.
        halRig.teardownDetached(on: listenerQueue)
    }

    // MARK: - IO-block data path

    /// The IO block callback data path (guards, downmix, resample, chunking).
    /// Synchronous, so tests get a deterministic stop fence.
    func handleAudioBufferList(
        _ abl: UnsafePointer<AudioBufferList>, format: AudioStreamBasicDescription
    ) {
        guard isRunning else { return }
        guard format.mFormatID == kAudioFormatLinearPCM else { return }

        guard let mono = extractMono(from: abl, format: format) else {
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
            guard append(mono, format: format, to: &current) else {
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
    private func append(
        _ mono: [Float], format: AudioStreamBasicDescription, to state: inout CaptureState
    ) -> Bool {
        if format.mSampleRate == Self.outputSampleRate {
            state.accumulated.append(contentsOf: mono)
            return true
        }
        guard let converted = resample(mono, from: format.mSampleRate) else {
            return false
        }
        state.accumulated.append(contentsOf: converted)
        return true
    }

    // MARK: - Resample (primary path: taps deliver the native 48 kHz mix)

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
    /// never clipped. Returns `nil` on conversion failure, and is bounded by
    /// `maxDrainPasses` — a converter stuck on `.haveData` with zero frames
    /// would otherwise spin the realtime IO thread forever.
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
        into output: AVAudioPCMBuffer
    ) -> [Float]? {
        nonisolated(unsafe) let inputBuffer = input
        let fed = Mutex(false)
        var samples: [Float] = []
        var status: AVAudioConverterOutputStatus = .haveData
        var passes = 0
        repeat {
            passes += 1
            output.frameLength = 0
            var conversionError: NSError?
            status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
                if fed.withLock({ fed in fed }) {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                inputStatus.pointee = .haveData
                fed.withLock { fed in fed = true }
                return inputBuffer
            }
            guard status != .error, conversionError == nil,
                  let src = output.floatChannelData?[0]
            else { return nil }

            let n = Int(output.frameLength)
            samples.append(contentsOf: UnsafeBufferPointer(start: src, count: n))
        } while status == .haveData && passes < Self.maxDrainPasses
        #if DEBUG
            if status == .haveData {
                print("[capture] converter drain hit the \(Self.maxDrainPasses)-pass cap; truncating this callback")
            }
        #endif
        return samples
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

/// Weak, sendable hop for the block-captured IO closure: the capture must be
/// releasable while the HAL still holds the block.
private final class WeakRef<T: AnyObject>: @unchecked Sendable {
    weak var value: T?

    init(_ value: T?) {
        self.value = value
    }
}
