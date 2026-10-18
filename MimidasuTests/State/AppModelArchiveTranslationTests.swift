import Foundation
@testable import Mimidasu
import Synchronization
import Testing

/// Tests `AppModel`'s bulk archive-translation surface over a seeded
/// in-temp store: the fill-missing run and its write-back, the progress
/// card that morphs into the run's summary, the failure summary's retry,
/// the cloud disclosure confirm/decline, the pre-armed Apple session, the
/// close-time cancel, the one-job-at-a-time refusal, and the
/// unavailable-engine report. Scripted engine doubles make every run
/// deterministic; a permit gate parks runs mid-sentence. The store-backed
/// runs (lost writes, complete-language re-runs, count reads) live in the
/// sibling suite.
@MainActor
@Suite("AppModelArchiveTranslation")
struct AppModelArchiveTranslationTests {

    private let resultTimeout: TimeInterval = 5

    // MARK: - Fixtures

    /// The three rows a full `fr` run of the default fixture lands, in
    /// sentence order.
    private var expectedFRLandings: [[SentenceTranslation]] {
        [
            [SentenceTranslation(lang: "fr", text: "T:こんにちは", engine: .google)],
            [SentenceTranslation(lang: "fr", text: "T:さようなら", engine: .google)],
            [SentenceTranslation(lang: "fr", text: "T:おはよう", engine: .google)]
        ]
    }

    // MARK: - Filling missing sentences

