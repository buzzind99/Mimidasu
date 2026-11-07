import Foundation
@testable import Mimidasu
import Testing

/// The scoped busy gate at the app-model seam: the delete refusal follows
/// the run's own session regardless of language and never touches a foreign
/// session, the landing sink and progress poster read the running status,
/// and the command guards only act while the job is claimed or running.
/// A parked resolution makes the claimed window observable; a permit-gated
/// engine parks the walk.
@MainActor
@Suite("AppModel archive run gates")
struct AppModelArchiveRunGateTests {

    private let resultTimeout: TimeInterval = 5

    // MARK: - Delete

    @Test("deleting the run's session is refused under any run language", arguments: ["fr", "de"])
    func deleteRefusedForTheRunSession(lang: String) async {
        let sut = await makeSUT()
        let gate = parkArchiveClaim(on: sut, lang: lang, resolution: .cancelled)
        #expect(sut.model.archiveTranslationRunning, "the run is claimed before the delete")
        let claimed = sut.model.archiveTranslationJob.activity.runStatus

        sut.model.deleteArchive(id: sut.id)

        #expect(sut.store.load(id: sut.id) != nil, "the run's session survives the refused delete")
        #expect(sut.model.pane.openArchive?.id == sut.id, "the pane stays on the run's session")
        #expect(sut.model.archiveTranslationJob.activity.runStatus == claimed, "the run stays claimed")

        gate.open()
        #expect(
            await pollUntil(timeout: resultTimeout) { !sut.model.archiveTranslationRunning },
            "the released resolution frees the slot"
        )
    }

    @Test("a foreign session's row reads idle while another session's run is claimed")
    func foreignRowStaysEnabled() async {
        let sut = await makeSUT()
        let otherID = appendArchive(to: sut.store)
        let gate = parkArchiveClaim(on: sut, lang: "de", resolution: .cancelled)

        #expect(
            sut.model.archiveTranslationJob.activity(for: otherID) == .idle,
            "the foreign row's activity is idle"
        )
        #expect(
            !sut.model.archiveTranslationJob.isBusy(sessionID: otherID, lang: nil),
            "the nil-language gate never widens to a foreign session"
        )
        #expect(
            !sut.model.archiveTranslationJob.isBusy(sessionID: otherID, lang: "de"),
            "the language-matched gate never widens to a foreign session"
        )
        #expect(
            sut.model.archiveTranslationJob.isBusy(sessionID: sut.id, lang: nil),
            "the run's own session stays gated"
        )
        #expect(
            sut.model.archiveTranslationJob.isBusy(sessionID: sut.id, lang: "de"),
            "the run's matching language stays gated"
        )
        #expect(
            !sut.model.archiveTranslationJob.isBusy(sessionID: sut.id, lang: "fr"),
            "a language the run never targets is not gated"
        )

        gate.open()
        #expect(
            await pollUntil(timeout: resultTimeout) { !sut.model.archiveTranslationRunning },
            "the released resolution frees the slot"
        )
    }

    @Test("a foreign session's delete stays enabled while another session's run is claimed")
    func foreignDeleteStaysEnabled() async {
        let sut = await makeSUT()
        let otherID = appendArchive(to: sut.store)
        let gate = parkArchiveClaim(on: sut, resolution: .cancelled)

        sut.model.deleteArchive(id: otherID)

        #expect(sut.store.load(id: otherID) == nil, "the foreign session is deleted")
        #expect(sut.model.pane.openArchive?.id == sut.id, "the run's pane is untouched")

        gate.open()
        #expect(
            await pollUntil(timeout: resultTimeout) { !sut.model.archiveTranslationRunning },
            "the released resolution frees the slot"
        )
    }

    // MARK: - Landing and progress

    @Test("the land sink writes through the running status's session")
    func landSinkUsesTheRunningStatusSession() async {
        let sut = await makeSUT()
        let otherID = appendArchive(to: sut.store, sentences: ["bonjour", "merci"])
        let gate = PermitGate()
        let engine = ScriptedArchiveEngine(gate: gate)
        install(engine, for: .google, on: sut.model)

        sut.model.beginArchiveTranslation(engine: .google, lang: "fr", sessionID: otherID)
        #expect(
            await pollUntil(timeout: resultTimeout) {
                sut.model.archiveTranslationJob.activity.isRunning
                    && engine.recordedBatches.count == 1
            },
            "the run walks the foreign session"
        )
        #expect(
            sut.model.archiveTranslationJob.activity.runStatus?.sessionID == otherID,
            "the running status names the run's session"
        )
        #expect(sut.model.pane.openArchive?.id == sut.id, "the pane shows the other session")

        gate.release()
        gate.release()
        #expect(
            await pollUntil(timeout: resultTimeout) { runFinished(sut.model, translated: 2) },
            "the run lands both sentences"
        )
        #expect(
            sut.store.load(id: otherID)?.entries.compactMap { entry in entry.translation(for: "fr")?.text }
                == ["T:bonjour", "T:merci"],
            "both landings persist under the running status's session"
        )
        #expect(
            sut.store.load(id: sut.id)?.entries.allSatisfy { entry in entry.translations.isEmpty } == true,
            "the open pane's session is never written"
        )
    }

    @Test("the progress poster names the running status's language and the resolved progress kind")
    func progressPosterUsesTheStatusLanguageAndProgressKind() async {
        let sut = await makeSUT()
        let gate = PermitGate()
        let engine = ScriptedArchiveEngine(gate: gate)
        sut.model.archiveTranslationJob.resolveEngine = { _, _ in
            .ready(engine: engine, kind: .deepl)
        }

        sut.model.beginArchiveTranslation(engine: .google, lang: "de")
        #expect(
            await pollUntil(timeout: resultTimeout) {
                archiveToast(sut.model)?.progress != nil && engine.recordedBatches.count == 1
            },
            "the started event posts the progress card"
        )
        #expect(
            sut.model.archiveTranslationJob.runProgress
                == ArchiveTranslationJobFixtures.makeRunProgress(kind: .deepl, processed: 0, total: 3),
            "the card reads the separate progress value"
        )
        let toast = archiveToast(sut.model)
        #expect(toast?.title == "Translating to Deutsch…", "the title reads the status's language")
        #expect(toast?.body == "DeepL · 0/3 sentences", "the body reads the resolved progress kind")

        gate.release()
        gate.release()
        gate.release()
        #expect(
            await pollUntil(timeout: resultTimeout) { runFinished(sut.model, translated: 3) },
            "the run drains"
        )
    }
}

