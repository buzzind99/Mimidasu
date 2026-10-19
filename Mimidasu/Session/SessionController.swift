import Foundation
import Synchronization

/// Owns the mechanics of a live capture → ASR session: engine lifecycle and
/// warm-up scheduling, system-audio capture wiring, sentence buffering, and
/// the poll/tick timers. Published UI state, translation configuration, and
/// export delegation stay in `AppModel`, which plugs in via the callbacks.
@MainActor
final class SessionController {
    /// Upper bound for the translation-tail drain in `stop()` — the instance
    /// default; tests whose queue no worker will ever consume inject a shorter
    /// `translationDrainTimeout`. Also part of the quit-time watchdog budget
    /// in `AppDelegate`.
    static let translationDrainTimeout: TimeInterval = 5

    /// Grace window after capture start before the no-audio warning fires:
    /// the tap needs a beat to spin up, and a couple of seconds of silence is
    /// otherwise indistinguishable from denied system-audio permission.
    static let noAudioWarningDelay: Duration = .seconds(8)

    private let live: LivePartialState
    private let latency: LatencyState
    private let audioLevel: AudioLevelState
    /// Chunk RMS staged off-main by `handleCaptureChunk`, drained onto
    /// `audioLevel` by the 60 ms poll tick (see `MeterHandoff`).
    private let meterHandoff = MeterHandoff()
    /// Sticky audio-presence latch fed by the same chunks; read by the
    /// no-audio watchdog and the one-shot `onAudioDetected` (see
    /// `AudioPresenceHandoff`).
    private let audioPresence = AudioPresenceHandoff()
    private let translationQueue: TranslationQueue
    private let makeEngine: @Sendable (URL?, Bool) -> ASREngine?
    private let makeCapture: () -> any AudioCapturing
    private let warmUpEnabled: () -> Bool

    /// A session is about to run: clear transcript state.
    var onSessionBegin: (() -> Void)?
    /// The engine was created for a new session.
    var onEngineChosen: ((_ isMock: Bool, _ modelURL: URL?) -> Void)?
    /// A sentence left the buffer (append to transcript + enqueue translation).
    var onSentence: ((Sentence) -> Void)?
    /// The engine surfaced an internal error.
    var onEngineError: ((String) -> Void)?
    /// The capture stream died mid-session.
    var onCaptureError: ((String) -> Void)?
    /// A fresh capture delivered no chunk above the silence floor within
    /// `silenceGracePeriod` — the denied-permission / muted-source case.
    var onNoAudioDetected: (() -> Void)?
    /// The first chunk above the silence floor arrived; lets the UI retire a
    /// posted no-audio warning once capture starts working.
    var onAudioDetected: (() -> Void)?

    /// Metadata captured at the start of the most recent session (export).
    private(set) var sessionMetadata: SessionMetadata?

    private var engine: ASREngine?
    private var capture: (any AudioCapturing)?
    private var sentenceBuffer: SentenceBuffer?
    private var pollTimer: Timer?
    private var tickTimer: Timer?
    /// One-shot silence watchdog for the current capture; cancelled on stop
    /// and re-armed by every `startCapture`.
    private var noAudioWatchdog: Task<Void, Never>?
    /// Serializes the engine's flush/finish calls for this session and owns
    /// the exactly-once pause-flush handoff (see `SessionEngineChannel`).
    private let engineChannel = SessionEngineChannel()
    /// Serial tail of the capture transitions: `pause()`, `resume()`,
    /// `restartCapture()`, and `stop()` enqueue behind it, so their capture
    /// and engine calls run strictly in request order.
    var transitionTail: Task<Void, Never>?
    /// The task returned by the most recent `pause()` enqueue; the deferred
    /// resume reads it through `awaitPauseCompletion()`.
    var pauseCompletedTask: Task<Void, Never>?
    /// Latched synchronously by `stop()` before its first suspension: an
    /// airborne pause/resume/restart observes it after every await and sheds
    /// the work the stop now owns.
    var stopRequested = false
    /// One-shot guard: the queued teardown runs at most once per session.
    var hasStopped = false
    private let silenceGracePeriod: Duration
    /// Bound for `stop()`'s translation-tail drain; `Self.translationDrainTimeout`
    /// unless a test injects a shorter one.
    private let translationDrainTimeout: TimeInterval
    /// Path of the model the warm-up last loaded (nil = none yet). Keyed on
    /// path so the warm-up re-arms when the user switches models: the new
    /// GGUF gets prepared in the background instead of loading synchronously
    /// inside the first `begin` after the switch. Repeat calls with the same
    /// path are no-ops.
    private var warmedModelPath: String?
    #if DEBUG
        private var debugIngressChunks = 0
    #endif