    @Test("an external start fills every missing sentence and writes each landing back")
    func externalStartFillsEveryMissingSentence() async {
        let sut = await makeSUT()
        let engine = ScriptedArchiveEngine()
        install(engine, for: .google, on: sut.model)

        sut.model.beginArchiveTranslation(engine: .google, lang: "fr")

        #expect(
            await pollUntil(timeout: resultTimeout) { runFinished(sut.model, translated: 3) },
            "the run fills every missing sentence"
        )
        #expect(engine.recordedBatches == [["こんにちは"], ["さようなら"], ["おはよう"]])
        #expect(
            sut.model.entries.map { entry in entry.translations } == expectedFRLandings,
            "the pane rows carry the new translations"
        )
        #expect(
            sut.model.openArchive?.summary.languageCount(for: "fr")
                == ArchiveLanguageCount(lang: "fr", translated: 3),
            "the banner's language count refreshes in place"
        )

        // Durable: the store is the home of every landing.
        #expect(
            sut.model.archive.load(id: sut.id)?.entries.map { entry in entry.translations }
                == expectedFRLandings,
            "every landing is written back with its engine kind stamp"
        )

        // And a reopen reads the write-back out of the store.
        sut.model.closeArchive()
        sut.model.openArchiveSession(id: sut.id)
        #expect(
            sut.model.entries.compactMap { entry in entry.translation(for: "fr")?.text }
                == ["T:こんにちは", "T:さようなら", "T:おはよう"]
        )
    }

    // MARK: - Progress card

    @Test("the progress card advances in place and morphs into the all-success summary")
    func progressCardMorphsIntoSummary() async {
        let sut = await makeSUT()
        let gate = PermitGate()
        let engine = ScriptedArchiveEngine(gate: gate)
        install(engine, for: .google, on: sut.model)

        sut.model.beginArchiveTranslation(engine: .google, lang: "fr")
        #expect(
            await pollUntil(timeout: resultTimeout) { archiveToast(sut.model)?.progress != nil },
            "the started event posts the progress card"
        )

        let started = archiveToast(sut.model)
        #expect(started?.style == .info)
        #expect(started?.title == "Translating to Français…")
        #expect(started?.body == "Google Translate · 0/3 sentences")
        #expect(started?.action?.label == "Cancel")
        let cardID = started?.id

        gate.release()
        #expect(
            await pollUntil(timeout: resultTimeout) {
                archiveToast(sut.model)?.progress == ToastCenter.ToastProgress(done: 1, total: 3)
            },
            "the first landing advances the bar in place"
        )
        let advanced = archiveToast(sut.model)
        #expect(advanced?.body == "Google Translate · 1/3 sentences")
        #expect(advanced?.id == cardID, "a keyed re-post keeps the card's identity")

        gate.release()
        gate.release()
        #expect(
            await pollUntil(timeout: resultTimeout) {
                archiveToast(sut.model)?.title == "Archive translation finished"
            },
            "the same key holds the run's summary"
        )
        let summary = archiveToast(sut.model)
        #expect(summary?.body == "Translated 3 sentences to Français")
        #expect(summary?.progress == nil)
        #expect(summary?.action == nil, "the all-success summary carries no action")
        #expect(summary?.autoDismisses == true, "the plain summary auto-dismisses")
        #expect(summary?.id == cardID, "the summary replaced the progress card in place")
    }

    // MARK: - Failures

    @Test("the failure summary's retry re-runs exactly the failed sentence without a disclosure")
    func failureSummaryRetryRerunsFailedSentence() async {
        let sut = await makeSUT()
        let engine = ScriptedArchiveEngine()
        engine.fail(on: ["さようなら"])
        install(engine, for: .google, on: sut.model)

        sut.model.beginArchiveTranslation(engine: .google, lang: "fr")
        #expect(
            await pollUntil(timeout: resultTimeout) {
                archiveToast(sut.model)?.title == "Archive translation finished"
                    && !sut.model.archiveTranslationRunning
            },
            "the failure summary lands"
        )

        let summary = archiveToast(sut.model)
        #expect(summary?.body == "2/3 translated to Français · 1 failed")
        #expect(summary?.action?.label == "Retry failed sentences")
        #expect(summary?.autoDismisses == false, "the failure summary waits for its retry")

        // A deliberate held intent survives the retry: the retry neither
        // re-raises the disclosure nor clears what is staged for another
        // sheet.
        sut.model.providerAwaitingDisclosure = .retranslateEngine(.deepl)
        engine.clearFailures()
        summary?.action?.handler()

        #expect(
            await pollUntil(timeout: resultTimeout) {
                archiveToast(sut.model)?.body == "Translated 1 sentence to Français"
                    && !sut.model.archiveTranslationRunning
            },
            "the retry lands the previously failed sentence"
        )
        #expect(
            engine.recordedBatches == [["こんにちは"], ["さようなら"], ["おはよう"], ["さようなら"]],
            "the second run sends exactly the failed index"
        )
        #expect(
            sut.model.entries.allSatisfy { entry in entry.translation(for: "fr") != nil },
            "every row now carries a translation"
        )
        #expect(
            sut.model.providerAwaitingDisclosure == .retranslateEngine(.deepl),
            "the retry leaves the held disclosure intent untouched"
        )
    }

    @Test("a retry after the archive swapped is refused")
    func retryAfterArchiveSwapIsRefused() async {
        let sut = await makeSUT()
        let engine = ScriptedArchiveEngine()
        engine.fail(on: ["さようなら"])
        install(engine, for: .google, on: sut.model)

        sut.model.beginArchiveTranslation(engine: .google, lang: "fr")
        #expect(
            await pollUntil(timeout: resultTimeout) {
                !sut.model.archiveTranslationRunning
                    && sut.model.archiveTranslationJob.failureIndexes == [1]
            },
            "the run finishes with one failure"
        )
        let batches = engine.recordedBatches.count

        let otherID = appendArchive(to: sut.store)
        sut.model.openArchiveSession(id: otherID)
        #expect(sut.model.openArchive?.id == otherID, "the other archive is open")

        sut.model.retryFailedArchiveTranslation()

        #expect(sut.model.archiveTranslationJob.activity == .idle, "the cross-archive retry is refused")
        #expect(engine.recordedBatches.count == batches, "no new engine batch is sent")
        #expect(
            sut.store.load(id: otherID)?.entries.allSatisfy { entry in entry.translations.isEmpty } == true,
            "the swapped-in archive is never modified"
        )
    }

    @Test("closing and reopening clears a finished run's failure card")
    func closingAndReopeningClearsFailureCard() async {
        let sut = await makeSUT()
        let engine = ScriptedArchiveEngine()
        engine.fail(on: ["さようなら"])
        install(engine, for: .google, on: sut.model)

        sut.model.beginArchiveTranslation(engine: .google, lang: "fr")
        #expect(
            await pollUntil(timeout: resultTimeout) {
                archiveToast(sut.model)?.title == "Archive translation finished"
                    && !sut.model.archiveTranslationRunning
            },
            "the failure summary lands"
        )
        #expect(archiveToast(sut.model)?.action != nil, "the failure card is up and waits")

        sut.model.closeArchive()

        #expect(archiveToast(sut.model) == nil, "the card dismisses with the close even though the run had finished")

        sut.model.openArchiveSession(id: sut.id)

        #expect(archiveToast(sut.model) == nil, "the failure card never resurrects on reopen")
    }
}

