import Foundation
@testable import Mimidasu
import Testing

/// The row-chip start half of the bulk-run lifecycle: a start addressed by
/// session id works whether or not that session is open — it loads the
/// rows from the store, lands its results there, refreshes the window's row
/// summary, and never swaps the transcript pane. The one-job-at-a-time
/// refusal and the delete-mid-run guard are pinned from the row's angle
/// (a run over a session the pane is not showing), and a deleted session
/// reports instead of claiming.
@MainActor
@Suite("AppModelArchiveTranslation row starts")
struct AppModelArchiveTranslationRowStartTests {

    private let resultTimeout: TimeInterval = 5

    @Test("a row start over a non-open session lands in its own store and refreshes its summary")
    func rowStartOverANonOpenSessionLandsInItsOwnStore() async {
        let sut = await makeSUT()
        let otherID = appendArchive(to: sut.store, sentences: ["bonjour", "merci"])
        sut.store.upsert(
            translation: SentenceTranslation(lang: "fr", text: "Seed"), index: 0, session: otherID
        )
        let engine = ScriptedArchiveEngine()
        install(engine, for: .google, on: sut.model)
        sut.model.archiveRead.reload()
        let before = sut.model.archiveRead.summaries.first { summary in summary.id == otherID }
        #expect(
            before?.languageCount(for: "fr") == ArchiveLanguageCount(lang: "fr", translated: 1),
            "the row's summary starts partial"
        )

        sut.model.beginArchiveTranslation(engine: .google, lang: "fr", sessionID: otherID)

        #expect(
            await pollUntil(timeout: resultTimeout) { runFinished(sut.model, translated: 1) },
            "the row's run fills only the missing sentence"
        )
        #expect(
            engine.recordedBatches == [["merci"]],
            "the run reads its rows from the store, not from the open pane"
        )
        #expect(
            sut.store.load(id: otherID)?.entries.compactMap { entry in entry.translation(for: "fr")?.text }
                == ["Seed", "T:merci"],
            "the seed survives and the fresh landing persists in the row's own session"
        )
        let after = sut.model.archiveRead.summaries.first { summary in summary.id == otherID }
        #expect(
            after?.languageCount(for: "fr") == ArchiveLanguageCount(lang: "fr", translated: 2),
            "the row summary refreshes in place"
        )
        #expect(sut.model.openArchive?.id == sut.id, "the row start never swaps the pane")
        #expect(
            sut.model.entries.map { entry in entry.sentence.text }
                == ["こんにちは", "さようなら", "おはよう"],
            "the open pane keeps its own rows"
        )
    }

    @Test("a row start over a deleted session reports unavailable and claims nothing")
    func rowStartOverADeletedSessionReportsUnavailable() async {
        let sut = await makeSUT()
        let otherID = appendArchive(to: sut.store)
        sut.model.archiveRead.reload()
        sut.model.deleteArchive(id: otherID)
        #expect(sut.store.load(id: otherID) == nil, "the session is gone before the start")
        let engine = ScriptedArchiveEngine()
        install(engine, for: .google, on: sut.model)

        sut.model.beginArchiveTranslation(engine: .google, lang: "fr", sessionID: otherID)

        #expect(archiveToast(sut.model) != nil, "the start reports the missing session")
        let toast = archiveToast(sut.model)
        #expect(toast?.style == .yellowAuto)
        #expect(toast?.title == "Archive translation unavailable")
        #expect(toast?.body == "This session is no longer in the archive.")
        #expect(sut.model.archiveTranslationJob.activity == .idle, "no claim is taken")
        #expect(sut.model.archiveTranslationJob.lastRun == nil)
        #expect(engine.recordedBatches.isEmpty, "no engine ever runs")
    }

    @Test("a direct picker request is refused while a job runs")
    func directRequestRefusedWhileAJobRuns() async {
        let sut = await makeSUT()
        let otherID = appendArchive(to: sut.store)
        let gate = PermitGate()
        let engine = ScriptedArchiveEngine(gate: gate)
        install(engine, for: .google, on: sut.model)

        sut.model.beginArchiveTranslation(engine: .google, lang: "fr")
        #expect(
            await pollUntil(timeout: resultTimeout) {
                sut.model.archiveTranslationRunning && engine.recordedBatches.count == 1
            },
            "the first run claims the slot and parks mid-walk"
        )
        let claimed = sut.model.archiveTranslationJob.activity.request

        sut.model.requestArchiveTranslation(
            engine: .google, lang: "fr", sessionID: otherID, presenter: .archiveWindow
        )

        #expect(
            sut.model.providerAwaitingDisclosure == nil,
            "the refused request stages nothing for a disclosure"
        )
        #expect(
            sut.model.archiveTranslationJob.activity.request == claimed,
            "the claimed run is untouched"
        )
        #expect(engine.recordedBatches == [["こんにちは"]], "no second flight starts")

        gate.release()
        gate.release()
        gate.release()
        #expect(
            await pollUntil(timeout: resultTimeout) { runFinished(sut.model, translated: 3) },
            "the claimed run drains on its own"
        )
    }

    @Test("deleting the session a row run walks is refused while it is claimed")
    func deletingTheWalksSessionIsRefused() async {
        let sut = await makeSUT()
        let otherID = appendArchive(to: sut.store, sentences: ["bonjour", "merci"])
        let gate = PermitGate()
        let engine = ScriptedArchiveEngine(gate: gate)
        install(engine, for: .google, on: sut.model)

        sut.model.beginArchiveTranslation(engine: .google, lang: "fr", sessionID: otherID)
        #expect(
            await pollUntil(timeout: resultTimeout) {
                sut.model.archiveTranslationRunning && engine.recordedBatches.count == 1
            },
            "the row run parks on its first sentence"
        )

        sut.model.deleteArchive(id: otherID)

        #expect(sut.store.load(id: otherID) != nil, "the delete is refused while the run walks it")
        #expect(
            sut.model.archiveTranslationJob.activity.request?.sessionID == otherID,
            "the run stays claimed"
        )
        #expect(sut.model.openArchive?.id == sut.id, "the pane stays on its archive")

        gate.release()
        gate.release()
        #expect(
            await pollUntil(timeout: resultTimeout) { runFinished(sut.model, translated: 2) },
            "the released run walks both sentences"
        )
        #expect(
            sut.store.load(id: otherID)?.entries.allSatisfy { entry in
                entry.translation(for: "fr") != nil
            } == true,
            "every sentence of the refused delete persists"
        )
    }
}