    /// Injection seams for tests: engine and capture default to the real
    /// implementations; tests inject doubles so `begin()` and the event
    /// paths run without the audio HAL or the native runtime.
    /// `makeEngine` receives `allowMock` (true from `begin`, false from the
    /// warm-up, which must never fall back to the mock). `warmUpEnabled`
    /// defaults to off inside a unit-test host: that app runs the real launch
    /// path during `xcodebuild test`, and its detached warm-up would construct
    /// a real engine that races the suites' own engine constructions into a
    /// permanent ggml-metal init wedge. Warm-up tests opt back in explicitly.
    init(
        live: LivePartialState,
        latency: LatencyState,
        audioLevel: AudioLevelState = AudioLevelState(),
        translationQueue: TranslationQueue,
        makeEngine: @escaping @Sendable (URL?, Bool) -> ASREngine? = { modelURL, allowMock in
            ASREngineFactory.makeEngine(modelURL: modelURL, allowMock: allowMock)
        },
        makeCapture: @escaping () -> any AudioCapturing = { SystemAudioCapture() },
        warmUpEnabled: @escaping () -> Bool = {
            ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
        },
        silenceGracePeriod: Duration = SessionController.noAudioWarningDelay,
        translationDrainTimeout: TimeInterval = SessionController.translationDrainTimeout
    ) {
        self.live = live
        self.latency = latency
        self.audioLevel = audioLevel
        self.translationQueue = translationQueue
        self.makeEngine = makeEngine
        self.makeCapture = makeCapture
        self.warmUpEnabled = warmUpEnabled
        self.silenceGracePeriod = silenceGracePeriod
        self.translationDrainTimeout = translationDrainTimeout
    }

    // MARK: - Warm-up

    /// Loads the ASR model + compiles the Metal pipelines in the background
    /// (at app launch, when a model becomes available, or after a model
    /// switch) so the first session start is instant. Safe against racing
    /// `begin`: the engine's `prepare` is serialized, and a second opener
    /// reuses the already-open session.
    func warmUpIfNeeded(modelURL: URL?) {
        guard warmUpEnabled(), let url = modelURL, warmedModelPath != url.path else { return }
        warmedModelPath = url.path
        #if DEBUG
            print("[warmup] preparing ASR engine in background")
        #endif
        let makeEngine = makeEngine
        Task.detached(priority: .utility) {
            if let engine = makeEngine(url, false) {
                try? engine.prepare()
            }
        }
    }

    // MARK: - Session control

    /// Brings up engine → capture → buffer. Returns `false` when no model is
    /// available (caller maps that to `.needsModel`); throws when capture setup
    /// fails. `modelURL` comes from the caller's
    /// resolved state (single resolve, no second verify on the start path);
    /// `modelID` is the active choice's id for session metadata; `targetLang`
    /// is the selected translation target's BCP-47 code for session metadata.
    func begin(modelURL: URL?, modelID: String, targetLang: String = "en") async throws -> Bool {
        // A new session starts only after any in-flight transition settled: a
        // stop still tearing down must not interleave with this start.
        await transitionTail?.value
        stopRequested = false
        hasStopped = false
        pauseCompletedTask = nil
        // A new session starts the engine channel clean (a capture object is
        // never restarted after `stop()`, but the controller is).
        engineChannel.reset()
        // No TCC preflight: the tap needs no Microphone permission — the
        // system prompts for audio-capture access at the aggregate's first
        // IO (driven by NSAudioCaptureUsageDescription). That first IO is the
        // capture's `AudioDeviceStart`, which TCC blocks until the user
        // answers (verified on device); an unpermitted start therefore throws
        // from `startCapture` below instead of running silent.
        guard let engine = makeEngine(modelURL, true) else {
            return false
        }
        self.engine = engine
        onEngineChosen?(engine.isMock, modelURL)
        engine.onEngineError = { [weak self] message in
            Task { @MainActor in self?.onEngineError?(message) }
        }

        onSessionBegin?()
        live.partial = ""
        latency.reset()
        audioLevel.reset()
        clearAudioStaging()

        let buffer = SentenceBuffer()
        buffer.onSentence = { [weak self] sentence in
            self?.onSentence?(sentence)
        }
        sentenceBuffer = buffer

        try await startCapture(for: engine)

        // `prepare` may wait out a multi-second GGUF load + Metal compile
        // (when the background warm-up hasn't finished) — keep it off the
        // main actor. `prepareLock` still serializes it against the warm-up.
        try await Task.detached(priority: .userInitiated) { try engine.prepare() }.value
        try engine.openStream()
        engineChannel.started()

        sessionMetadata = SessionMetadata(
            startedAt: Date(),
            sourceLang: "ja",
            targetLang: targetLang,
            model: engine.isMock ? "mock" : modelID,
            chunkMS: 160
        )

        return true
    }