/// The cloud-disclosure, cancel-surface, unavailable-engine, lost-write,
/// and completeness cases of the suite, split from the main declaration at
/// the type-body-length gate.
extension AppModelArchiveTranslationTests {

    // MARK: - Cloud disclosure

    @Test("confirming the archive-translation disclosure starts the run")
    func confirmStartsTheRun() async {
        let sut = await makeSUT()
        let engine = ScriptedArchiveEngine()
        install(engine, for: .deepl, on: sut.model)
        sut.model.providerAwaitingDisclosure = .archiveTranslation(.deepl, lang: "fr")

        sut.model.confirmCloudDisclosure(.archiveTranslation(.deepl, lang: "fr"))

        #expect(sut.model.providerAwaitingDisclosure == nil, "the confirm clears the slot")
        #expect(
            await pollUntil(timeout: resultTimeout) { runFinished(sut.model, translated: 3) },
            "the confirmed pick flies the run"
        )
        #expect(sut.model.archiveTranslationJob.lastRun?.request.engine == .deepl)
        #expect(sut.model.archiveTranslationJob.lastRun?.kind == .deepl)
        #expect(
            sut.model.entries.first?.translation(for: "fr")
                == SentenceTranslation(lang: "fr", text: "T:こんにちは", engine: .deepl)
        )
    }

    @Test("a stale confirm leaves the staged intent and starts nothing")
    func staleConfirmStartsNothing() async {
        let sut = await makeSUT()
        sut.model.providerAwaitingDisclosure = .archiveTranslation(.deepl, lang: "fr")

        sut.model.confirmCloudDisclosure(.archiveTranslation(.google, lang: "fr"))

        #expect(
            sut.model.providerAwaitingDisclosure == .archiveTranslation(.deepl, lang: "fr"),
            "the staged intent stays for its own sheet"
        )
        #expect(!sut.model.archiveTranslationRunning)
        #expect(sut.model.archiveTranslationJob.lastRun == nil)
        #expect(sut.model.archive.load(id: sut.id)?.entries.allSatisfy { entry in entry.translations.isEmpty } == true)
    }

    @Test("declining the archive-translation disclosure starts nothing")
    func declineStartsNothing() async {
        let sut = await makeSUT()
        let engine = ScriptedArchiveEngine()
        install(engine, for: .deepl, on: sut.model)
        sut.model.providerAwaitingDisclosure = .archiveTranslation(.deepl, lang: "fr")

        sut.model.declineCloudDisclosure()

        #expect(sut.model.providerAwaitingDisclosure == nil)
        #expect(!sut.model.archiveTranslationRunning)
        #expect(sut.model.archiveTranslationJob.lastRun == nil)
        #expect(engine.recordedBatches.isEmpty, "the declined pick never reaches an engine")
    }

    // MARK: - Apple route

    @Test("an Apple start flies the pre-armed dedicated session and stamps fast")
    func appleStartUsesArmedSession() async {
        let sut = await makeSUT()
        let engine = ScriptedArchiveEngine()
        // The host's hand-over precedes the start, so the run acquires the
        // stored session instead of waiting out an arm window.
        sut.model.retranslate.armRetranslateSessionIfNeeded(for: .appleFast, target: "fr")
        sut.model.retranslateSessionArrived(engine)
        #expect(sut.model.retranslateSessionEngine != nil, "the hand-over stores the session")

        sut.model.beginArchiveTranslation(engine: .appleFast, lang: "fr")

        #expect(
            await pollUntil(timeout: resultTimeout) { runFinished(sut.model, translated: 3) },
            "the armed session serves the whole run"
        )
        #expect(sut.model.archiveTranslationJob.lastRun?.kind == .appleFast)
        #expect(
            sut.model.entries.compactMap { entry in entry.translation(for: "fr")?.engine }
                == [.appleFast, .appleFast, .appleFast],
            "every landed row is stamped fast"
        )
    }

    // MARK: - Cancel

    @Test("closing the archive cancels the run and keeps the landed partial rows")
    func closeCancelsAndKeepsPartialRows() async {
        let sut = await makeSUT()
        let gate = PermitGate()
        let engine = ScriptedArchiveEngine(gate: gate)
        install(engine, for: .google, on: sut.model)

        sut.model.beginArchiveTranslation(engine: .google, lang: "fr")
        #expect(
            await pollUntil(timeout: resultTimeout) {
                sut.model.archiveTranslationRunning && engine.recordedBatches.count == 1
            },
            "the run starts and parks on its first sentence"
        )

        sut.model.closeArchive()

        #expect(archiveToast(sut.model) == nil, "the card clears with the cancel")
        gate.release()
        #expect(await pollUntil(timeout: resultTimeout) { !sut.model.archiveTranslationRunning }, "the released run winds down")
        #expect(engine.recordedBatches == [["こんにちは"]], "no new sentence starts after the cancel")
        #expect(
            sut.store.load(id: sut.id)?.entries.first?.translations
                == [SentenceTranslation(lang: "fr", text: "T:こんにちは", engine: .google)],
            "the airborne result still persists"
        )
        #expect(
            !sut.model.toasts.toasts.contains { toast in toast.title == "Archive translation finished" },
            "a canceled run posts no summary"
        )
    }

    @Test("an open swap cancels the airborne run and its result persists under the original id")
    func openSwapCancelsAndAirborneResultPersists() async {
        let sut = await makeSUT()
        let gate = PermitGate()
        let engine = ScriptedArchiveEngine(gate: gate)
        install(engine, for: .google, on: sut.model)

        sut.model.beginArchiveTranslation(engine: .google, lang: "fr")
        #expect(
            await pollUntil(timeout: resultTimeout) {
                sut.model.archiveTranslationRunning && engine.recordedBatches.count == 1
            },
            "the run starts and parks on its first sentence"
        )

        let otherID = appendArchive(to: sut.store)
        sut.model.openArchiveSession(id: otherID)

        #expect(sut.model.openArchive?.id == otherID, "the swap opened the other archive")
        #expect(archiveToast(sut.model) == nil, "the card clears with the swap")
        gate.release()
        #expect(
            await pollUntil(timeout: resultTimeout) { !sut.model.archiveTranslationRunning },
            "the released run winds down"
        )
        #expect(engine.recordedBatches.count == 1, "no new sentence starts after the swap")
        #expect(
            sut.store.load(id: sut.id)?.entries.first?.translations
                == [SentenceTranslation(lang: "fr", text: "T:こんにちは", engine: .google)],
            "the airborne result still persists under its own archive's id"
        )
        #expect(
            sut.store.load(id: otherID)?.entries.allSatisfy { entry in entry.translations.isEmpty } == true,
            "the newly opened archive is untouched"
        )
    }

    @Test("the progress card's Cancel action stops the run and keeps the partial rows")
    func toastCancelActionStopsRun() async {
        let sut = await makeSUT()
        let gate = PermitGate()
        let engine = ScriptedArchiveEngine(gate: gate)
        install(engine, for: .google, on: sut.model)

        sut.model.beginArchiveTranslation(engine: .google, lang: "fr")
        #expect(
            await pollUntil(timeout: resultTimeout) {
                sut.model.archiveTranslationRunning && engine.recordedBatches.count == 1
            },
            "the run starts and parks on its first sentence"
        )
        #expect(archiveToast(sut.model)?.action != nil, "the progress card carries the Cancel action")

        archiveToast(sut.model)?.action?.handler()

        #expect(archiveToast(sut.model) == nil, "the cancel dismisses the card")
        gate.release()
        #expect(
            await pollUntil(timeout: resultTimeout) { !sut.model.archiveTranslationRunning },
            "the released run winds down"
        )
        #expect(engine.recordedBatches.count == 1, "no sentence starts after the cancel")
        #expect(
            sut.store.load(id: sut.id)?.entries.first?.translations
                == [SentenceTranslation(lang: "fr", text: "T:こんにちは", engine: .google)],
            "the airborne result still persists"
        )
    }

    @Test("deleting the open archive cancels the run")
    func deletingOpenArchiveCancelsRun() async {
        let sut = await makeSUT()
        let gate = PermitGate()
        let engine = ScriptedArchiveEngine(gate: gate)
        install(engine, for: .google, on: sut.model)

        sut.model.beginArchiveTranslation(engine: .google, lang: "fr")
        #expect(
            await pollUntil(timeout: resultTimeout) {
                sut.model.archiveTranslationRunning && engine.recordedBatches.count == 1
            },
            "the run starts and parks on its first sentence"
        )

        sut.model.deleteArchive(id: sut.id)

        #expect(archiveToast(sut.model) == nil, "the card clears with the delete")
        #expect(sut.model.openArchive == nil, "the open archive is gone")
        gate.release()
        #expect(
            await pollUntil(timeout: resultTimeout) { !sut.model.archiveTranslationRunning },
            "the released run winds down"
        )
        #expect(engine.recordedBatches.count == 1, "no sentence starts after the delete")
        #expect(
            !sut.model.toasts.toasts.contains { toast in toast.title == "Archive translation finished" },
            "the deleted archive's run posts no summary"
        )
        #expect(
            !sut.model.toasts.toasts.contains { toast in toast.key == ToastKey.archiveUnavailable },
            "the canceled run's failed write never posts the archive warning"
        )
    }

    // MARK: - One job at a time

    @Test("a claimed run keeps a second start and the per-row lane out")
    func claimedRunRefusesSecondStartAndLane() async {
        let sut = await makeSUT()
        let gate = PermitGate()
        let engine = ScriptedArchiveEngine(gate: gate)
        install(engine, for: .google, on: sut.model)

        sut.model.beginArchiveTranslation(engine: .google, lang: "fr")
        #expect(
            await pollUntil(timeout: resultTimeout) {
                sut.model.archiveTranslationRunning && engine.recordedBatches.count == 1
            },
            "the run claims the slot and parks"
        )
        let claimed = sut.model.archiveTranslationJob.activity.request

        sut.model.beginArchiveTranslation(engine: .google, lang: "fr")
        sut.model.retranslateSentence(sut.model.entries[1].sentence)

        #expect(sut.model.archiveTranslationJob.activity.request == claimed, "the second start is refused")
        #expect(engine.recordedBatches == [["こんにちは"]], "only the claimed run's flight is airborne")
        #expect(sut.model.pendingRetranslations.isEmpty, "the per-row lane never takes a marker")
        #expect(retranslateToast(sut.model) == nil, "the per-row lane never reports")

        gate.release()
        gate.release()
        gate.release()
        #expect(
            await pollUntil(timeout: resultTimeout) { runFinished(sut.model, translated: 3) },
            "the claimed run finishes alone"
        )
    }

    // MARK: - Claim window

    @Test("the claim window reads running from the click, before any resolution")
    func claimWindowReadsRunningFromTheClick() async {
        let sut = await makeSUT()
        let engine = ScriptedArchiveEngine()
        install(engine, for: .google, on: sut.model)

        sut.model.beginArchiveTranslation(engine: .google, lang: "fr")

        #expect(sut.model.archiveTranslationRunning, "the claimed run is visible from the click")

        #expect(
            await pollUntil(timeout: resultTimeout) { runFinished(sut.model, translated: 3) },
            "the claimed run drains to completion"
        )
    }

    // MARK: - Unavailable engine

    @Test("an external start with no engine reports unavailable and starts nothing")
    func unavailableEngineReportsAndStartsNothing() async {
        let sut = await makeSUT()
        sut.model.retranslateEngineFactory = { _, _ in nil }

        sut.model.beginArchiveTranslation(engine: .google, lang: "fr")

        #expect(
            await pollUntil(timeout: resultTimeout) { archiveToast(sut.model) != nil },
            "the unavailable report lands"
        )
        let toast = archiveToast(sut.model)
        #expect(toast?.style == .yellowAuto)
        #expect(toast?.title == "Archive translation unavailable", "the run's own copy, not the retry key's")
        #expect(toast?.body == "No API key stored for Google Translate.")
        #expect(toast?.progress == nil, "no progress card is ever posted")
        #expect(retranslateToast(sut.model) == nil, "the per-row lane's key is untouched")
        #expect(!sut.model.archiveTranslationRunning, "the claim releases with the report")
        #expect(sut.model.archive.load(id: sut.id)?.entries.allSatisfy { entry in entry.translations.isEmpty } == true)
    }
}
