import Foundation
@testable import Mimidasu
import Testing

/// Drives `ArchiveTranslationJob` through the run lifecycle to pin the split
/// between the transition activity and the per-tick run progress: claim and
/// resolution publish no counts, the walk starts and advances them, a failure
/// counts like a success, the finish clears them, and every non-begun outcome
/// leaves them empty.
@MainActor
@Suite("Archive translation run progress")
struct ArchiveRunProgressTests {

    // MARK: - Fixtures

    private let resultTimeout: TimeInterval = 5

    private func makeJob() -> ArchiveTranslationJob {
        ArchiveTranslationJob()
    }

    // MARK: - Claim and start

    @Test("a claim publishes the claimed status with no run progress")
    func claimPublishesNoProgress() {
        let job = makeJob()
        let request = ArchiveTranslationJobFixtures.makeRequest()

        let claimed = job.claim(request)

        #expect(claimed, "the free slot accepts the claim")
        #expect(job.activity == .claimed(ArchiveTranslationJob.RunStatus(request)))
        #expect(job.runProgress == nil, "nothing runs at claim time")
    }

    @Test("the walk starts at zero progress with the resolved engine kind")
    func walkStartsAtZeroProgress() async {
        let job = makeJob()
        let gate = AsyncGate()
        let engine = ScriptedEngine(gate: gate)
        job.resolveEngine = { _, _ in .ready(engine: engine, kind: .google) }
        job.land = { _, _ in true }

        #expect(job.claim(ArchiveTranslationJobFixtures.makeRequest()))
        let run = Task { await job.run() }

        #expect(
            await pollUntil(timeout: resultTimeout) { gate.enteredCount == 1 },
            "the walk parks in its first engine call"
        )
        #expect(job.activity == .running(ArchiveTranslationJobFixtures.makeStatus()))
        #expect(
            job.runProgress
                == ArchiveTranslationJobFixtures.makeRunProgress(kind: .google, processed: 0, total: 3)
        )

        gate.open()
        await run.value
    }

    // MARK: - Per-sentence ticks

    @Test("a per-sentence tick advances runProgress and leaves the activity unchanged")
    func tickAdvancesOnlyRunProgress() async {
        let job = makeJob()
        let gate = PermitGate()
        let engine = ScriptedArchiveEngine(gate: gate)
        job.resolveEngine = { _, _ in .ready(engine: engine, kind: .google) }
        job.land = { _, _ in true }

        #expect(job.claim(ArchiveTranslationJobFixtures.makeRequest(scope: .all)))
        let run = Task { await job.run() }

        #expect(
            await pollUntil(timeout: resultTimeout) { engine.recordedBatches.count == 1 },
            "the walk parks on the first sentence"
        )
        #expect(job.activity == .running(ArchiveTranslationJobFixtures.makeStatus()))
        let runningActivity = job.activity
        let activityEmissions = ObservedValuesRecorder(read: { job.activity })

        gate.release()
        #expect(
            await pollUntil(timeout: resultTimeout) { job.runProgress?.processed == 1 },
            "the first sentence advances the progress"
        )
        await flushObservations()

        #expect(
            job.runProgress
                == ArchiveTranslationJobFixtures.makeRunProgress(kind: .google, processed: 1, total: 3)
        )
        #expect(job.activity == runningActivity, "the tick leaves the running status unchanged")
        #expect(activityEmissions.values.isEmpty, "the tick does not republish the activity")

        gate.release()
        gate.release()
        await run.value
    }

    @Test("a failed sentence advances the processed count exactly once")
    func failedSentenceAdvancesProcessedOnce() async {
        let job = makeJob()
        let gate = PermitGate()
        let engine = ScriptedArchiveEngine(gate: gate)
        engine.fail(on: ["s1"])
        job.resolveEngine = { _, _ in .ready(engine: engine, kind: .google) }
        job.land = { _, _ in true }

        #expect(job.claim(ArchiveTranslationJobFixtures.makeRequest(scope: .all)))
        let run = Task { await job.run() }

        #expect(
            await pollUntil(timeout: resultTimeout) { engine.recordedBatches.count == 1 },
            "the walk parks on the first sentence"
        )
        gate.release()
        #expect(await pollUntil(timeout: resultTimeout) { job.runProgress?.processed == 1 })

        gate.release()
        #expect(
            await pollUntil(timeout: resultTimeout) { job.runProgress?.processed == 2 },
            "the failed sentence still advances the progress"
        )
        #expect(
            job.runProgress
                == ArchiveTranslationJobFixtures.makeRunProgress(kind: .google, processed: 2, total: 3)
        )
        #expect(job.failureIndexes == [1], "the failure is reported separately from the progress")

        gate.release()
        await run.value

        #expect(job.lastRun?.processed == 3, "the final count includes the failure")
    }

    // MARK: - Finish

    @Test("the finish clears the running status and progress and keeps the final count")
    func finishClearsProgressAndKeepsFinalCount() async {
        let job = makeJob()
        let engine = ScriptedEngine()
        job.resolveEngine = { _, _ in .ready(engine: engine, kind: .google) }
        job.land = { _, _ in true }

        #expect(job.claim(ArchiveTranslationJobFixtures.makeRequest()))
        await job.run()

        let lastTick = ArchiveTranslationJobFixtures.makeRunProgress(kind: .google, processed: 3, total: 3)

        #expect(job.activity == .idle)
        #expect(job.runProgress == nil)
        #expect(job.lastRun?.processed == lastTick.processed, "the final count matches the last published tick")
    }

    // MARK: - Non-begun outcomes

    @Test("an empty scope ends idle with no run progress")
    func emptyScopeEndsIdleWithoutProgress() async {
        let job = makeJob()
        job.resolveEngine = { _, _ in .unavailable(reason: "unused") }

        #expect(job.claim(ArchiveTranslationJobFixtures.makeRequest(translated: [0, 1, 2])))
        await job.run()

        #expect(job.activity == .idle)
        #expect(job.runProgress == nil)
    }

    @Test("an unavailable resolution ends idle with no run progress")
    func unavailableResolutionEndsIdleWithoutProgress() async {
        let job = makeJob()
        job.resolveEngine = { _, _ in .unavailable(reason: "No engine attached.") }

        #expect(job.claim(ArchiveTranslationJobFixtures.makeRequest()))
        await job.run()

        #expect(job.activity == .idle)
        #expect(job.runProgress == nil)
    }

    @Test("a cancel during resolution ends idle with no run progress")
    func cancelDuringResolutionEndsIdleWithoutProgress() async {
        let job = makeJob()
        let gate = AsyncGate()
        let engine = ScriptedEngine()
        job.resolveEngine = { _, _ in
            await gate.wait()
            return .ready(engine: engine, kind: .google)
        }

        #expect(job.claim(ArchiveTranslationJobFixtures.makeRequest()))
        let run = Task { await job.run() }
        #expect(
            await pollUntil(timeout: resultTimeout) { gate.enteredCount == 1 },
            "the run parks in engine resolution"
        )

        job.cancel()
        gate.open()
        await run.value

        #expect(job.activity == .idle)
        #expect(job.runProgress == nil)
    }

    @Test("a cancel during the walk ends idle with no run progress")
    func cancelDuringWalkEndsIdleWithoutProgress() async {
        let job = makeJob()
        let engine = ScriptedEngine()
        job.resolveEngine = { _, _ in .ready(engine: engine, kind: .google) }
        let recorder = Recorder()
        recorder.cancelAfterLandings = 1
        recorder.cancel = { [weak job] in job?.cancel() }
        job.land = recorder.recordLanding

        #expect(job.claim(ArchiveTranslationJobFixtures.makeRequest()))
        await job.run()

        #expect(job.activity == .idle)
        #expect(job.runProgress == nil)
        #expect(job.lastRun?.processed == 1, "the cancel keeps the last published count")
    }

    @Test("a second run starts its progress at zero")
    func secondRunStartsProgressAtZero() async {
        let job = makeJob()
        let firstEngine = ScriptedEngine()
        job.resolveEngine = { _, _ in .ready(engine: firstEngine, kind: .google) }
        job.land = { _, _ in true }

        #expect(job.claim(ArchiveTranslationJobFixtures.makeRequest()))
        await job.run()
        #expect(job.runProgress == nil, "the first run clears its progress")

        let gate = AsyncGate()
        let secondEngine = ScriptedEngine(gate: gate)
        job.resolveEngine = { _, _ in .ready(engine: secondEngine, kind: .deepl) }
        let second = ArchiveTranslationJobFixtures.makeRequest(
            sentenceCount: 1, scope: .all, engine: .deepl, lang: "de"
        )

        #expect(job.claim(second))
        #expect(job.runProgress == nil, "the claim publishes no progress")

        let run = Task { await job.run() }
        #expect(
            await pollUntil(timeout: resultTimeout) { gate.enteredCount == 1 },
            "the second run parks in its first engine call"
        )
        #expect(
            job.activity
                == .running(ArchiveTranslationJobFixtures.makeStatus(lang: "de", engine: .deepl))
        )
        #expect(
            job.runProgress
                == ArchiveTranslationJobFixtures.makeRunProgress(kind: .deepl, processed: 0, total: 1)
        )

        gate.open()
        await run.value

        #expect(job.runProgress == nil)
    }
}