    /// Builds, wires, and starts a new capture stream for `engine`. Shared
    /// by `begin()` and `restartCapture()`. The engine is captured strongly:
    /// a session owns exactly one engine, and chunks must not read
    /// main-actor state from the capture IO queue. `capture.stop()` fences
    /// chunks after teardown.
    private func startCapture(for engine: ASREngine) async throws {
        let capture = makeCapture()
        capture.onChunk = { [weak self] chunk in
            guard let self else { return }
            handleCaptureChunk(chunk, engine: engine)
        }
        capture.onIOError = { [weak self] error in
            Task { @MainActor in self?.onCaptureError?(error.localizedDescription) }
        }
        self.capture = capture

        // Reset the presence tracker for this stream before `start()`: IO
        // callbacks can land the instant the device starts, and a chunk that
        // beat the reset would be lost. A watchdog left over from a previous
        // capture (restart path) is cancelled here instead of relying on the
        // owner to re-arm it; the owner arms a fresh one once the phase is
        // actually `.running`.
        disarmNoAudioWatchdog()
        clearAudioStaging()

        #if DEBUG
            print("[session] start: whole-system process-tap audio capture")
        #endif
        try await capture.start()
    }

    /// Starts the one-shot silence watchdog: after the grace window it fires
    /// `onNoAudioDetected` unless a chunk above the silence floor has already
    /// been staged. The owner calls this when the phase flips to `.running`,
    /// not at capture start — a first-launch TCC prompt keeps the session in
    /// `.starting`, and counting that wait as silence would warn before the
    /// user can even grant access. TCC blocks the aggregate's first IO
    /// (`AudioDeviceStart`) while the prompt is up (verified on device), so
    /// the IO proc delivers no callbacks and stages no silence before the
    /// `.running` arm point; silence observed after it is genuine. A prior
    /// watchdog is cancelled first, so a restart re-arms cleanly.
    func armNoAudioWatchdog() {
        noAudioWatchdog?.cancel()
        noAudioWatchdog = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: silenceGracePeriod)
            guard !Task.isCancelled, !audioPresence.hasHeardAudio() else { return }
            onNoAudioDetected?()
        }
    }

    private func disarmNoAudioWatchdog() {
        noAudioWatchdog?.cancel()
        noAudioWatchdog = nil
    }

    /// Clears the staged meter level and the presence latch: a capture built
    /// or torn down must not leak a stale level or latch into the next stream.
    private func clearAudioStaging() {
        meterHandoff.clear()
        audioPresence.clear()
    }

    /// The queued body of `restartCapture()`: rebuilds the capture stream
    /// mid-session after the source died — the `capture.lost` toast's Restart
    /// action. The engine, timers, sentence buffer, and translation queue are
    /// untouched: no model reload, and `onSessionBegin` does not re-fire.
    /// Timestamp continuity is free — sentence timestamps derive from the
    /// engine's sample counters, not the capture's. A no-op without a live
    /// engine (the session is already down) or once a stop owns the teardown.
    func performRestartCapture() async throws {
        guard !stopRequested else { return }
        guard let engine else { return }
        // Defensive: fence any chunks still arriving from the dead stream.
        capture?.stop()
        try await startCapture(for: engine)
        // A stop that arrived during the rebuilt start owns the teardown: it
        // runs next in the queue and fences this freshly built capture.
        guard !stopRequested else { return }
        engineChannel.markLive()
    }

    /// The queued body of `pause()`: suspends the live session without
    /// ending it — the capture stops at the IOProc (no callbacks while
    /// paused), the in-flight utterance is flushed through the engine so
    /// speech spoken just before pausing still lands as a sentence, and the
    /// live surfaces clear. Timers keep running so the flush final and the
    /// buffer tick close what the flush emits. The translation queue is
    /// deliberately left alone — enqueued sentences finish normally.
    func performPause() async {
        guard !stopRequested else { return }
        await capture?.pause()
        // A stop that raced the capture pause owns the teardown: no flush
        // starts here; the queued stop's `finish` performs the final flush.
        guard !stopRequested else { return }
        guard let engine else { return }
        disarmNoAudioWatchdog()
        // The flush decode is a multi-second C call whenever speech is in
        // flight — the channel keeps it off the main actor (mirrors
        // `stop`'s drain) and reports the flush superseded when a stop
        // claimed the engine first, so no decode ever overlaps `finish()`.
        let outcome = await engineChannel.pauseFlush(engine: engine)
        guard case let .delivered(flushed) = outcome else { return }
        for event in flushed {
            handleASREvent(event)
        }
        sentenceBuffer?.flush()
        live.partial = ""
        latency.reset()
        audioLevel.reset()
        clearAudioStaging()
    }

    /// The queued body of `resume()`: restarts the IOProc stopped by
    /// `pause()`, arms a fresh no-audio watchdog grace window, and resets the
    /// presence latch so that grace restarts genuinely instead of counting
    /// the pre-pause silence. Throws when the rig is gone or the HAL refuses
    /// the restart — the owner then falls back to the capture-lost rebuild
    /// flow. A stop that arrived while the HAL start was airborne owns the
    /// teardown: no watchdog and no channel reopening run afterwards.
    func performResume() async throws {
        guard !stopRequested else { return }
        guard let capture else { return }
        try await capture.resume()
        guard !stopRequested else { return }
        engineChannel.markLive()
        armNoAudioWatchdog()
        clearAudioStaging()
    }

    /// Synchronous engine-channel latch for `stop()`: the queue entry point
    /// runs it before enqueueing, so an airborne transition observes the stop
    /// without waiting for the queued teardown.
    func requestEngineStop() {
        engineChannel.requestStop()
    }

    /// The queued body of `stop()`: one-shot teardown, ordered so pending
    /// translations finish first — capture and ASR are shut down immediately,
    /// the final flushed sentence is enqueued, and only after the translation
    /// queue drains (bounded by a timeout) does the session wind down. That
    /// keeps the tail of the session exportable with translations intact.
    /// The channel hands over any airborne pause flush, so a pause waking
    /// inside its own await skips its delivery and the flush lands once.
    ///
    /// The engine stays warm: the loaded model is reused by the next session.
    func performStop() async {
        guard !hasStopped else { return }
        hasStopped = true
        // Strictly ordered teardown: capture stops first (synchronous fence),
        // then the channel flushes out any airborne pause and runs the ASR
        // finish → drain off-main — a bounded drain wait plus a synchronous
        // flush decode, a multi-second C call whenever speech is in flight
        // at Stop.
        capture?.stop()
        disarmNoAudioWatchdog()
        if let engine {
            let drained = await engineChannel.finish(engine: engine)
            for event in drained {
                handleASREvent(event)
            }
        }
        engine = nil
        capture = nil
        stopTimers()

        // Flush a partially-formed sentence (its translation is awaited
        // below), then let the translation worker finish its tail.
        sentenceBuffer?.flush()
        sentenceBuffer = nil
        _ = await translationQueue.drain(timeout: translationDrainTimeout)
        live.partial = ""
        audioLevel.reset()
        clearAudioStaging()
    }

    // MARK: - Capture (ASR queue)

    private func handleCaptureChunk(_ chunk: AudioChunk, engine: ASREngine) {
        engine.push(chunk.samples)
        // Stage the per-chunk level for the sidebar AUDIO meter: this runs on
        // the capture IO queue, so `AudioLevelState` (main-actor observable)
        // is fed by the poll tick instead of from here — same RMS metric the
        // debug ingress log samples every ~8 s.
        let rms = AudioLevels.rms(of: chunk.samples)
        meterHandoff.stage(rms)
        audioPresence.observe(rms)
        #if DEBUG
            logIngressEnergy(chunk)
        #endif
    }

    #if DEBUG
        /// Every ~8 s of audio, print ASR-ingress energy so a dead pipeline
        /// (all-zero audio reaching the model) is obvious.
        private func logIngressEnergy(_ chunk: AudioChunk) {
            debugIngressChunks += 1
            guard debugIngressChunks % 50 == 0 else { return }
            let rms = AudioLevels.rms(of: chunk.samples)
            print(
                "[capture] chunk #\(debugIngressChunks) rms=\(String(format: "%.6f", rms)) " +
                    "t=\(SessionClock.timestamp(SessionClock.seconds(chunk.startSample)))"
            )
        }
    #endif

    // MARK: - Timers

    func startTimers() {
        pollTimer?.invalidate()
        pollTimer = makeCommonModeTimer(interval: 0.06) { [weak self] in
            self?.pollASR()
        }
        tickTimer?.invalidate()
        tickTimer = makeCommonModeTimer(interval: 0.2) { [weak self] in
            self?.sentenceBuffer?.tick()
        }
    }

    /// Timers must fire while a mouse press/drag tracks (`eventTracking`
    /// run-loop mode), or the live UI freezes on hold; `.common` covers
    /// default + tracking + modal modes.
    private func makeCommonModeTimer(
        interval: TimeInterval, onMainActor body: @escaping @MainActor () -> Void
    ) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: true) { _ in
            Task { @MainActor in body() }
        }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    private func stopTimers() {
        pollTimer?.invalidate(); pollTimer = nil
        tickTimer?.invalidate(); tickTimer = nil
    }

    private func pollASR() {
        guard let engine else { return }
        while let event = engine.poll() {
            handleASREvent(event)
        }
        // Latency and the audio meter ride the existing 60 ms tick (no
        // per-chunk Task hop): the 0.1 s rounding gate in `LatencyState`
        // keeps latency publishes visible-only, and the meter only needs
        // the latest staged RMS.
        latency.update(
            max(0, Double(engine.pushedSamples - engine.processedSamples) / SessionClock.sampleRate)
        )
        if let rms = meterHandoff.take() {
            audioLevel.update(rms: rms)
        }
        if audioPresence.consumeFirstAudible() {
            onAudioDetected?()
        }
    }

    // MARK: - Event handling (main actor)

    private func handleASREvent(_ event: ASREvent) {
        switch event {
        case let .partial(text):
            live.partial = text
        case let .final(text, startSample, endSample, lang):
            live.partial = ""
            _ = lang
            // Only Japanese-script finals become transcript sentences —
            // kana counts: the final re-decode often renders kanji words
            // as kana even when the partial showed kanji. Latin- or
            // symbol-only finals are dropped at the door.
            guard KanaClassification.containsJapanese(text) else {
                // A dropped final is still speech: keep the open sentence's
                // silence timer and end span honest without appending it.
                sentenceBuffer?.noteTrailing(endSample: endSample)
                return
            }
            sentenceBuffer?.append(
                finalText: text, startSample: startSample, endSample: endSample
            )
        }
    }
}

