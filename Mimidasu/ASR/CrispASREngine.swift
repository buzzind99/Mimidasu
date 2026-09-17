import Foundation
import Synchronization

/// Swift wrapper over `libcrispasr.dylib` (stable C session ABI, bound at
/// runtime with dlopen/dlsym so the app builds and launches before the native
/// runtime is installed).
///
/// Runs the CrispASR backend detected from the GGUF's architecture header
/// (`crispasr_detect_backend_from_gguf` — `sensevoice` for Lite, `funasr`
/// for Full; neither has cache-aware streaming) — the sliding window lives
/// here instead of in the C library:
///
///   - `push` appends 160 ms chunks to a rolling utterance buffer (bounded by
///     a forced-final cap) plus a 10 s window used for partial decodes.
///   - FireRedVAD (via `crispasr_vad_slices`) runs on a dedicated VAD queue
///     every 500 ms and is the authoritative speech signal: it separates
///     speech from BGM, gates partial decodes, and finalizes an utterance
///     once it has confirmed `endpointSamples` of silence after the last
///     speech span. Buffers the VAD finds speechless are discarded without
///     decoding.
///   - A cheap per-chunk RMS check (`utteranceHasLoudAudio`) is only a
///     backstop so truly silent audio is never decoded — including in
///     degraded mode (VAD model unavailable: cap-only finals, no partials).
///   - A `step`-spaced window decode posts `.partial` events (HUD draft text);
///     the endpoint redecodes the buffered utterance PCM (CrispASR's
///     "redecode" final mode) and posts one clean `.final`.
///
/// Threading: pushes land on the caller's audio thread but only take the
/// state mutex; actual decoding runs on a dedicated serial queue so the main
/// thread's 60 ms `poll()` loop never blocks behind a multi-second decode.
/// VAD analysis runs on its own serial queue: an AR decode takes seconds,
/// and endpointing must never wait behind one (a starved VAD freezes both
/// the partial gate and silence detection). The two job types interlock
/// only through the state mutex; the C library serializes VAD access to the
/// cached model internally.
///
/// Sendability: all mutable engine state lives in `State` behind a `Mutex`
/// (`state`), and `prepareMutex` serializes prepare/close, so the engine is
/// safe to hand across concurrency domains (e.g. `finish()` runs detached
/// from the main actor on session stop). `@unchecked` remains for
/// `onEngineError` and the injected library seam, neither of which the
/// compiler can see as thread-confined.
final class CrispASREngine: ASREngine, @unchecked Sendable {
    let isMock = false

    /// Called on an arbitrary thread when a decode fails or the VAD degrades
    /// to cap-only finalization. Throttled by the engine to the first failure
    /// and then once every 32 consecutive ones.
    var onEngineError: ((String) -> Void)?

    private let modelPath: String
    let languageCode: String
    let lib: any CrispASRLibraryAPI

    // Window/endpointing knobs (mirrors the CLI defaults where sensible).
    static let sampleRate = 16000
    static let stepSamples = 1 * sampleRate // decode cadence
    static let lengthSamples = 10 * sampleRate // rolling window cap
    /// How much confirmed silence after the last VAD speech span triggers a
    /// final. Must stay ≥ the VAD's `min_silence_ms` (below) — that is what
    /// makes a span end + this much analyzed audio a *confirmed* silence gap.
    static let endpointSamples = 1000 * sampleRate / 1000
    /// Forced-final cap: safety net under VAD, and the only endpoint when the
    /// VAD model is unavailable (degraded mode).
    static let utteranceCapSamples = 12 * sampleRate
    /// Tail kept in the rolling window after a final, for decode context.
    static let windowKeepTailSamples = 200 * sampleRate / 1000
    static let minDecodeSamples = 2 * sampleRate // encoder conv-kernel floor
    /// Backstop only (never used for endpointing): marks a buffer as not
    /// truly silent so the cap path never decodes known-silent audio.
    static let speechRMS: Float = 1e-3
    /// Total budget for `finish()` to wait out in-flight decode/VAD jobs.
    /// Bounds the whole drain, not each semaphore wait — a hung C call never
    /// clears its in-flight flag, so per-wait timeouts alone would re-arm
    /// forever. (The synchronous flush decode below stays unbounded: it is a
    /// single direct C call on the session, and aborting mid-call would leave
    /// the C library using a session this side has already torn down.)
    static let drainTimeout: TimeInterval = 30
    /// Per-instance drain budget — defaults to the static budget above.
    /// Injectable so tests can exercise the bounded wait against a held job
    /// without waiting out the full 30 s.
    var drainTimeout = CrispASREngine.drainTimeout

