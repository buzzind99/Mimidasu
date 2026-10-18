import Foundation
@testable import Mimidasu
import Synchronization
import Testing

/// Tests the bulk archive-translation job: scope computation, ordered
/// one-sentence-at-a-time landing, progress and finish events, failure
/// accounting, the cooperative cancel (partial results stay, a fill-missing
/// re-run resumes), the one-job-at-a-time claim, and the engine-resolution
/// outcomes. The engine resolver, landing sink, and event hook are injected,
/// so the suite drives the job against a scripted engine double and
/// deterministic gates.
@MainActor
@Suite("ArchiveTranslationJob")
struct ArchiveTranslationJobTests {

    // MARK: - Fixtures

    private let resultTimeout: TimeInterval = 5
    private let sessionID: Int64 = 42
    private let language = "en"

    private func makeJob() -> ArchiveTranslationJob {
        ArchiveTranslationJob()
    }

    /// `count` sentences: indexes 0..<count, texts "s0"…"sN".
    private func makeSentences(_ count: Int) -> [Sentence] {
        (0 ..< count).map { index in
            Sentence(
                index: index, startS: Double(index), endS: Double(index) + 1,
                lang: "ja", text: "s\(index)"
            )
        }
    }

    private func makeRequest(
        sentenceCount: Int = 3,
        translated: Set<Int> = [],
        scope: ArchiveTranslationJob.Scope = .missing,
        provider: TranslationProvider = .google
    ) -> ArchiveTranslationJob.Request {
        ArchiveTranslationJob.Request(
            sessionID: sessionID,
            lang: language,
            provider: provider,
            sentences: makeSentences(sentenceCount),
            translated: translated,
            scope: scope
        )
    }

    // MARK: - Scope computation

    @Test("the missing scope picks the indexes without a translation, in sentence order")
    func missingScopeIndexes() {
        let request = makeRequest(sentenceCount: 5, translated: [1, 3])

        let indexes = ArchiveTranslationJob.indexes(for: request)

        #expect(indexes == [0, 2, 4])
    }

    @Test("the all scope returns every index in sentence order")
    func allScopeIndexes() {
        let request = makeRequest(scope: .all)

        let indexes = ArchiveTranslationJob.indexes(for: request)

        #expect(indexes == [0, 1, 2])
    }

    @Test("the failedOnly scope keeps exactly the given indexes in sentence order")
    func failedOnlyScopeIndexes() {
        let request = makeRequest(sentenceCount: 5, scope: .failedOnly([3, 0, 99]))

        let indexes = ArchiveTranslationJob.indexes(for: request)

        #expect(indexes == [0, 3])
    }

    // MARK: - Ordered landing & progress