/// Single-slot handoff for the sidebar AUDIO meter: `handleCaptureChunk`
/// stages the chunk's RMS from the capture IO queue; the main-actor poll tick
/// drains the latest value into `AudioLevelState`. `Mutex`-guarded — the slot
/// only ever holds a `Float?`, so the critical sections stay sub-microsecond.
/// `take()` leaves the slot empty: with no new chunks (source lost), the poll
/// tick simply doesn't re-publish and the meter freezes at its last level
/// until `clear()`.
private final class MeterHandoff: Sendable {
    private let slot = Mutex<Float?>(nil)

    func stage(_ rms: Float) {
        slot.withLock { value in value = rms }
    }

    func take() -> Float? {
        slot.withLock { value -> Float? in
            let latest = value
            value = nil
            return latest
        }
    }

    func clear() {
        slot.withLock { value in value = nil }
    }
}

/// Sticky audio-presence latch fed by the same chunk RMS as `MeterHandoff`:
/// `heardAudio` latches once any chunk rises above
/// `AudioLevels.silenceFloorRMS` and only `clear()` resets it. The no-audio
/// watchdog reads it to tell a denied/muted capture (silent or no chunks)
/// from a live one. `consumeFirstAudible()` is the one-shot counterpart the
/// poll tick uses to surface `onAudioDetected` exactly once per capture.
private final class AudioPresenceHandoff: Sendable {
    private struct State {
        var heardAudio = false
        var notifiedAudible = false
    }

    private let slot = Mutex(State())

    func observe(_ rms: Float) {
        guard rms > AudioLevels.silenceFloorRMS else { return }
        slot.withLock { value in value.heardAudio = true }
    }

    /// Sticky: true once any observed chunk has carried signal above the floor.
    func hasHeardAudio() -> Bool {
        slot.withLock { value in value.heardAudio }
    }

    /// One-shot: true on the first call after an audible chunk, false
    /// thereafter (and until `clear()`).
    func consumeFirstAudible() -> Bool {
        slot.withLock { value -> Bool in
            guard value.heardAudio, !value.notifiedAudible else { return false }
            value.notifiedAudible = true
            return true
        }
    }

    func clear() {
        slot.withLock { value in value = State() }
    }
}