    // FireRedVAD (via the dispatcher-backed crispasr_vad_slices ABI; the
    // model is process-cached in the C library after the first call).
    static let vadCheckIntervalSamples = 500 * sampleRate / 1000
    static let vadThreshold: Float = 0.7
    static let vadMinSpeechMS = 160
    /// Kept below `endpointSamples` — see the comment there.
    static let vadMinSilenceMS = 800
    static let vadPadMS = 30
    /// Don't discard a short speechless buffer on a single VAD pass — onsets
    /// can be missed on very short windows; wait until the buffer is at
    /// least this long before trusting a zero-span verdict.
    static let vadMinDiscardSamples = 2 * sampleRate

    /// Backend name used when `crispasr_detect_backend_from_gguf` can't name
    /// one (runtime without the symbol, unparsable GGUF): the model family
    /// guessed from the GGUF's file name — both shipped GGUFs are named
    /// after their architecture (`funasr-nano-2512-q8_0.gguf`,
    /// `sensevoice-small-q8_0.gguf`), so the guess follows the same naming
    /// the detector would resolve.
    static func fallbackBackend(modelPath: String) -> String {
        let name = URL(fileURLWithPath: modelPath).lastPathComponent.lowercased()
        return name.contains("funasr") ? "funasr" : "sensevoice"
    }

    /// FunASR-family models tag non-speech audio in their decode output
    /// (`<sil>`, `/sil`, …, optionally pipe-wrapped). Stripped before the
    /// empty-text gates in `runDecode` so a silence-only decode emits no
    /// event instead of a tag literal.
    ///
    /// `nonisolated(unsafe)`: the SDK does not mark `Regex` `Sendable`, but it
    /// is a value type with `let` internals, safe to share across threads.
    nonisolated(unsafe) static let nonSpeechTag =
        #/(?:<\|?|</|/)(?:sil|noise|music|bar|unk|laugh|breath)\|?>?/#.ignoresCase()