    @Test("a run lands one result per sentence in index order and publishes progress 1..N")
    func landsInIndexOrderAndPublishesProgress() async {
        let job = makeJob()
        let engine = ScriptedEngine()
        job.resolveEngine = { provider, target in
            #expect(provider == .google)
            #expect(target.code == "en")
            return .ready(engine: engine, kind: .google)
        }
        let recorder = Recorder()
        job.onEvent = recorder.recordEvent
        job.land = recorder.recordLanding
        let request = makeRequest()

        #expect(job.prepare())
        await job.run(request)

        #expect(engine.recordedBatches == [["s0"], ["s1"], ["s2"]], "one sentence per engine call")
        #expect(recorder.landedIndexes == [0, 1, 2])
        #expect(recorder.landed == [
            SentenceTranslation(lang: language, text: "T:s0", engine: .google),
            SentenceTranslation(lang: language, text: "T:s1", engine: .google),
            SentenceTranslation(lang: language, text: "T:s2", engine: .google)
        ])
        #expect(recorder.events == [
            .started(total: 3),
            .progress(processed: 1, total: 3),
            .progress(processed: 2, total: 3),
            .progress(processed: 3, total: 3),
            .finished(translated: 3, failedIndexes: [])
        ])
        #expect(job.kind == .google)
        #expect(job.currentRun == request)
        #expect(job.isActive == false)
        #expect(job.isRunning == false)
    }

    // MARK: - Failures

    @Test("failures are skipped, reported in index order, and later sentences still run")
    func failuresAreSkippedAndReportedInOrder() async {
        let job = makeJob()
        let engine = ScriptedEngine()
        engine.fail(on: ["s1", "s2"])
        job.resolveEngine = { _, _ in .ready(engine: engine, kind: .deepl) }
        let recorder = Recorder()
        job.onEvent = recorder.recordEvent
        job.land = recorder.recordLanding
        let request = makeRequest(sentenceCount: 4, scope: .all)

        #expect(job.prepare())
        await job.run(request)

        #expect(
            engine.recordedBatches == [["s0"], ["s1"], ["s2"], ["s3"]],
            "the loop never stops for a failure"
        )
        #expect(recorder.landedIndexes == [0, 3])
        #expect(job.translatedCount == 2)
        #expect(job.failureIndexes == [1, 2])
        #expect(job.processed == 4, "the progress count includes the failures")
        #expect(recorder.events.last == .finished(translated: 2, failedIndexes: [1, 2]))
        #expect(job.isActive == false)
    }

    // MARK: - Cancel

    @Test("a cancel from inside the landing hook stops before the next sentence")
    func cancelFromLandingHookStopsBeforeTheNextSentence() async {
        let job = makeJob()
        let engine = ScriptedEngine()
        job.resolveEngine = { _, _ in .ready(engine: engine, kind: .google) }
        let recorder = Recorder()
        recorder.cancelAfterLandings = 2
        recorder.cancel = { [weak job] in job?.cancel() }
        job.onEvent = recorder.recordEvent
        job.land = recorder.recordLanding
        let request = makeRequest(sentenceCount: 5)

        #expect(job.prepare())
        await job.run(request)

        #expect(recorder.landedIndexes == [0, 1], "the partial results stay landed")
        #expect(recorder.landed == [
            SentenceTranslation(lang: language, text: "T:s0", engine: .google),
            SentenceTranslation(lang: language, text: "T:s1", engine: .google)
        ])
        #expect(engine.recordedBatches == [["s0"], ["s1"]], "no sentence starts after the cancel")
        #expect(recorder.events == [
            .started(total: 5),
            .progress(processed: 1, total: 5),
            .progress(processed: 2, total: 5),
            .cancelled(translated: 2)
        ])
        #expect(job.isActive == false)
        #expect(job.isRunning == false)
    }

    @Test("a missing-scope rerun after a cancel resumes with only the remaining indexes")
    func missingRerunAfterCancelResumesWithRemainingIndexes() async {
        let job = makeJob()
        let engine = ScriptedEngine()
        job.resolveEngine = { _, _ in .ready(engine: engine, kind: .google) }
        let recorder = Recorder()
        recorder.cancelAfterLandings = 2
        recorder.cancel = { [weak job] in job?.cancel() }
        job.onEvent = recorder.recordEvent
        job.land = recorder.recordLanding

        #expect(job.prepare())
        await job.run(makeRequest(sentenceCount: 5))
        #expect(recorder.landedIndexes == [0, 1])

        #expect(job.prepare())
        await job.run(
            makeRequest(sentenceCount: 5, translated: Set(recorder.landedIndexes))
        )

        #expect(recorder.landedIndexes == [0, 1, 2, 3, 4])
        #expect(
            engine.recordedBatches == [["s0"], ["s1"], ["s2"], ["s3"], ["s4"]],
            "only the sentences still missing ran"
        )
        #expect(recorder.events.last == .finished(translated: 3, failedIndexes: []))
    }

    @Test("an all-scope rerun after a cancel re-translates from the first sentence")
    func allScopeRerunAfterCancelStartsOver() async {
        let job = makeJob()
        let engine = ScriptedEngine()
        job.resolveEngine = { _, _ in .ready(engine: engine, kind: .appleFast) }
        let recorder = Recorder()
        recorder.cancelAfterLandings = 2
        recorder.cancel = { [weak job] in job?.cancel() }
        job.onEvent = recorder.recordEvent
        job.land = recorder.recordLanding

        #expect(job.prepare())
        await job.run(makeRequest(sentenceCount: 5))
        #expect(recorder.landedIndexes == [0, 1])

        #expect(job.prepare())
        await job.run(
            makeRequest(sentenceCount: 5, translated: Set(recorder.landedIndexes), scope: .all)
        )

        #expect(recorder.landedIndexes == [0, 1, 0, 1, 2, 3, 4])
        #expect(engine.recordedBatches == [
            ["s0"], ["s1"], ["s0"], ["s1"], ["s2"], ["s3"], ["s4"]
        ], "the full pass restarts from the first sentence")
    }

    @Test("a failedOnly rerun processes exactly the failed indexes in index order")
    func failedOnlyRerunProcessesTheFailuresInOrder() async {
        let job = makeJob()
        let engine = ScriptedEngine()
        engine.fail(on: ["s1", "s2"])
        job.resolveEngine = { _, _ in .ready(engine: engine, kind: .openrouter) }
        let recorder = Recorder()
        job.onEvent = recorder.recordEvent
        job.land = recorder.recordLanding

        #expect(job.prepare())
        await job.run(makeRequest(sentenceCount: 4, scope: .all))
        #expect(job.failureIndexes == [1, 2])

        engine.clearFailures()
        #expect(job.prepare())
        await job.run(
            makeRequest(
                sentenceCount: 4, scope: .failedOnly(Set(job.failureIndexes))
            )
        )

        #expect(recorder.landedIndexes == [0, 3, 1, 2], "the retry lands the failed set after the first pass")
        #expect(engine.recordedBatches == [
            ["s0"], ["s1"], ["s2"], ["s3"], ["s1"], ["s2"]
        ])
        #expect(job.failureIndexes.isEmpty)
    }

    // MARK: - Claim lifecycle

    @Test("prepare claims the slot once and refuses a second claim")
    func prepareClaimsTheSlotOnce() {
        let job = makeJob()

        #expect(job.prepare())
        #expect(job.prepare() == false)
    }

    @Test("a run without the prepare claim is refused with no events")
    func unpreparedRunIsRefused() async {
        let job = makeJob()
        let engine = ScriptedEngine()
        job.resolveEngine = { _, _ in .ready(engine: engine, kind: .google) }
        let recorder = Recorder()
        job.onEvent = recorder.recordEvent
        job.land = recorder.recordLanding

        await job.run(makeRequest())

        #expect(recorder.events.isEmpty)
        #expect(recorder.landedIndexes.isEmpty)
        #expect(engine.recordedBatches.isEmpty)
        #expect(job.isActive == false)
    }

    @Test("a second prepare is refused while a run is airborne")
    func secondPrepareWhileAirborneIsRefused() async {
        let job = makeJob()
        let engine = ScriptedEngine()
        let gate = AsyncGate()
        job.resolveEngine = { _, _ in
            await gate.wait()
            return .ready(engine: engine, kind: .google)
        }
        let recorder = Recorder()
        job.onEvent = recorder.recordEvent
        job.land = recorder.recordLanding

        #expect(job.prepare())
        let run = Task { await job.run(makeRequest()) }
        #expect(
            await pollUntil(timeout: resultTimeout) { gate.enteredCount == 1 },
            "the run parks in engine resolution"
        )
        #expect(job.prepare() == false, "the airborne run holds the claim")

        gate.open()
        await run.value
        #expect(job.prepare(), "the finished run frees the slot")
    }

    // MARK: - Engine resolution outcomes

    @Test("an unavailable resolution reports its reason and releases the slot")
    func unavailableResolutionReportsAndReleases() async {
        let job = makeJob()
        let reason = "No API key stored for Google Translate."
        job.resolveEngine = { _, _ in .unavailable(reason: reason) }
        let recorder = Recorder()
        job.onEvent = recorder.recordEvent
        job.land = recorder.recordLanding

        #expect(job.prepare())
        await job.run(makeRequest())

        #expect(recorder.events == [.unavailable(reason: reason)])
        #expect(recorder.landedIndexes.isEmpty)
        #expect(job.isActive == false)
        #expect(job.isRunning == false)
    }

    @Test("a cancelled resolution stays silent")
    func cancelledResolutionStaysSilent() async {
        let job = makeJob()
        job.resolveEngine = { _, _ in .cancelled }
        let recorder = Recorder()
        job.onEvent = recorder.recordEvent
        job.land = recorder.recordLanding

        #expect(job.prepare())
        await job.run(makeRequest())

        #expect(recorder.events.isEmpty)
        #expect(recorder.landedIndexes.isEmpty)
        #expect(job.isActive == false)
        #expect(job.isRunning == false)
    }

    @Test("an empty scope finishes at zero without resolving the engine")
    func emptyScopeFinishesWithoutResolving() async {
        let job = makeJob()
        let resolutions = Mutex(0)
        job.resolveEngine = { _, _ in
            resolutions.withLock { count in count += 1 }
            return .unavailable(reason: "unused")
        }
        let recorder = Recorder()
        job.onEvent = recorder.recordEvent
        job.land = recorder.recordLanding

        #expect(job.prepare())
        await job.run(makeRequest(translated: [0, 1, 2]))

        #expect(recorder.events == [.finished(translated: 0, failedIndexes: [])])
        #expect(resolutions.withLock { count in count } == 0, "the resolver is never consulted")
        #expect(job.isActive == false)
    }

    @Test("the claim reads active while resolving and running once the engine is ready")
    func activeWhileResolvingRunningOnceReady() async {
        let job = makeJob()
        let engineGate = AsyncGate()
        let resolutionGate = AsyncGate()
        let engine = ScriptedEngine(gate: engineGate)
        job.resolveEngine = { _, _ in
            await resolutionGate.wait()
            return .ready(engine: engine, kind: .appleFast)
        }
        let recorder = Recorder()
        job.onEvent = recorder.recordEvent
        job.land = recorder.recordLanding

        #expect(job.prepare())
        let run = Task { await job.run(makeRequest()) }
        #expect(
            await pollUntil(timeout: resultTimeout) { resolutionGate.enteredCount == 1 },
            "the run parks in engine resolution"
        )
        #expect(job.isActive, "the claim is active from prepare onward")
        #expect(job.isRunning == false, "no engine work starts while resolving")

        resolutionGate.open()
        #expect(
            await pollUntil(timeout: resultTimeout) { engineGate.enteredCount == 1 },
            "the first sentence parks in the engine"
        )
        #expect(job.isRunning, "the loop is running once the engine is resolved")
        #expect(recorder.events.first == .started(total: 3))

        engineGate.open()
        await run.value
        #expect(job.isRunning == false)
        #expect(job.isActive == false)
        #expect(recorder.events.last == .finished(translated: 3, failedIndexes: []))
    }
}

