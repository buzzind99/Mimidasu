import Foundation
@testable import Mimidasu
import Synchronization
import Testing

/// Tests `CrispASREngine`'s session lifecycle over the scripted fake
/// library (`CrispASRLibraryAPI` injection): push accounting, `prepare`'s
/// session handshake (detected/fallback backend, `.createFailed`, warm
/// reuse, init-time VAD degrade), `close`'s single session release, and
/// `finish()`'s in-flight drain + flush decode + drain. The state machine
/// itself lives in `CrispASREngineLibraryTests`.
///
/// Runs on every machine — no dlopen, no model, no Metal: the fake bypasses
/// the library seam and the vad/decode queues are per-engine instance state,
/// so the suite is NOT `.serialized`. Timelines converge through bounded
/// `pollUntilOffMain` polls on the fake's recorded calls and the engine's
/// mutex-guarded state, never bare sleeps.
@Suite("CrispASREngine (fake library, lifecycle)")
struct CrispASREngineLifecycleTests {

    // MARK: - Fixtures

    private let tmp: TemporaryDirectory

    init() throws {
        tmp = try TemporaryDirectory(prefix: "mimidasu-crisp-fake")
    }

    /// 1 s of loud PCM (RMS 0.1 ≫ speechRMS) — "speech" for the RMS backstop.
    private var loudSecond: [Float] {
        [Float](repeating: 0.1, count: CrispASREngine.sampleRate)
    }

    private var silentSecond: [Float] {
        [Float](repeating: 0, count: CrispASREngine.sampleRate)
    }

    // MARK: - Helpers

    private func makePreparedEngine(_ library: FakeCrispASRLibrary) throws -> CrispASREngine {
        let modelURL = try tmp.write(Data("gguf".utf8), named: "model.gguf")
        let engine = try CrispASREngine(modelPath: modelURL, library: library)
        try engine.prepare()
        try engine.openStream()
        return engine
    }

    /// Reads engine state under its mutex — jobs mutate it on their queues.
    private func state<T>(_ engine: CrispASREngine, _ read: (CrispASREngine.State) -> T) -> T {
        engine.state.withLock { current in read(current) }
    }

    private func requireFinal(_ event: ASREvent?, text: String, start: Int, end: Int) {
        guard case let .final(actualText, actualStart, actualEnd, actualLang) = event else {
            Issue.record("expected .final, got \(String(describing: event))")
            return
        }
        #expect(actualText == text)
        #expect(actualStart == start)
        #expect(actualEnd == end)
        #expect(actualLang == "ja")
    }

    // MARK: - Sample accounting

    @Test("pushedSamples tracks pushed audio before any decode")
    func pushedSamplesTrackPushedAudio() throws {
        let library = FakeCrispASRLibrary()
        let engine = try makePreparedEngine(library)

        engine.push(loudSecond)
        engine.push(silentSecond)

        #expect(engine.pushedSamples == 2 * CrispASREngine.sampleRate)
    }

    // MARK: - prepare / close (session lifecycle)

    @Test("prepare throws .createFailed when the C session cannot be opened")
    func prepareThrowsCreateFailedWhenSessionOpenFails() throws {
        let library = FakeCrispASRLibrary()
        library.openSessionResult = nil
        let modelURL = try tmp.write(Data("gguf".utf8), named: "model.gguf")
        let engine = try CrispASREngine(modelPath: modelURL, library: library)

        let thrown = #expect(throws: ASREngineError.self) {
            try engine.prepare()
        }
        let error = try #require(thrown)