    /// Removes non-speech tags from a decode result, collapses whitespace,
    /// and joins the ASR's space-separated CJK tokens; "" when nothing spoken
    /// remains.
    static func sanitizeDecodeText(_ raw: String) -> String {
        droppingInterCJKWhitespace(
            raw
                .replacing(nonSpeechTag, with: " ")
                .replacing(#/\s+/#, with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// Kana, kanji, and CJK punctuation — surfaces that never take an
    /// inter-word space in Japanese.
    static func isCJKSurface(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3001 ... 0x303F, // 、。「々〆…
             0x3041 ... 0x309F, // hiragana
             0x30A1 ... 0x30FF, // katakana incl. ー
             0x3400 ... 0x4DBF, 0x4E00 ... 0x9FFF: // kanji
            true
        default:
            false
        }
    }

    /// Removes whitespace runs whose neighbors on both sides are CJK
    /// surfaces. The models emit space-separated CJK tokens, and the gaps
    /// fragment words at dictionary stem boundaries (思 って) so the reading
    /// annotator loses whole fragments; spaces touching Latin or digits stay
    /// ("600 回" keeps its gap — numeral fusion already tolerates it).
    static func droppingInterCJKWhitespace(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        var result = String.UnicodeScalarView()
        var i = 0
        while i < scalars.count {
            let scalar = scalars[i]
            if scalar.properties.isWhitespace, i > 0, isCJKSurface(scalars[i - 1]) {
                var j = i
                while j < scalars.count, scalars[j].properties.isWhitespace {
                    j += 1
                }
                if j < scalars.count, isCJKSurface(scalars[j]) {
                    i = j
                    continue
                }
            }
            result.append(scalar)
            i += 1
        }
        return String(result)
    }

    /// `library` is injectable so tests can drive the full state machine over
    /// a scripted fake without dlopen; nil (the default) binds the real dylib.
    init(
        modelPath: URL,
        languageCode: String = "ja",
        library: (any CrispASRLibraryAPI)? = nil
    ) throws {
        self.modelPath = modelPath.path
        self.languageCode = languageCode
        lib = try library ?? CrispASRLibrary.open()
        let vadModelPath = lib.vadModelPath
        vadUnavailableReason = if vadModelPath == nil {
            "VAD unavailable (missing firered-vad.gguf or libcrispasr VAD symbols) — " +
                "finalization falls back to the \(Self.utteranceCapSamples / Self.sampleRate)s cap"
        } else {
            nil
        }
        state = Mutex(State(vadModelPath: vadModelPath))
    }

    // MARK: - State

    /// All mutable engine state, guarded by `state`: jobs mutate it on the
    /// decode/VAD queues, pushes on the audio thread, `finish`/`close` on
    /// their callers. Every access runs inside a `state.withLock` scope;
    /// helpers that need the locked state take it as an explicit `inout`
    /// parameter and must only be called from such a scope.
    ///
    /// `@unchecked` only for the C session handle: `OpaquePointer` is an
    /// opaque token the compiler can't see as safe to copy across threads —
    /// the mutex is what serializes every mutation.
    struct State: @unchecked Sendable {
        var session: OpaquePointer?
        var totalSamples = 0
        var window: [Float] = [] // last `lengthSamples` samples
        var utterance: [Float] = [] // PCM since the last final
        var utteranceStartSample = 0
        /// Bumped on every final/discard so stale VAD results (snapshot taken
        /// before the reset) can be ignored.
        var utteranceGeneration = 0
        var lastDecodeDispatchSample = 0
        /// `vadLastSpeechEndSample` at the time the last partial was dispatched.
        /// Partials only re-decode when the VAD has confirmed speech beyond this,
        /// so a pause doesn't chain identical window redecodes (which would both
        /// freeze the HUD draft and starve the VAD on the serial decode queue).
        var lastPartialSpeechEndSample = 0
        var processedCount = 0
        var decodeInFlight = false
        var vadInFlight = false
        var finishing = false
        var inbox: [ASREvent] = []
        var consecutiveDecodeFailures = 0

        /// VAD state.
        var vadModelPath: String?
        /// Flipped off at runtime on VAD failure → degraded mode for the session.
        var vadEnabled = true
        var consecutiveVADFailures = 0
        var lastVADDispatchSample = 0
        /// True once the VAD has found a speech span in the current utterance.
        var utteranceHasSpeech = false
        /// RMS backstop: any chunk since the last final/discard was not silent.
        var utteranceHasLoudAudio = false
        /// Absolute sample of the end of the last VAD speech span (nil = none yet).
        var vadLastSpeechEndSample: Int?
        /// Absolute sample through which VAD results are valid for the current
        /// utterance (0 = nothing analyzed). Endpointing only trusts a span end
        /// once analysis has progressed past it.
        var vadAnalyzedThroughSample = 0
        /// Absolute sample of the start of the first speech span in the utterance.
        var vadFirstSpeechStartSample: Int?
        /// Set once in `prepare` when the VAD can't be used; reported once.
        var vadUnavailableReported = false

        /// True when the VAD is actually in the loop (symbols bound, model
        /// present, not runtime-disabled). Everything else is degraded mode.
        var vadActive: Bool {
            vadEnabled && vadModelPath != nil
        }
    }

    /// All shared mutable state; `withLock` scopes are the only access.
    let state: Mutex<State>
    /// Serializes `prepare` (and `close`) so a background warm-up and a
    /// session start can never both open a C session (the second opener
    /// would leak the first). Held across the multi-second session open.
    let prepareMutex = Mutex<Void>(())
    let decodeQueue = DispatchQueue(label: "mimidasu.asr.decode", qos: .userInitiated)
    let vadQueue = DispatchQueue(label: "mimidasu.asr.vad", qos: .userInitiated)
    /// Signaled after every decode or VAD completion so `finish` can wait
    /// out in-flight work. Never waited on by the job paths themselves.
    let jobFinished = DispatchSemaphore(value: 0)

    /// Set in init when the VAD can't be used; reported once in `prepare`.
    private let vadUnavailableReason: String?

    var processedSamples: Int {
        state.withLock { current in current.processedCount }
    }

    var pushedSamples: Int {
        state.withLock { current in current.totalSamples }
    }

    // MARK: - ASREngine

    func prepare() throws(ASREngineError) {
        guard FileManager.default.fileExists(atPath: modelPath) else {
            throw ASREngineError.modelNotFound(modelPath)
        }
        // `Mutex.withLock` rethrows untyped, so the typed failure comes out
        // of the scope as a value and is thrown at its edge.
        let failure: ASREngineError? = prepareMutex.withLock { _ in
            // Warm restart: the C session from a previous run is still open —
            // reuse it and skip the multi-second GGUF load + Metal compile.
            let alreadyOpen = state.withLock { current in current.session != nil }
            if alreadyOpen {
                #if DEBUG
                    print("[asr] prepare: reusing warm session (model already loaded)")
                #endif
                return nil
            }
            // TLS-backed GPU preference: must be set on the same thread that
            // opens the session (prepare runs once, before any decode starts).
            let backend = lib.detectBackend(modelPath: modelPath) ?? Self.fallbackBackend(modelPath: modelPath)
            #if DEBUG
                print("[asr] prepare: opening C session (\(backend)/metal)")
            #endif
            lib.setGpuBackend("metal")
            guard let handle = lib.openSession(modelPath: modelPath, backend: backend) else {
                return ASREngineError.createFailed(
                    "crispasr_session_open_explicit failed (backend \(backend))"
                )
            }
            // Publish the handle under the state mutex: `close()` nils it
            // there, and finish/runDecode snapshot it there.
            state.withLock { current in current.session = handle }
            return nil
        }
        if let failure {
            throw failure
        }
        if let reason = vadUnavailableReason {
            let shouldReport = state.withLock { current -> Bool in
                guard !current.vadUnavailableReported else { return false }
                current.vadUnavailableReported = true
                return true
            }
            if shouldReport {
                #if DEBUG
                    print("[asr] \(reason)")
                #endif
                onEngineError?(reason)
            }
        }
    }

    func openStream() throws(ASREngineError) {
        state.withLock { current in
            current.totalSamples = 0
            current.window = []
            current.utterance = []
            current.utteranceStartSample = 0
            current.utteranceGeneration += 1
            current.lastDecodeDispatchSample = 0
            current.lastPartialSpeechEndSample = 0
            current.processedCount = 0
            current.decodeInFlight = false
            current.vadInFlight = false
            current.finishing = false
            current.inbox = []
            current.lastVADDispatchSample = 0
            current.utteranceHasSpeech = false
            current.utteranceHasLoudAudio = false
            current.vadLastSpeechEndSample = nil
            current.vadAnalyzedThroughSample = 0
            current.vadFirstSpeechStartSample = nil
            current.consecutiveDecodeFailures = 0
            current.consecutiveVADFailures = 0
            current.vadEnabled = true
        }
    }

    func push(_ samples: [Float]) {
        state.withLock { current in
            guard current.session != nil, !current.finishing else { return }
            current.window.append(contentsOf: samples)
            if current.window.count > Self.lengthSamples {
                current.window.removeFirst(current.window.count - Self.lengthSamples)
            }
            current.totalSamples += samples.count

            // Every chunk feeds the utterance (bounded by the forced-final cap);
            // speech vs. silence is the VAD's call, not an energy threshold's.
            if current.utterance.isEmpty {
                current.utteranceStartSample = current.totalSamples - samples.count
            }
            current.utterance.append(contentsOf: samples)

            // RMS backstop: track whether this buffer is not truly silent.
            if AudioLevels.rms(of: samples) > Self.speechRMS {
                current.utteranceHasLoudAudio = true
            }

            maybeScheduleWork(&current)
        }
    }
}
