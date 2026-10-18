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
        engine: RetranslateEngine = .google
    ) -> ArchiveTranslationJob.Request {
        ArchiveTranslationJob.Request(
            sessionID: sessionID,
            lang: language,
            engine: engine,
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
        let scriptedEngine = ScriptedEngine()
        job.resolveEngine = { engine, target in
            #expect(engine == .google)
            #expect(target.code == "en")
            return .ready(engine: scriptedEngine, kind: .google)
        }
        let recorder = Recorder()
        job.onEvent = recorder.recordEvent
        job.land = recorder.recordLanding
        let request = makeRequest()

        #expect(job.claim(request))
        await job.run()

        #expect(scriptedEngine.recordedBatches == [["s0"], ["s1"], ["s2"]], "one sentence per engine call")
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
        #expect(job.lastRun?.kind == .google)
        #expect(job.lastRun?.request == request)
        #expect(job.activity == .idle, "the request moves into `lastRun` once the run ends")
        #expect(job.activity == .idle)
        #expect(!job.activity.isRunning)
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

        #expect(job.claim(request))
        await job.run()

        #expect(
            engine.recordedBatches == [["s0"], ["s1"], ["s2"], ["s3"]],
            "the loop never stops for a failure"
        )
        #expect(recorder.landedIndexes == [0, 3])
        #expect(job.translatedCount == 2)
        #expect(job.failureIndexes == [1, 2])
        #expect(job.lastRun?.processed == 4, "the progress count includes the failures")
        #expect(recorder.events.last == .finished(translated: 2, failedIndexes: [1, 2]))
        #expect(job.activity == .idle)
    }

    @Test("a landing sink reporting a lost write counts the sentence as failed")
    func lostWriteCountsAsFailure() async {
        let job = makeJob()
        let engine = ScriptedEngine()
        job.resolveEngine = { _, _ in .ready(engine: engine, kind: .google) }
        let recorder = Recorder()
        recorder.unlandedIndexes = [1]
        job.onEvent = recorder.recordEvent
        job.land = recorder.recordLanding

        #expect(job.claim(makeRequest()))
        await job.run()

        #expect(recorder.landedIndexes == [0, 1, 2], "the sink still sees every result")
        #expect(job.translatedCount == 2, "the lost write is not counted as a success")
        #expect(job.failureIndexes == [1], "the lost write becomes a retryable failure")
        #expect(job.lastRun?.processed == 3)
        #expect(recorder.events.last == .finished(translated: 2, failedIndexes: [1]))
    }

    @Test("an engine-reported CancellationError fails that sentence and the walk continues")
    func engineCancellationFailsOnlyItsSentence() async {
        let job = makeJob()
        let engine = ScriptedEngine()
        engine.cancel(on: ["s1"])
        job.resolveEngine = { _, _ in .ready(engine: engine, kind: .google) }
        let recorder = Recorder()
        job.onEvent = recorder.recordEvent
        job.land = recorder.recordLanding

        #expect(job.claim(makeRequest(scope: .all)))
        await job.run()

        #expect(
            engine.recordedBatches == [["s0"], ["s1"], ["s2"]],
            "the walk continues past the engine-reported cancellation"
        )
        #expect(recorder.landedIndexes == [0, 2])
        #expect(job.failureIndexes == [1])
        #expect(recorder.events.last == .finished(translated: 2, failedIndexes: [1]))
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

        #expect(job.claim(request))
        await job.run()

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
        #expect(job.activity == .idle)
        #expect(!job.activity.isRunning)
        #expect(job.lastRun?.processed == 2, "the cancel keeps the last published count")
    }

    @Test("a cancel during engine resolution discards the run silently")
    func cancelDuringResolutionDiscardsRun() async {
        let job = makeJob()
        let gate = AsyncGate()
        let engine = ScriptedEngine()
        job.resolveEngine = { _, _ in
            await gate.wait()
            return .ready(engine: engine, kind: .google)
        }
        let recorder = Recorder()
        job.onEvent = recorder.recordEvent
        job.land = recorder.recordLanding

        let request = makeRequest()
        #expect(job.claim(request))
        let run = Task { await job.run() }
        #expect(
            await pollUntil(timeout: resultTimeout) { gate.enteredCount == 1 },
            "the run parks in engine resolution"
        )
        #expect(job.activity == .claimed(request), "the claimed request is visible while resolving")
        job.cancel()
        gate.open()
        await run.value

        #expect(recorder.events.isEmpty, "a cancelled resolution reports nothing")
        #expect(recorder.landedIndexes.isEmpty)
        #expect(engine.recordedBatches.isEmpty)
        #expect(job.activity == .idle)
        #expect(!job.activity.isRunning)
        #expect(job.lastRun == nil)
        #expect(job.activity == .idle)
    }

    @Test("a real cancel surfacing as a CancellationError stops the walk")
    func realCancelThroughCancellationErrorStopsWalk() async {
        let job = makeJob()
        let gate = AsyncGate()
        let engine = ScriptedEngine(gate: gate)
        engine.cancel(on: ["s0"])
        job.resolveEngine = { _, _ in .ready(engine: engine, kind: .google) }
        let recorder = Recorder()
        job.onEvent = recorder.recordEvent
        job.land = recorder.recordLanding

        #expect(job.claim(makeRequest()))
        let run = Task { await job.run() }
        #expect(
            await pollUntil(timeout: resultTimeout) { gate.enteredCount == 1 },
            "the first sentence parks in the engine"
        )
        job.cancel()
        gate.open()
        await run.value

        #expect(recorder.events.last == .cancelled(translated: 0))
        #expect(engine.recordedBatches == [["s0"]], "no sentence starts after the cancel")
        #expect(job.failureIndexes.isEmpty, "a real cancel is not a failure")
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

        #expect(job.claim(makeRequest(sentenceCount: 5)))
        await job.run()
        #expect(recorder.landedIndexes == [0, 1])

        #expect(job.claim(makeRequest(sentenceCount: 5, translated: Set(recorder.landedIndexes))))
        await job.run()

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

        #expect(job.claim(makeRequest(sentenceCount: 5)))
        await job.run()
        #expect(recorder.landedIndexes == [0, 1])

        #expect(job.claim(makeRequest(sentenceCount: 5, translated: Set(recorder.landedIndexes), scope: .all)))
        await job.run()

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

        #expect(job.claim(makeRequest(sentenceCount: 4, scope: .all)))
        await job.run()
        #expect(job.failureIndexes == [1, 2])

        engine.clearFailures()
        #expect(job.claim(makeRequest(sentenceCount: 4, scope: .failedOnly(Set(job.failureIndexes)))))
        await job.run()

        #expect(recorder.landedIndexes == [0, 3, 1, 2], "the retry lands the failed set after the first pass")
        #expect(engine.recordedBatches == [
            ["s0"], ["s1"], ["s2"], ["s3"], ["s1"], ["s2"]
        ])
        #expect(job.failureIndexes.isEmpty)
    }
}