// MARK: - Fixtures

/// The job's event and landing sinks, kept together so a test can script a
/// one-shot cancel after the Nth landing.
@MainActor
private final class Recorder {
    private(set) var events: [ArchiveTranslationJob.Event] = []
    private(set) var landedIndexes: [Int] = []
    private(set) var landed: [SentenceTranslation] = []

    /// The landing ordinal that triggers `cancel` once, then defuses.
    var cancelAfterLandings: Int?
    var cancel: (@MainActor () -> Void)?

    func recordEvent(_ event: ArchiveTranslationJob.Event) {
        events.append(event)
    }

    func recordLanding(_ index: Int, _ translation: SentenceTranslation) {
        landedIndexes.append(index)
        landed.append(translation)
        if landedIndexes.count == cancelAfterLandings {
            cancelAfterLandings = nil
            cancel?()
        }
    }
}

/// A one-shot gate: `wait()` parks until `open()` releases every waiter, and
/// later calls pass straight through. The entered count is the deterministic
/// "the run reached this point" observable.
private final class AsyncGate: @unchecked Sendable {
    private struct State {
        var open = false
        var entered = 0
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    var enteredCount: Int {
        state.withLock { current in current.entered }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            let immediate = state.withLock { current -> CheckedContinuation<Void, Never>? in
                current.entered += 1
                guard !current.open else { return continuation }
                current.waiters.append(continuation)
                return nil
            }
            immediate?.resume()
        }
    }

