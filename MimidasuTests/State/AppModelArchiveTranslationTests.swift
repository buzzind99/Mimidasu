import Foundation
@testable import Mimidasu
import Synchronization
import Testing

/// Tests `AppModel`'s bulk archive-translation surface over a seeded
/// in-temp store: the fill-missing run and its write-back, the progress
/// card that morphs into the run's summary, the failure summary's retry
/// (including one begun after its archive left the pane), the cloud
/// disclosure confirm/decline, the pre-armed Apple session, the run and
/// card that survive archive boundaries, the one-job-at-a-time refusal,
/// and the unavailable-engine report. Scripted engine doubles make every
/// run deterministic; a permit gate parks runs mid-sentence. The
/// store-backed runs (lost writes, complete-language re-runs, count reads)
/// live in the sibling suite.
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

    @Test("a retry after the archive swapped re-runs the failed sentence in its own archive")
    func retryAfterArchiveSwapRunsAgainstItsOwnArchive() async {
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

        let otherID = appendArchive(to: sut.store)
        sut.model.openArchiveSession(id: otherID)
        #expect(sut.model.openArchive?.id == otherID, "the other archive is open")

        engine.clearFailures()
        sut.model.retryFailedArchiveTranslation()

        #expect(
            await pollUntil(timeout: resultTimeout) {
                archiveToast(sut.model)?.body == "Translated 1 sentence to Français"
                    && !sut.model.archiveTranslationRunning
            },
            "the retry lands the failed sentence with another archive open"
        )
        #expect(
            engine.recordedBatches == [["こんにちは"], ["さようなら"], ["おはよう"], ["さようなら"]],
            "the retry sends exactly the failed index"
        )
        #expect(
            sut.model.archiveTranslationJob.lastRun?.request.sessionID == sut.id,
            "the retry stays on the original run's archive"
        )
        #expect(
            sut.store.load(id: sut.id)?.entries.allSatisfy { entry in entry.translation(for: "fr") != nil } == true,
            "the original archive now carries every translation"
        )
        #expect(
            sut.store.load(id: otherID)?.entries.allSatisfy { entry in entry.translations.isEmpty } == true,
            "the swapped-in archive is never modified"
        )
    }

    @Test("a failure card survives close and reopen, and retries from another open session")
    func failureCardSurvivesCloseAndRetriesFromAnotherOpenSession() async {
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
        let failureCard = archiveToast(sut.model)
        #expect(failureCard?.action != nil, "the failure card is up and waits")

        sut.model.closeArchive()

        #expect(
            archiveToast(sut.model)?.id == failureCard?.id,
            "the card stays up with the archive closed"
        )

        sut.model.openArchiveSession(id: sut.id)

        #expect(
            archiveToast(sut.model)?.id == failureCard?.id,
            "the card stays up when the run's archive reopens"
        )

        let otherID = appendArchive(to: sut.store)
        sut.model.openArchiveSession(id: otherID)
        #expect(
            archiveToast(sut.model)?.id == failureCard?.id,
            "the card stays up while another session is open"
        )

        engine.clearFailures()
        archiveToast(sut.model)?.action?.handler()

        #expect(
            await pollUntil(timeout: resultTimeout) {
                archiveToast(sut.model)?.body == "Translated 1 sentence to Français"
                    && !sut.model.archiveTranslationRunning
            },
            "the retry from another open session lands the failed sentence"
        )
        #expect(
            sut.store.load(id: sut.id)?.entries.allSatisfy { entry in entry.translation(for: "fr") != nil } == true,
            "the retry lands into the run's own archive"
        )
        #expect(
            sut.store.load(id: otherID)?.entries.allSatisfy { entry in entry.translations.isEmpty } == true,
            "the open session is never modified"
        )
    }
}

/// The boundary-and-cancel, unavailable-engine, lost-write, and
/// completeness cases of the suite, split from the main declaration at the
/// type-body-length gate.
extension AppModelArchiveTranslationTests {

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

    // MARK: - Archive boundaries and cancel

