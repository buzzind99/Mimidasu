import Foundation
@testable import Mimidasu
import Testing

/// `AppModel`'s archive-mode surface over a seeded in-temp store: the
/// open/close of a stored session into the transcript pane (rows, metadata,
/// anchors, HUD), the availability gate against live phases, the
/// promote/rename/delete commands, the banner-update-in-place behavior, and
/// the bulk-run boundaries (a same-id reopen is a no-op; another id or a
/// close cancels).
///
/// No session machinery involved — these tests seed the store directly and
/// poke `phase`; the begin-driven persistence lives in
/// `AppModelArchivePersistenceTests`.
@MainActor
@Suite("AppModel archive mode")
struct AppModelArchiveTests {

    // MARK: - Fixtures

    private func metadata() -> SessionMetadata {
        SessionMetadata(
            startedAt: Date(timeIntervalSince1970: 1_000_000),
            sourceLang: "ja",
            targetLang: "en",
            model: "test-model",
            chunkMS: 160
        )
    }

    private func sentence(_ index: Int, text: String) -> Sentence {
        Sentence(index: index, startS: Double(index), endS: Double(index) + 1.5, lang: "ja", text: text)
    }

    /// A recent with two sentences ("こんにちは" and "さようなら") and a 90 s
    /// duration, seeded into a fresh isolated store.
    private func makeModel(sentences: [String] = ["こんにちは", "さようなら"]) -> (AppModel, Int64) {
        let store = isolatedArchive()
        var id: Int64?
        for (index, text) in sentences.enumerated() {
            id = store.append(
                sentence: sentence(index, text: text), sessionID: id, metadata: metadata()
            )
        }
        if let id {
            store.finalize(session: id, durationMS: 90000, saved: false)
        }
        let model = AppModel(favorites: isolatedFavorites(), archive: store)
        return (model, id ?? -1)
    }

    private func entry(_ text: String) -> SessionEntry {
        SessionEntry(sentence: sentence(0, text: text))
    }

    // MARK: - Availability gate

    @Test("opening is allowed only from idle-ish phases")
    func canOpenMatrix() {
        let (model, _) = makeModel()

        #expect(model.canOpenArchivedSession)
        model.phase = .needsModel
        #expect(model.canOpenArchivedSession)
        model.phase = .failed("boom")
        #expect(model.canOpenArchivedSession)

        for phase in [SessionPhase.starting, .running, .paused, .sourceLost, .stopping] {
            model.phase = phase
            #expect(!model.canOpenArchivedSession, "phase \(phase) must block opening")
        }
    }

    @Test("opening is refused while a session is live-ish")
    func openRefusedWhileLive() {
        let (model, id) = makeModel()
        model.phase = .running

        model.openArchiveSession(id: id)

        #expect(model.openArchive == nil)
        #expect(model.entries.isEmpty)
    }

    // MARK: - Open / close

    @Test("opening swaps in the rows, metadata, and anchors")
    func openLoadsRowsAndResetsAnchors() {
        let (model, id) = makeModel()
        model.entries = [entry("live row")]
        model.sessionCharacterCount = 42
        model.hudVisible = true
        model.translationOverlayVisible = true
        model.sessionStartedAt = ContinuousClock.now
        model.sessionEndedAt = ContinuousClock.now

        model.openArchiveSession(id: id)

        #expect(model.openArchive?.id == id)
        #expect(model.entries.map { entry in entry.sentence.text } == ["こんにちは", "さようなら"])
        #expect(model.entryPositionBySentence == [0: 0, 1: 1])
        #expect(model.sessionCharacterCount == "こんにちは".count + "さようなら".count)
        #expect(model.selectedLookup == nil)
        #expect(model.pinnedLookup == nil)
        #expect(!model.hudVisible)
        #expect(!model.translationOverlayVisible)
        #expect(model.sessionStartedAt == nil)
        #expect(model.sessionEndedAt == nil)
        #expect(model.captureLostAt == nil)
    }

    @Test("opening an unknown id is a no-op")
    func openUnknownIdIsNoop() {
        let (model, _) = makeModel()

        model.openArchiveSession(id: 9999)

        #expect(model.openArchive == nil)
        #expect(model.entries.isEmpty)
    }

    @Test("closing empties the pane without restoring the live rows")
    func closeEmptiesPane() {
        let (model, id) = makeModel()
        model.openArchiveSession(id: id)
        #expect(!model.entries.isEmpty)

        model.closeArchive()

        #expect(model.openArchive == nil)
        #expect(model.entries.isEmpty)
        #expect(model.entryPositionBySentence.isEmpty)
        #expect(model.sessionCharacterCount == 0)
    }

    // MARK: - Bulk-run boundaries

    @Test("re-opening the open archive leaves its running run claimed")
    func reopenSameArchiveKeepsRunningRun() async {
        let sut = await makeSUT()
        let gate = PermitGate()
        let engine = ScriptedArchiveEngine(gate: gate)
        install(engine, for: .google, on: sut.model)

        sut.model.beginArchiveTranslation(provider: .google, lang: "fr")
        #expect(
            await pollUntil {
                sut.model.archiveTranslationRunning && engine.recordedBatches.count == 1
            },
            "the run starts and parks on its first sentence"
        )

        sut.model.openArchiveSession(id: sut.id)

        #expect(sut.model.archiveTranslationJob.isActive, "the same-id reopen must not cancel the run")
        #expect(archiveToast(sut.model) != nil, "its progress card stays up")
        #expect(engine.recordedBatches == [["こんにちは"]], "no new flight starts")