    func open() {
        let parked = state.withLock { current -> [CheckedContinuation<Void, Never>] in
            current.open = true
            let waiters = current.waiters
            current.waiters.removeAll()
            return waiters
        }
        for waiter in parked {
            waiter.resume()
        }
    }
}

/// Deterministic engine double: translates `text` to `"T:\(text)"`, records
/// every batch (one sentence per call, the job's contract), fails on
/// scripted inputs, and can park each call on a gate until released.
private final class ScriptedEngine: TranslationEngine, @unchecked Sendable {
    let preferredBatchSize = 1
    var onRetry: (@Sendable (RetryProgress) -> Void)?

    private struct State {
        var batches: [[String]] = []
        var failing: Set<String> = []
        let gate: AsyncGate?
    }

    private let state: Mutex<State>

    init(gate: AsyncGate? = nil) {
        state = Mutex(State(gate: gate))
    }

    var recordedBatches: [[String]] {
        state.withLock { current in current.batches }
    }

    /// Inputs that throw instead of translating.
    func fail(on texts: Set<String>) {
        state.withLock { current in current.failing.formUnion(texts) }
    }

    func clearFailures() {
        state.withLock { current in current.failing.removeAll() }
    }

    func translate(_ texts: [String]) async throws -> [String] {
        let gate = state.withLock { current -> AsyncGate? in
            current.batches.append(texts)
            return current.gate
        }
        if let gate {
            await gate.wait()
        }
        try Task.checkCancellation()
        let failing = state.withLock { current in current.failing }
        if texts.contains(where: { text in failing.contains(text) }) {
            throw TranslationEngineError.serverError(500)
        }
        return texts.map { text in "T:\(text)" }
    }
}