extension AppModelArchiveRunGateTests {

    // MARK: - Request guard

    @Test("a picker request is refused while the job is claimed")
    func requestRefusedWhileClaimed() async {
        let sut = await makeSUT()
        let otherID = appendArchive(to: sut.store)
        let gate = parkArchiveClaim(on: sut, resolution: .cancelled)
        let claimed = sut.model.archiveTranslationJob.activity.runStatus

        sut.model.requestArchiveTranslation(
            engine: .google, lang: "de", sessionID: otherID, presenter: .archiveWindow
        )

        #expect(sut.model.providerAwaitingDisclosure == nil, "the refused request stages nothing")
        #expect(sut.model.archiveTranslationJob.activity.runStatus == claimed, "the claimed run is untouched")

        gate.open()
        #expect(
            await pollUntil(timeout: resultTimeout) { !sut.model.archiveTranslationRunning },
            "the released resolution frees the slot"
        )
    }

    @Test("a picker request is refused while the job runs")
    func requestRefusedWhileRunning() async {
        let sut = await makeSUT()
        let otherID = appendArchive(to: sut.store)
        let gate = PermitGate()
        let engine = ScriptedArchiveEngine(gate: gate)
        install(engine, for: .google, on: sut.model)

        sut.model.beginArchiveTranslation(engine: .google, lang: "fr")
        #expect(
            await pollUntil(timeout: resultTimeout) {
                sut.model.archiveTranslationJob.activity.isRunning && engine.recordedBatches.count == 1
            },
            "the run claims the slot and parks mid-walk"
        )
        let running = sut.model.archiveTranslationJob.activity.runStatus

        sut.model.requestArchiveTranslation(
            engine: .google, lang: "de", sessionID: otherID, presenter: .archiveWindow
        )

        #expect(sut.model.providerAwaitingDisclosure == nil, "the refused request stages nothing")
        #expect(sut.model.archiveTranslationJob.activity.runStatus == running, "the running run is untouched")

        gate.release()
        gate.release()
        gate.release()
        #expect(
            await pollUntil(timeout: resultTimeout) { runFinished(sut.model, translated: 3) },
            "the run drains on its own"
        )
    }

    // MARK: - Retry guard

    @Test("retry-failed is refused while the job is claimed")
    func retryRefusedWhileClaimed() async throws {
        let sut = await makeSUT()
        let engine = ScriptedArchiveEngine()
        engine.fail(on: ["さようなら"])
        install(engine, for: .google, on: sut.model)
        sut.model.beginArchiveTranslation(engine: .google, lang: "fr")
        #expect(
            await pollUntil(timeout: resultTimeout) {
                sut.model.archiveTranslationJob.failureIndexes == [1]
                    && !sut.model.archiveTranslationRunning
            },
            "the first run leaves one retryable failure"
        )
        let failedRun = sut.model.archiveTranslationJob.lastRun
        let batches = engine.recordedBatches.count
        try #require(
            sut.model.archiveTranslationJob.claim(
                ArchiveTranslationJobFixtures.makeRequest(sessionID: sut.id)
            )
        )
        let claimed = sut.model.archiveTranslationJob.activity.runStatus

        sut.model.retryFailedArchiveTranslation()

        #expect(sut.model.archiveTranslationJob.lastRun == failedRun, "the retry never replaces the failed run")
        #expect(sut.model.archiveTranslationJob.activity.runStatus == claimed, "the direct claim survives")
        #expect(engine.recordedBatches.count == batches, "no retry flight starts")

        sut.model.archiveTranslationJob.resolveEngine = { _, _ in .cancelled }
        await sut.model.archiveTranslationJob.run()
    }

    @Test("retry-failed is refused while the job runs")
    func retryRefusedWhileRunning() async {
        let sut = await makeSUT()
        let gate = PermitGate()
        let engine = ScriptedArchiveEngine(gate: gate)
        engine.fail(on: ["こんにちは"])
        install(engine, for: .google, on: sut.model)
        gate.release()

        sut.model.beginArchiveTranslation(engine: .google, lang: "fr")
        #expect(
            await pollUntil(timeout: resultTimeout) {
                sut.model.archiveTranslationJob.failureIndexes == [0]
                    && engine.recordedBatches.count == 2
            },
            "the run records a failure and parks on the next sentence"
        )
        let lastRun = sut.model.archiveTranslationJob.lastRun
        let batches = engine.recordedBatches.count
        let running = sut.model.archiveTranslationJob.activity.runStatus

        sut.model.retryFailedArchiveTranslation()

        #expect(sut.model.archiveTranslationJob.lastRun == lastRun, "the retry never rebuilds a run mid-walk")
        #expect(sut.model.archiveTranslationJob.activity.runStatus == running, "the live run keeps its status")
        #expect(engine.recordedBatches.count == batches, "no retry flight starts")

        gate.release()
        gate.release()
        #expect(
            await pollUntil(timeout: resultTimeout) { runFinished(sut.model, translated: 2) },
            "the released run finishes its remaining sentences"
        )
    }

    // MARK: - Cancel guard

    @Test("cancel at idle leaves the job uncancelled")
    func cancelAtIdleLeavesJobUncancelled() async {
        let sut = await makeSUT()

        sut.model.cancelArchiveTranslation()

        #expect(
            !sut.model.archiveTranslationJob.isCancelled,
            "the idle guard never trips the next run's abort flag"
        )
    }

    @Test("cancel while claimed trips the run and releases the claim")
    func cancelWhileClaimedTripsTheRun() async {
        let sut = await makeSUT()
        let engine = ScriptedArchiveEngine()
        let gate = parkArchiveClaim(on: sut, resolution: .ready(engine: engine, kind: .google))
        #expect(sut.model.archiveTranslationRunning, "the run is claimed")

        sut.model.cancelArchiveTranslation()

        #expect(sut.model.archiveTranslationJob.isCancelled, "the cancel reaches the claimed run")

        gate.open()
        #expect(
            await pollUntil(timeout: resultTimeout) { !sut.model.archiveTranslationRunning },
            "the cancelled resolution releases the claim"
        )
        #expect(sut.model.archiveTranslationJob.lastRun == nil, "the cancel prevents the walk from beginning")
    }

    // MARK: - Running flag across non-begun outcomes

    @Test("archiveTranslationRunning is true from the synchronous claim")
    func runningTrueFromTheSynchronousClaim() async {
        let sut = await makeSUT()
        let gate = parkArchiveClaim(on: sut, resolution: .cancelled)

        #expect(sut.model.archiveTranslationRunning, "the claim is visible before any resolution")
        #expect(
            sut.model.archiveTranslationJob.activity.runStatus
                == ArchiveTranslationJobFixtures.makeStatus(
                    sessionID: sut.id, lang: "fr", engine: .google
                ),
            "the claimed status carries the run's identity"
        )

        gate.open()
        #expect(
            await pollUntil(timeout: resultTimeout) { !sut.model.archiveTranslationRunning },
            "the released resolution frees the slot"
        )
    }

    @Test("archiveTranslationRunning is false after an empty-scope run")
    func runningFalseAfterEmptyScope() async throws {
        let sut = await makeSUT()
        let job = sut.model.archiveTranslationJob
        try #require(
            job.claim(
                ArchiveTranslationJobFixtures.makeRequest(
                    translated: [0, 1, 2], sessionID: sut.id
                )
            )
        )
        #expect(sut.model.archiveTranslationRunning, "the claim is visible synchronously")

        await job.run()

        #expect(!sut.model.archiveTranslationRunning, "the empty scope releases the gate")
        #expect(job.activity == .idle)
    }

    @Test("archiveTranslationRunning is false after an unavailable resolution")
    func runningFalseAfterUnavailableResolution() async throws {
        let sut = await makeSUT()
        let job = sut.model.archiveTranslationJob
        job.resolveEngine = { _, _ in .unavailable(reason: "no engine for this test") }
        try #require(job.claim(ArchiveTranslationJobFixtures.makeRequest(sessionID: sut.id)))
        #expect(sut.model.archiveTranslationRunning, "the claim is visible synchronously")

        await job.run()

        #expect(!sut.model.archiveTranslationRunning, "the unavailable report releases the gate")
        #expect(job.activity == .idle)
    }

    @Test("archiveTranslationRunning is false after a cancelled resolution")
    func runningFalseAfterCancelledResolution() async throws {
        let sut = await makeSUT()
        let job = sut.model.archiveTranslationJob
        job.resolveEngine = { _, _ in .cancelled }
        try #require(job.claim(ArchiveTranslationJobFixtures.makeRequest(sessionID: sut.id)))
        #expect(sut.model.archiveTranslationRunning, "the claim is visible synchronously")

        await job.run()

        #expect(!sut.model.archiveTranslationRunning, "the cancelled resolution releases the gate")
        #expect(job.activity == .idle)
    }
}

/// Parks the open archive's run at engine resolution so the claimed window
/// is observable, then releases into `resolution` when the returned gate
/// opens.
@MainActor
private func parkArchiveClaim(
    on sut: ArchiveTranslationSUT,
    lang: String = "fr",
    resolution: ArchiveTranslationJob.EngineResolution
) -> AsyncGate {
    let gate = AsyncGate()
    sut.model.archiveTranslationJob.resolveEngine = { _, _ in
        await gate.wait()
        return resolution
    }
    sut.model.beginArchiveTranslation(engine: .google, lang: lang)
    return gate
}