        gate.release()
        gate.release()
        gate.release()
        #expect(
            await pollUntil { runFinished(sut.model, translated: 3) },
            "the untouched run completes every sentence"
        )
    }

    @Test("opening another archive cancels the run over the previous one")
    func openAnotherArchiveCancelsRunningRun() async {
        let sut = await makeSUT()
        let secondID = appendArchive(to: sut.store)
        let gate = PermitGate()
        let engine = ScriptedArchiveEngine(gate: gate)
        install(engine, for: .google, on: sut.model)

        sut.model.beginArchiveTranslation(provider: .google, lang: "fr")
        #expect(
            await pollUntil {
                sut.model.archiveTranslationRunning && engine.recordedBatches.count == 1
            },
            "the run starts and parks on its first sentence"
        )

        sut.model.openArchiveSession(id: secondID)

        #expect(sut.model.openArchive?.id == secondID)
        #expect(archiveToast(sut.model) == nil, "the swap cancels and clears the card")
        gate.release()
        #expect(
            await pollUntil { !sut.model.archiveTranslationRunning },
            "the released run winds down canceled"
        )
        #expect(engine.recordedBatches == [["こんにちは"]], "no new sentence starts after the cancel")
        #expect(
            sut.store.load(id: sut.id)?.entries.first?.translations
                == [SentenceTranslation(lang: "fr", text: "T:こんにちは", engine: .google)],
            "the airborne result still persists under the first archive"
        )
    }

    @Test("archive boundaries clear a pending archive-translation intent")
    func boundariesClearPendingArchiveIntent() {
        let (model, first) = makeModel()
        let secondID = appendArchive(to: model.archive)

        model.openArchiveSession(id: first)
        model.providerAwaitingDisclosure = .archiveTranslation(.deepl, lang: "fr")
        model.openArchiveSession(id: first)
        #expect(
            model.providerAwaitingDisclosure == .archiveTranslation(.deepl, lang: "fr"),
            "a same-id reopen swaps nothing and keeps the intent"
        )

        model.openArchiveSession(id: secondID)
        #expect(model.providerAwaitingDisclosure == nil, "the swap clears the archive intent")

        model.providerAwaitingDisclosure = .archiveTranslation(.google, lang: "de")
        model.closeArchive()
        #expect(model.providerAwaitingDisclosure == nil, "closing clears it")

        model.openArchiveSession(id: first)
        model.providerAwaitingDisclosure = .retranslateEngine(.deepl)
        model.closeArchive()
        #expect(
            model.providerAwaitingDisclosure == .retranslateEngine(.deepl),
            "other intent kinds survive the boundary"
        )
    }

    // MARK: - Promote / rename / delete

    @Test("promoting moves the session to Saved and updates the open banner")
    func promoteUpdatesStoreAndBanner() {
        let (model, id) = makeModel()
        model.openArchiveSession(id: id)
        let revisionBefore = model.archiveRevision

        model.promoteArchive(id: id)

        #expect(model.archive.list().first?.saved == true)
        #expect(model.openArchive?.summary.saved == true)
        #expect(model.archiveRevision != revisionBefore)
    }

    @Test("the banner save icon promotes once and then no-ops")
    func saveOpenArchivePromotesOnce() {
        let (model, id) = makeModel()
        model.openArchiveSession(id: id)
        #expect(model.openArchive?.summary.saved == false)

        model.saveOpenArchive()
        #expect(model.archive.list().first?.saved == true)

        let revisionAfterPromote = model.archiveRevision
        model.saveOpenArchive()
        #expect(model.archiveRevision == revisionAfterPromote)
    }

    @Test("the banner save icon is a no-op with nothing open")
    func saveOpenArchiveWithoutOpenIsNoop() {
        let (model, _) = makeModel()
        let revisionBefore = model.archiveRevision

        model.saveOpenArchive()

        #expect(model.archive.list().first?.saved == false)
        #expect(model.archiveRevision == revisionBefore)
    }

    @Test("renaming updates the store and the open banner; an empty name clears")
    func renameUpdatesStoreAndBanner() {
        let (model, id) = makeModel()
        model.openArchiveSession(id: id)

        model.renameArchive(id: id, name: "Lecture 3")
        #expect(model.archive.list().first?.name == "Lecture 3")
        #expect(model.openArchive?.summary.name == "Lecture 3")

        model.renameArchive(id: id, name: "  ")
        #expect(model.archive.list().first?.name == nil)
        #expect(model.openArchive?.summary.name == nil)
    }

    @Test("deleting the open session closes it first, then removes it")
    func deleteClosesAndRemoves() {
        let (model, id) = makeModel()
        model.openArchiveSession(id: id)

        model.deleteArchive(id: id)

        #expect(model.openArchive == nil)
        #expect(model.entries.isEmpty)
        #expect(model.archive.list().isEmpty)
        #expect(model.archive.load(id: id) == nil)
    }

    // MARK: - Finalize guard

    @Test("finalizing without a recording session persists nothing")
    func finalizeWithoutRecordingIsNoop() {
        let (model, _) = makeModel()
        let revisionBefore = model.archiveRevision

        let finalized = model.finalizeLiveSession(durationMS: 5000)

        #expect(!finalized)
        #expect(model.archiveRevision == revisionBefore)
        #expect(!model.toasts.toasts.contains { toast in toast.key == ToastKey.archiveUnavailable })
    }

    @Test("a healthy store reports the archive as available")
    func healthyStoreIsAvailable() {
        let (model, _) = makeModel()

        #expect(model.archiveAvailable)
        #expect(!model.archiveWriteFailed)
    }
}