/// The disclosure half of the row start: which window an external pick
/// stages for, that the confirm starts the session the intent names (not
/// the open pane), and that the archive window's close declines only its
/// own intent.
@MainActor
@Suite("AppModelArchiveTranslation row disclosures")
struct ArchiveTranslationRowDisclosureTests {

    private let resultTimeout: TimeInterval = 5

    @Test("the banner request stages a main-window intent for the open archive")
    func bannerRequestStagesMainWindowIntent() async {
        let sut = await makeSUT()

        sut.model.requestArchiveTranslation(engine: .google, lang: "fr")

        #expect(
            sut.model.providerAwaitingDisclosure
                == .archiveTranslation(.google, lang: "fr", session: sut.id, presenter: .mainWindow),
            "the banner pick pairs the open archive with the main window"
        )
        #expect(!sut.model.archiveTranslationRunning, "staging never starts a run")
    }

    @Test("a row request stages an archive-window intent for its own session")
    func rowRequestStagesArchiveWindowIntent() async {
        let sut = await makeSUT()
        let otherID = appendArchive(to: sut.store)

        sut.model.requestArchiveTranslation(
            engine: .google, lang: "fr", sessionID: otherID, presenter: .archiveWindow
        )

        #expect(
            sut.model.providerAwaitingDisclosure
                == .archiveTranslation(.google, lang: "fr", session: otherID, presenter: .archiveWindow),
            "the row pick pairs its own session with the archive window"
        )
        #expect(sut.model.archiveTranslationJob.activity == .idle)
    }

    @Test("confirming a row intent starts the row's session, not the open one")
    func confirmingRowIntentStartsTheRowsSession() async throws {
        let sut = await makeSUT()
        let otherID = appendArchive(to: sut.store, sentences: ["bonjour", "merci"])
        let engine = ScriptedArchiveEngine()
        install(engine, for: .google, on: sut.model)
        sut.model.requestArchiveTranslation(
            engine: .google, lang: "fr", sessionID: otherID, presenter: .archiveWindow
        )
        let intent = try #require(sut.model.providerAwaitingDisclosure)

        sut.model.confirmCloudDisclosure(intent)

        #expect(sut.model.providerAwaitingDisclosure == nil, "the confirm clears the slot")
        #expect(
            await pollUntil(timeout: resultTimeout) { runFinished(sut.model, translated: 2) },
            "the confirmed pick flies the row's session"
        )
        #expect(
            sut.model.archiveTranslationJob.lastRun?.request.sessionID == otherID,
            "the run never retargets the open archive"
        )
        #expect(engine.recordedBatches == [["bonjour"], ["merci"]])
        #expect(sut.model.openArchive?.id == sut.id, "the confirm never swaps the pane")
        #expect(
            sut.store.load(id: sut.id)?.entries.allSatisfy { entry in entry.translations.isEmpty } == true,
            "the open archive is untouched"
        )
    }

    @Test("closing the window declines its own row intent")
    func windowCloseDeclinesItsOwnRowIntent() async {
        let sut = await makeSUT()
        sut.model.requestArchiveTranslation(
            engine: .google, lang: "fr", sessionID: sut.id, presenter: .archiveWindow
        )
        #expect(
            sut.model.providerAwaitingDisclosure != nil,
            "the row staged its intent"
        )

        sut.model.declineArchiveWindowDisclosure()

        #expect(
            sut.model.providerAwaitingDisclosure == nil,
            "the window close declines its own intent"
        )
    }

    @Test("closing the window leaves a main-window intent staged")
    func windowCloseLeavesMainWindowIntentStaged() async {
        let sut = await makeSUT()
        let intent = PendingCloudDisclosure.archiveTranslation(
            .google, lang: "fr", session: sut.id, presenter: .mainWindow
        )
        sut.model.providerAwaitingDisclosure = intent

        sut.model.declineArchiveWindowDisclosure()

        #expect(
            sut.model.providerAwaitingDisclosure == intent,
            "the banner's intent stays staged for its own sheet"
        )
    }
}