        guard case let .createFailed(detail) = error else {
            Issue.record("expected .createFailed, got \(error)")
            return
        }
        #expect(detail.contains("backend sensevoice"), "the fallback backend names the failure")
        #expect(library.openSessionCount == 1)
    }

    @Test("init without a VAD model degrades at init and prepare reports it exactly once")
    func initWithoutVADModelDegradesAndReportsOnce() throws {
        let library = FakeCrispASRLibrary()
        library.vadModelPathValue = nil
        let modelURL = try tmp.write(Data("gguf".utf8), named: "model.gguf")
        let engine = try CrispASREngine(modelPath: modelURL, library: library)
        let errors = ErrorRecorder()
        engine.onEngineError = { message in errors.record(message) }

        try engine.prepare()
        try engine.prepare() // warm reuse — must not re-report

        #expect(
            errors.all == [
                "VAD unavailable (missing firered-vad.gguf or libcrispasr VAD symbols) — "
                    + "finalization falls back to the 12s cap"
            ]
        )
        #expect(state(engine) { current in current.vadActive } == false)
        #expect(library.openSessionCount == 1, "the second prepare reuses the warm session")
    }

    @Test("prepare reuses an already-open C session")
    func prepareReusesOpenSession() throws {
        let library = FakeCrispASRLibrary()
        let engine = try makePreparedEngine(library)

        try engine.prepare()

        #expect(library.openSessionCount == 1, "warm restart must not reopen the C session")
        #expect(library.gpuBackends == ["metal"], "GPU backend set once")
    }

    @Test("prepare drives the library handshake with the detected or fallback backend")
    func prepareDrivesHandshakeWithDetectedOrFallbackBackend() throws {
        let library = FakeCrispASRLibrary()
        let modelURL = try tmp.write(Data("gguf".utf8), named: "fallback.gguf")
        let fallbackEngine = try CrispASREngine(modelPath: modelURL, library: library)

        try fallbackEngine.prepare()

        #expect(library.gpuBackends == ["metal"], "GPU preference is set on the prepare thread")
        #expect(
            library.openSessionBackends == ["sensevoice"],
            "nil detection falls back to the name guessed from the file name"
        )

        library.detectBackendResult = "funasr"
        let detectedEngine = try CrispASREngine(modelPath: modelURL, library: library)
        try detectedEngine.prepare()

        #expect(
            library.openSessionBackends == ["sensevoice", "funasr"],
            "a detected backend is passed through to openSession"
        )
    }

    @Test("close releases an open C session exactly once and silences the stream")
    func closeReleasesSessionOnceAndSilencesStream() throws {
        let library = FakeCrispASRLibrary()
        let engine = try makePreparedEngine(library)

        engine.close()
        engine.close()

        #expect(library.closeSessionCount == 1, "the second close has no session to release")
        engine.push(loudSecond)
        #expect(engine.pushedSamples == 0, "push after close is ignored (finishing latched)")
    }

    // MARK: - finish()

    @Test("finish flush-decodes a speechful open utterance and drains the final")
    func finishFlushesSpeechfulUtterance() async throws {
        let library = FakeCrispASRLibrary()
        library.vadReplies = [.spans([(start: 0.0, end: 1.0)])]
        library.transcribeReplies = ["", "フラッシュ。"] // window partial, flush decode
        let engine = try makePreparedEngine(library)

        engine.push(loudSecond)
        #expect(await pollUntilOffMain { library.transcribeCalls.count == 1 }, "speech confirmed")

        let drained = engine.finish()

        #expect(drained.count == 1)
        requireFinal(drained.first, text: "フラッシュ。", start: 0, end: 16000)
        #expect(library.transcribeCalls.count == 2)
        let flush = library.transcribeCalls[1]
        #expect(flush.pcmCount == 2 * CrispASREngine.sampleRate)
        #expect(flush.pcm[16000...].allSatisfy { sample in sample == 0 }, "the flush pads the 1 s utterance")
        #expect(engine.poll() == nil, "finish drains the inbox")
    }

    @Test("finish skips the flush decode for a speechless utterance")
    func finishSkipsSpeechlessFlush() async throws {
        let library = FakeCrispASRLibrary()
        library.vadReplies = [.failure(-3)]
        let engine = try makePreparedEngine(library)
        let errors = ErrorRecorder()
        engine.onEngineError = { message in errors.record(message) }

        engine.push(silentSecond) // VAD #1 → degrade; utterance silent and short
        #expect(await pollUntilOffMain { !errors.all.isEmpty }, "the VAD degrade was reported")

        let drained = engine.finish()

        #expect(drained.isEmpty)
        #expect(
            library.transcribeCalls.isEmpty,
            "the RMS backstop must keep known-silent audio out of the flush decode"
        )
    }

    @Test("finish waits out an in-flight decode before flushing and draining")
    func finishWaitsOutInFlightDecode() async throws {
        let library = FakeCrispASRLibrary()
        library.vadReplies = [.failure(-3)] // degrade → deterministic cap finals
        library.transcribeReplies = ["キャップ。"]
        library.transcribeHoldSemaphore = DispatchSemaphore(value: 0)
        let engine = try makePreparedEngine(library)
        engine.drainTimeout = 5

        engine.push([Float](repeating: 0.1, count: 12 * CrispASREngine.sampleRate)) // loud cap decode
        #expect(await pollUntilOffMain { library.transcribeEntered }, "the cap decode entered the fake and is held")

        let task = Task.detached { engine.finish() }
        #expect(
            await pollUntilOffMain { state(engine) { current in current.finishing } },
            "finish entered the drain while the decode is in flight"
        )

        library.transcribeHoldSemaphore?.signal()
        library.transcribeHoldSemaphore = nil // an unexpected flush decode must not hang the suite
        let drained = await task.value
        #expect(
            drained.contains { event in
                if case .final = event {
                    true
                } else {
                    false
                }
            },
            "the held final survives the drain"
        )
        #expect(engine.poll() == nil, "finish drains the inbox")
    }

    @Test("finish's flush decode is trimmed but not tag-sanitized")
    func finishFlushDecodeIsTrimmedNotSanitized() async throws {
        let library = FakeCrispASRLibrary()
        library.vadReplies = [.spans([(start: 0.0, end: 1.0)])]
        library.transcribeReplies = ["", "  <sil>  "] // window partial, flush decode = whitespace + tag only
        let engine = try makePreparedEngine(library)

        engine.push(loudSecond)
        #expect(await pollUntilOffMain { library.transcribeCalls.count == 1 }, "speech confirmed")

        let drained = engine.finish()

        #expect(
            drained.count == 1,
            "documents the current trim-only flush behavior — the endpoint path would emit nothing"
        )
        requireFinal(drained.first, text: "<sil>", start: 0, end: 16000)
    }

    // MARK: - Drained teardown (in-flight job vs. free)

    @Test("close frees the session once the in-flight decode drains within the grace")
    func closeFreesAfterInFlightDecodeDrains() async throws {
        let library = FakeCrispASRLibrary()
        library.vadReplies = [.failure(-3)] // degrade → deterministic cap finals
        library.transcribeReplies = ["キャップ。"]
        library.transcribeHoldSemaphore = DispatchSemaphore(value: 0)
        let engine = try makePreparedEngine(library)

        engine.push([Float](repeating: 0.1, count: 12 * CrispASREngine.sampleRate)) // loud cap decode
        // `#require`, not `#expect`: a failed entry poll must abort the
        // test — continuing would drain a trivially idle engine and pass
        // vacuously.
        try #require(
            await pollUntilOffMain { library.transcribeEntered },
            "the cap decode entered the fake and is held"
        )
        defer {
            library.transcribeHoldSemaphore?.signal()
            library.transcribeHoldSemaphore = nil
        }

        let task = Task.detached { engine.close() }
        library.transcribeHoldSemaphore?.signal()
        library.transcribeHoldSemaphore = nil // an unexpected second decode must not hang the suite
        let closed = await task.value

        #expect(closed, "the decode finished within the grace, so the session was freed")
        #expect(library.closeSessionCount == 1)
        #expect(
            !library.freedUnderTranscribe,
            "the free must follow the drained decode, never overlap it"
        )
    }

    @Test("close leaks the session instead of freeing under a decode that outlives the grace")
    func closeLeaksWhenDecodeOutlivesGrace() async throws {
        let library = FakeCrispASRLibrary()
        library.vadReplies = [.failure(-3)] // degrade → deterministic cap finals
        library.transcribeReplies = ["キャップ。"]
        library.transcribeHoldSemaphore = DispatchSemaphore(value: 0)
        let engine = try makePreparedEngine(library)
        engine.closeDrainTimeout = 0.05

        engine.push([Float](repeating: 0.1, count: 12 * CrispASREngine.sampleRate)) // loud cap decode
        #expect(await pollUntilOffMain { library.transcribeEntered }, "the cap decode entered the fake and is held")
        let samplesBeforeClose = engine.pushedSamples
        defer {
            library.transcribeHoldSemaphore?.signal()
            library.transcribeHoldSemaphore = nil
        }

        let closed = await Task.detached { engine.close() }.value

        #expect(!closed, "close reports the leak; the caller must skip further runtime teardown")
        #expect(library.closeSessionCount == 0, "the session must never be freed under the in-flight decode")
        #expect(!library.freedUnderTranscribe)
        #expect(state(engine) { current in current.finishing }, "close latched finishing, not just the nilled session")
        engine.push(loudSecond)
        #expect(
            engine.pushedSamples == samplesBeforeClose,
            "push after close stays ignored (finishing latched before the drain)"
        )
    }

    @Test("finish skips the flush decode when a decode outlives the drain")
    func finishSkipsFlushWhenDrainExpires() async throws {
        let library = FakeCrispASRLibrary()
        library.vadReplies = [.spans([(start: 0.0, end: 1.0)])] // speechful utterance → the flush would decode
        library.transcribeReplies = [""]
        library.transcribeHoldSemaphore = DispatchSemaphore(value: 0)
        let engine = try makePreparedEngine(library)
        engine.drainTimeout = 0.05

        engine.push(loudSecond) // window partial decode (held)
        #expect(await pollUntilOffMain { library.transcribeEntered }, "the window decode entered the fake and is held")
        defer {
            library.transcribeHoldSemaphore?.signal()
            library.transcribeHoldSemaphore = nil
        }

        // Nil until finish() returns: a (buggy) flush decode would park on
        // the still-held semaphore and finish() would never return — the
        // bounded poll turns that regression into a failure instead of a
        // hung suite.
        let outcome = Mutex<[ASREvent]?>(nil)
        Task.detached {
            outcome.withLock { slot in slot = engine.finish() }
        }
        let finished = await pollUntilOffMain { outcome.withLock { events in events != nil } }
        #expect(finished, "finish returned while the decode is still held — the flush decode must not run")
        if finished {
            let drained = outcome.withLock { events in events }
            #expect(drained?.isEmpty == true, "the held job produced nothing the inbox could drain")
        }

        // The fake records a transcribe call only after its hold releases,
        // so once the in-flight decode lands the count must be exactly one;
        // a flush decode that snuck through would land as call two.
        library.transcribeHoldSemaphore?.signal()
        library.transcribeHoldSemaphore = nil
        #expect(await pollUntilOffMain { library.transcribeCalls.count == 1 }, "the in-flight partial decode landed")
        #expect(
            library.transcribeCalls.count == 1,
            "the flush decode must not run on a session a live job still owns"
        )
    }
}