    @Test("closing the archive keeps the run and its card, and the walk completes")
    func closeKeepsTheRunAndItsCard() async {
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
        let cardID = archiveToast(sut.model)?.id
        #expect(cardID != nil, "the started event posts the progress card")

        sut.model.closeArchive()

        #expect(sut.model.archiveTranslationRunning, "the close keeps the run claimed")
        #expect(archiveToast(sut.model)?.id == cardID, "the card stays with the run")
        gate.release()
        gate.release()
        gate.release()
        #expect(
            await pollUntil(timeout: resultTimeout) {
                archiveToast(sut.model)?.title == "Archive translation finished"
                    && !sut.model.archiveTranslationRunning
            },
            "the released run walks every sentence"
        )
        #expect(
            engine.recordedBatches == [["こんにちは"], ["さようなら"], ["おはよう"]],
            "every sentence is still sent after the close"
        )
        #expect(
            sut.store.load(id: sut.id)?.entries.map { entry in entry.translations } == expectedFRLandings,
            "every landing persists under its own archive's id"
        )
    }

    @Test("an open swap keeps the run and its card, and lands under the original id")
    func openSwapKeepsTheRunAndItsCard() async {
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
        let cardID = archiveToast(sut.model)?.id
        #expect(cardID != nil, "the started event posts the progress card")

        let otherID = appendArchive(to: sut.store)
        sut.model.openArchiveSession(id: otherID)

        #expect(sut.model.openArchive?.id == otherID, "the swap opened the other archive")
        #expect(sut.model.archiveTranslationRunning, "the swap keeps the run claimed")
        #expect(archiveToast(sut.model)?.id == cardID, "the card stays with the run")
        gate.release()
        gate.release()
        gate.release()
        #expect(
            await pollUntil(timeout: resultTimeout) {
                archiveToast(sut.model)?.title == "Archive translation finished"
                    && !sut.model.archiveTranslationRunning
            },
            "the released run walks every sentence"
        )
        #expect(
            engine.recordedBatches == [["こんにちは"], ["さようなら"], ["おはよう"]],
            "every sentence is still sent after the swap"
        )
        #expect(
            sut.store.load(id: sut.id)?.entries.map { entry in entry.translations } == expectedFRLandings,
            "every landing persists under its own archive's id"
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

    @Test("deleting the running session is refused until the run ends")
    func deletingRunningSessionIsRefused() async {
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

        #expect(sut.model.openArchive?.id == sut.id, "the open archive stays")
        #expect(sut.store.load(id: sut.id) != nil, "the session stays in the archive")
        #expect(sut.model.archiveTranslationRunning, "the run stays claimed")
        #expect(archiveToast(sut.model) != nil, "the run's card stays up")
        gate.release()
        gate.release()
        gate.release()
        #expect(
            await pollUntil(timeout: resultTimeout) {
                archiveToast(sut.model)?.title == "Archive translation finished"
                    && !sut.model.archiveTranslationRunning
            },
            "the released run walks every sentence"
        )
        #expect(
            engine.recordedBatches == [["こんにちは"], ["さようなら"], ["おはよう"]],
            "the refused delete never interrupts the run"
        )
        #expect(
            !sut.model.toasts.toasts.contains { toast in toast.key == ToastKey.archiveUnavailable },
            "the run's completed writes never post the archive warning"
        )

        sut.model.deleteArchive(id: sut.id)

        #expect(sut.model.openArchive == nil, "the delete after the run closes the archive")
        #expect(sut.store.load(id: sut.id) == nil, "the delete after the run removes it")
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

    // MARK: - Open-archive snapshot

    @Test("a bulk start sees translations landed after the archive opened")
    func bulkStartSeesTranslationsLandedAfterOpen() async {
        let sut = await makeSUT(translations: [0: "T:こんにちは"])
        let engine = ScriptedArchiveEngine()
        install(engine, for: .google, on: sut.model)

        sut.model.beginArchiveTranslation(engine: .google, lang: "fr")
        #expect(
            await pollUntil(timeout: resultTimeout) { runFinished(sut.model, translated: 2) },
            "the first run fills the sentences missing when the archive opened"
        )
        #expect(
            sut.model.openArchive?.summary.languageCount(for: "fr")?.translated == 3,
            "the summary reads complete after the fill"
        )

        sut.model.beginArchiveTranslation(engine: .google, lang: "fr")
        #expect(
            await pollUntil(timeout: resultTimeout) {
                sut.model.archiveTranslationJob.lastRun?.request.scope == .all
            },
            "the second run reads the pane's current rows, not the open-time snapshot"
        )
        #expect(
            sut.model.archiveTranslationJob.lastRun?.request.translated == Set([0, 1, 2]),
            "every sentence is known to be translated"
        )
        #expect(
            await pollUntil(timeout: resultTimeout) { runFinished(sut.model, translated: 3) },
            "a complete language gets a fresh full pass"
        )
    }
}
