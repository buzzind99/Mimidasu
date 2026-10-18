import Foundation
@testable import Mimidasu
import Synchronization
import Testing

/// Pins `ArchiveTranslationJob`'s activity projection: the synchronous
/// claim from the click onward, the scoped `activity(for:)` read, the
/// claimed → running(progress) → idle walk, and `lastRun`'s preservation
/// across runs that never begin. Drives the job directly against the shared
/// scripted engine and gate doubles.
@MainActor
@Suite("ArchiveTranslationJob activity")
struct ArchiveTranslationJobActivityTests {

    // MARK: - Fixtures

    private let resultTimeout: TimeInterval = 5
    private let sessionID: Int64 = 42

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
        engine: RetranslateEngine = .google,
        lang: String = "en"
    ) -> ArchiveTranslationJob.Request {
        ArchiveTranslationJob.Request(
            sessionID: sessionID,
            lang: lang,
            engine: engine,
            sentences: makeSentences(sentenceCount),
            translated: translated,
            scope: scope
        )
    }

    /// Runs one full successful run so the following non-begun cases can pin
    /// that `lastRun` survives them.
    private func seedSuccessfulRun(
        on job: ArchiveTranslationJob
    ) async throws -> ArchiveTranslationJob.LastRun {
        let engine = ScriptedEngine()
        job.resolveEngine = { _, _ in .ready(engine: engine, kind: .google) }
        try #require(job.claim(makeRequest()))
        await job.run()
        return try #require(job.lastRun, "the seed run leaves a record")
    }

    // MARK: - Claim

    @Test("a claim publishes the claimed activity synchronously and refuses a second claim")
    func claimPublishesClaimedActivitySynchronously() {
        let job = makeJob()
        let request = makeRequest()

        let claimed = job.claim(request)

        #expect(claimed, "the free slot accepts the claim")
        #expect(job.activity == .claimed(request), "the claim is visible before any run")
        #expect(job.claim(makeRequest()) == false, "a second claim is refused")
        #expect(job.activity == .claimed(request), "the refused claim leaves the activity unchanged")
    }

    @Test("activity(for:) scopes the claim to the run's session")
    func activityForScopesTheClaimToItsSession() {
        let job = makeJob()
        #expect(job.activity(for: sessionID) == .idle, "a fresh job is idle")

        let request = makeRequest()
        #expect(job.claim(request))

        #expect(job.activity(for: request.sessionID) == .claimed(request))
        #expect(job.activity(for: request.sessionID + 1) == .idle, "a foreign session never sees the claim")
    }

    // MARK: - The walk

    @Test("the walk moves claimed to running to idle and leaves a final lastRun")
    func walkMovesClaimedToRunningToIdle() async {
        let job = makeJob()
        let resolutionGate = AsyncGate()
        let engineGate = AsyncGate()
        let engine = ScriptedEngine(gate: engineGate)
        job.resolveEngine = { _, _ in
            await resolutionGate.wait()
            return .ready(engine: engine, kind: .google)
        }
        job.land = { _, _ in true }
        let request = makeRequest()

        #expect(job.claim(request))

        let run = Task { await job.run() }
        #expect(
            await pollUntil(timeout: resultTimeout) { resolutionGate.enteredCount == 1 },
            "the run parks in engine resolution"
        )
        #expect(job.activity == .claimed(request), "engine resolution keeps the run claimed")
        #expect(job.lastRun == nil, "nothing has begun while the resolver runs")

        resolutionGate.open()
        #expect(
            await pollUntil(timeout: resultTimeout) { engineGate.enteredCount == 1 },
            "the walk parks in its first engine call"
        )
        #expect(
            job.activity == .running(
                request,
                progress: ArchiveTranslationJob.RunProgress(kind: .google, processed: 0, total: 3)
            )
        )
        #expect(job.activity(for: request.sessionID) == job.activity, "the running state is scoped to its session")
        #expect(job.activity(for: request.sessionID + 1) == .idle, "a foreign session never sees the walk")
        #expect(
            job.lastRun == ArchiveTranslationJob.LastRun(request: request, kind: .google, total: 3, processed: 0)
        )

        engineGate.open()
        await run.value

        #expect(job.activity == .idle)
        #expect(
            job.lastRun == ArchiveTranslationJob.LastRun(request: request, kind: .google, total: 3, processed: 3)
        )
    }

    @Test("running progress advances per sentence and counts failures")
    func runningProgressAdvancesAndCountsFailures() async {
        let job = makeJob()
        let gate = PermitGate()
        let engine = ScriptedArchiveEngine(gate: gate)
        engine.fail(on: ["s1"])
        job.resolveEngine = { _, _ in .ready(engine: engine, kind: .google) }
        job.land = { _, _ in true }
        let request = makeRequest(scope: .all)

        #expect(job.claim(request))
        let run = Task { await job.run() }

        #expect(
            await pollUntil(timeout: resultTimeout) { engine.recordedBatches.count == 1 },
            "the walk parks on the first sentence"
        )
        #expect(
            job.activity == .running(
                request,
                progress: ArchiveTranslationJob.RunProgress(kind: .google, processed: 0, total: 3)
            )
        )

        gate.release()
        #expect(
            await pollUntil(timeout: resultTimeout) { job.activity.progress?.processed == 1 },
            "the first landing advances the progress"
        )

        gate.release()
        #expect(
            await pollUntil(timeout: resultTimeout) { job.activity.progress?.processed == 2 },
            "the failed sentence still advances the progress"
        )
        #expect(job.failureIndexes == [1], "the failure is reported in index order")
        #expect(
            job.activity == .running(
                request,
                progress: ArchiveTranslationJob.RunProgress(kind: .google, processed: 2, total: 3)
            ),
            "the progress count includes the failure"
        )

        gate.release()
        await run.value

        #expect(job.activity == .idle)
        #expect(job.lastRun?.processed == 3)
    }

    // MARK: - Non-begun outcomes keep lastRun

    @Test("an unavailable resolution keeps the previous lastRun and ends idle")
    func unavailableResolutionKeepsPreviousLastRun() async throws {
        let job = makeJob()
        let seeded = try await seedSuccessfulRun(on: job)

        let reason = "No API key stored for Google Translate."
        job.resolveEngine = { _, _ in .unavailable(reason: reason) }
        let recorder = Recorder()
        job.onEvent = recorder.recordEvent
        #expect(job.claim(makeRequest(engine: .deepl)))
        await job.run()

        #expect(job.activity == .idle)
        #expect(job.lastRun == seeded, "the non-begun run leaves the previous record")
        #expect(recorder.events == [.unavailable(reason: reason)])
    }

    @Test("a cancel during resolution ends idle and silently keeps lastRun")
    func cancelDuringResolutionKeepsPreviousLastRun() async throws {
        let job = makeJob()
        let seeded = try await seedSuccessfulRun(on: job)

        let resolutionGate = AsyncGate()
        let engine = ScriptedEngine()
        job.resolveEngine = { _, _ in
            await resolutionGate.wait()
            return .ready(engine: engine, kind: .google)
        }
        let recorder = Recorder()
        job.onEvent = recorder.recordEvent
        #expect(job.claim(makeRequest(engine: .deepl)))
        let run = Task { await job.run() }
        #expect(
            await pollUntil(timeout: resultTimeout) { resolutionGate.enteredCount == 1 },
            "the run parks in engine resolution"
        )

        job.cancel()
        resolutionGate.open()
        await run.value

        #expect(job.activity == .idle)
        #expect(job.lastRun == seeded, "the cancelled resolution leaves the record untouched")
        #expect(recorder.events.isEmpty, "a cancelled resolution reports nothing")
    }

    @Test("an empty scope finishes at zero, skips the resolver, and keeps lastRun")
    func emptyScopeKeepsPreviousLastRunAndSkipsResolver() async throws {
        let job = makeJob()
        let seeded = try await seedSuccessfulRun(on: job)

        let resolutions = Mutex(0)
        job.resolveEngine = { _, _ in
            resolutions.withLock { count in count += 1 }
            return .unavailable(reason: "unused")
        }
        let recorder = Recorder()
        job.onEvent = recorder.recordEvent
        #expect(job.claim(makeRequest(translated: [0, 1, 2])))
        await job.run()

        #expect(job.activity == .idle)
        #expect(job.lastRun == seeded, "the empty scope leaves the record untouched")
        #expect(recorder.events == [.finished(translated: 0, failedIndexes: [])])
        #expect(resolutions.withLock { count in count } == 0, "the resolver is never consulted")
    }

    @Test("a second run snapshots a fresh lastRun with reset progress")
    func secondRunSnapshotsFreshLastRun() async {
        let job = makeJob()
        let firstEngine = ScriptedEngine()
        job.resolveEngine = { _, _ in .ready(engine: firstEngine, kind: .google) }
        job.land = { _, _ in true }
        let first = makeRequest()

        #expect(job.claim(first))
        await job.run()
        #expect(
            job.lastRun == ArchiveTranslationJob.LastRun(request: first, kind: .google, total: 3, processed: 3)
        )

        let engineGate = AsyncGate()
        let secondEngine = ScriptedEngine(gate: engineGate)
        job.resolveEngine = { _, _ in .ready(engine: secondEngine, kind: .deepl) }
        let second = makeRequest(sentenceCount: 1, scope: .all, engine: .deepl, lang: "de")

        #expect(job.claim(second))
        #expect(
            job.lastRun == ArchiveTranslationJob.LastRun(request: first, kind: .google, total: 3, processed: 3),
            "the claim leaves the previous record"
        )

        let run = Task { await job.run() }
        #expect(
            await pollUntil(timeout: resultTimeout) { engineGate.enteredCount == 1 },
            "the second run parks in its first engine call"
        )
        #expect(
            job.lastRun == ArchiveTranslationJob.LastRun(request: second, kind: .deepl, total: 1, processed: 0),
            "the fresh snapshot resets the progress"
        )

        engineGate.open()
        await run.value

        #expect(
            job.lastRun == ArchiveTranslationJob.LastRun(request: second, kind: .deepl, total: 1, processed: 1)
        )
    }
}