/// The claim-lifecycle and engine-resolution cases of the suite, split from
/// the main declaration at the type-body-length gate.
extension ArchiveTranslationJobTests {

    // MARK: - Claim lifecycle

    @Test("prepare claims the slot once and refuses a second claim")
    func prepareClaimsTheSlotOnce() {
        let job = makeJob()
        let request = makeRequest()

        #expect(job.claim(request))
        #expect(job.claim(request) == false)
    }

    @Test("a run without the prepare claim is refused with no events")
    func unpreparedRunIsRefused() async {
        let job = makeJob()
        let engine = ScriptedEngine()
        job.resolveEngine = { _, _ in .ready(engine: engine, kind: .google) }
        let recorder = Recorder()
        job.onEvent = recorder.recordEvent
        job.land = recorder.recordLanding

        await job.run()

        #expect(recorder.events.isEmpty)
        #expect(recorder.landedIndexes.isEmpty)
        #expect(engine.recordedBatches.isEmpty)
        #expect(job.activity == .idle)
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

        let request = makeRequest()
        #expect(job.claim(request))
        let run = Task { await job.run() }
        #expect(
            await pollUntil(timeout: resultTimeout) { gate.enteredCount == 1 },
            "the run parks in engine resolution"
        )
        #expect(job.claim(makeRequest()) == false, "the airborne run holds the claim")

        gate.open()
        await run.value
        #expect(job.claim(makeRequest()), "the finished run frees the slot")
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

        #expect(job.claim(makeRequest()))
        await job.run()

        #expect(recorder.events == [.unavailable(reason: reason)])
        #expect(recorder.landedIndexes.isEmpty)
        #expect(job.activity == .idle)
        #expect(!job.activity.isRunning)
        #expect(job.activity == .idle, "an early return releases the claim")
    }

    @Test("a cancelled resolution stays silent")
    func cancelledResolutionStaysSilent() async {
        let job = makeJob()
        job.resolveEngine = { _, _ in .cancelled }
        let recorder = Recorder()
        job.onEvent = recorder.recordEvent
        job.land = recorder.recordLanding

        #expect(job.claim(makeRequest()))
        await job.run()

        #expect(recorder.events.isEmpty)
        #expect(recorder.landedIndexes.isEmpty)
        #expect(job.activity == .idle)
        #expect(!job.activity.isRunning)
        #expect(job.activity == .idle)
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

        #expect(job.claim(makeRequest(translated: [0, 1, 2])))
        await job.run()

        #expect(recorder.events == [.finished(translated: 0, failedIndexes: [])])
        #expect(resolutions.withLock { count in count } == 0, "the resolver is never consulted")
        #expect(job.activity == .idle, "an empty scope leaves the activity idle")
        #expect(job.activity == .idle)
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

        let request = makeRequest()
        #expect(job.claim(request))
        let run = Task { await job.run() }
        #expect(
            await pollUntil(timeout: resultTimeout) { resolutionGate.enteredCount == 1 },
            "the run parks in engine resolution"
        )
        #expect(job.activity == .claimed(request), "the claim is active from the claim onward")
        #expect(!job.activity.isRunning, "no engine work starts while resolving")
        #expect(job.activity == .claimed(request), "the resolving request is readable during the claim")

        resolutionGate.open()
        #expect(
            await pollUntil(timeout: resultTimeout) { engineGate.enteredCount == 1 },
            "the first sentence parks in the engine"
        )
        #expect(job.activity.isRunning, "the loop is running once the engine is resolved")
        #expect(job.activity.request == request, "the pending request moved into the running activity")
        #expect(recorder.events.first == .started(total: 3))

        engineGate.open()
        await run.value
        #expect(!job.activity.isRunning)
        #expect(job.activity == .idle)
        #expect(recorder.events.last == .finished(translated: 3, failedIndexes: []))
    }
}
