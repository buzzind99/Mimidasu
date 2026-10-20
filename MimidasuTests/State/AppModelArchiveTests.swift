import Foundation
@testable import Mimidasu
import Testing

/// `AppModel`'s archive-mode surface over a seeded in-temp store: the
/// open/close of a stored session into the transcript pane (rows, metadata,
/// anchors, HUD), the availability gate against live phases, the
/// promote/rename/delete commands, the banner-update-in-place behavior, and
/// the bulk-run boundaries (a same-id reopen is a no-op; another id or a
/// close keeps the run and its card).
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
    /// duration, seeded into `store` (a fresh isolated one by default).
    private func makeModel(
        sentences: [String] = ["こんにちは", "さようなら"],
        store: ArchiveStore = isolatedArchive()
    ) async -> (AppModel, Int64) {
        var id: Int64?
        for (index, text) in sentences.enumerated() {
            id = store.append(
                sentence: sentence(index, text: text), sessionID: id, metadata: metadata()
            )
        }
        if let id {
            store.finalize(session: id, durationMS: 90000, saved: false)
        }
        let model = AppModel(
            favorites: isolatedFavorites(), archive: store,
            initialModelResolve: { _ in nil }
        )
        await model.initialModelCheck?.value
        return (model, id ?? -1)
    }

    private func entry(_ text: String) -> SessionEntry {
        SessionEntry(sentence: sentence(0, text: text))
    }

    /// A store whose database path sits under a regular file, so the open
    /// fails terminally and every write fails. Returns the temp root for the
    /// caller's cleanup.
    private func makeDegradedStore() -> (store: ArchiveStore, root: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mimidasu-archive-mode-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let blocker = root.appendingPathComponent("blocker")
        try? Data().write(to: blocker)
        let store = ArchiveStore(location: blocker.appendingPathComponent("archives.sqlite"))
        return (store, root)
    }

    // MARK: - Availability gate

    @Test("opening is allowed only from idle-ish phases")
    func canOpenMatrix() async {
        let (model, _) = await makeModel()

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
    func openRefusedWhileLive() async {
        let (model, id) = await makeModel()
        model.phase = .running

        model.openArchiveSession(id: id)

        #expect(model.openArchive == nil)
        #expect(model.entries.isEmpty)
    }

    @Test("starting is refused while an archive is open")
    func startRefusedWhileArchiveOpen() async {
        let (model, id) = await makeModel()
        model.phase = .idle
        model.openArchiveSession(id: id)
        let entriesBefore = model.entries

        model.start()

        #expect(model.phase == .idle, "the start never leaves idle")
        #expect(model.openArchive?.id == id, "the archive stays open")
        #expect(model.entries == entriesBefore, "the pane keeps showing the archive")
        #expect(model.sessionStartedAt == nil, "no session began")
    }

    // MARK: - Open / close

    @Test("opening swaps in the rows, metadata, and anchors")
    func openLoadsRowsAndResetsAnchors() async {
        let (model, id) = await makeModel()
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
    func openUnknownIdIsNoop() async {
        let (model, _) = await makeModel()

        model.openArchiveSession(id: 9999)

        #expect(model.openArchive == nil)
        #expect(model.entries.isEmpty)
    }

    @Test("closing empties the pane without restoring the live rows")
    func closeEmptiesPane() async {
        let (model, id) = await makeModel()
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

        sut.model.beginArchiveTranslation(engine: .google, lang: "fr")
        #expect(
            await pollUntil {
                sut.model.archiveTranslationRunning && engine.recordedBatches.count == 1
            },
            "the run starts and parks on its first sentence"
        )

        sut.model.openArchiveSession(id: sut.id)

        #expect(sut.model.archiveTranslationJob.activity != .idle, "the same-id reopen must not cancel the run")
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

    @Test("opening another archive keeps the run over the previous one")
    func openAnotherArchiveKeepsRunningRun() async {
        let sut = await makeSUT()
        let secondID = appendArchive(to: sut.store)
        let gate = PermitGate()
        let engine = ScriptedArchiveEngine(gate: gate)
        install(engine, for: .google, on: sut.model)

        sut.model.beginArchiveTranslation(engine: .google, lang: "fr")
        #expect(
            await pollUntil {
                sut.model.archiveTranslationRunning && engine.recordedBatches.count == 1
            },
            "the run starts and parks on its first sentence"
        )
        let cardID = archiveToast(sut.model)?.id
        #expect(cardID != nil, "the started event posts the progress card")

        sut.model.openArchiveSession(id: secondID)

        #expect(sut.model.openArchive?.id == secondID)
        #expect(sut.model.archiveTranslationRunning, "the swap keeps the run claimed")
        #expect(archiveToast(sut.model)?.id == cardID, "the swap keeps the run's card")
        gate.release()
        gate.release()
        gate.release()
        #expect(
            await pollUntil {
                archiveToast(sut.model)?.title == "Archive translation finished"
                    && !sut.model.archiveTranslationRunning
            },
            "the released run walks every sentence"
        )
        #expect(
            engine.recordedBatches == [["こんにちは"], ["さようなら"], ["おはよう"]],
            "no sentence is dropped by the swap"
        )
        #expect(
            sut.store.load(id: sut.id)?.entries.compactMap { entry in entry.translation(for: "fr")?.text }
                == ["T:こんにちは", "T:さようなら", "T:おはよう"],
            "every landing persists under the first archive"
        )
    }

    @Test("archive boundaries clear only main-window intents")
    func boundariesClearOnlyMainWindowIntents() async {
        let (model, first) = await makeModel()
        let secondID = appendArchive(to: model.archive)
        let mainWindowIntent = PendingCloudDisclosure.archiveTranslation(
            .deepl, lang: "fr", session: first, presenter: .mainWindow
        )
        let archiveWindowIntent = PendingCloudDisclosure.archiveTranslation(
            .google, lang: "de", session: secondID, presenter: .archiveWindow
        )

        model.openArchiveSession(id: first)
        model.providerAwaitingDisclosure = mainWindowIntent
        model.openArchiveSession(id: first)
        #expect(
            model.providerAwaitingDisclosure == mainWindowIntent,
            "a same-id reopen swaps nothing and keeps the intent"
        )

        model.openArchiveSession(id: secondID)
        #expect(model.providerAwaitingDisclosure == nil, "the swap clears the main window's intent")

        model.providerAwaitingDisclosure = mainWindowIntent
        model.closeArchive()
        #expect(model.providerAwaitingDisclosure == nil, "closing clears the main window's intent")

        model.openArchiveSession(id: first)
        model.providerAwaitingDisclosure = archiveWindowIntent
        model.openArchiveSession(id: secondID)
        #expect(
            model.providerAwaitingDisclosure == archiveWindowIntent,
            "the swap keeps the archive window's own intent"
        )

        model.closeArchive()
        #expect(
            model.providerAwaitingDisclosure == archiveWindowIntent,
            "closing the archive keeps the archive window's own intent"
        )

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
    func promoteUpdatesStoreAndBanner() async {
        let (model, id) = await makeModel()
        model.openArchiveSession(id: id)
        let revisionBefore = model.archiveRevision

        model.promoteArchive(id: id)

        #expect(model.archive.list().first?.saved == true)
        #expect(model.openArchive?.summary.saved == true)
        #expect(model.archiveRevision != revisionBefore)
    }

    @Test("the banner save icon promotes once and then no-ops")
    func saveOpenArchivePromotesOnce() async {
        let (model, id) = await makeModel()
        model.openArchiveSession(id: id)
        #expect(model.openArchive?.summary.saved == false)

        model.saveOpenArchive()
        #expect(model.archive.list().first?.saved == true)

        let revisionAfterPromote = model.archiveRevision
        model.saveOpenArchive()
        #expect(model.archiveRevision == revisionAfterPromote)
    }

    @Test("the banner save icon is a no-op with nothing open")
    func saveOpenArchiveWithoutOpenIsNoop() async {
        let (model, _) = await makeModel()
        let revisionBefore = model.archiveRevision

        model.saveOpenArchive()

        #expect(model.archive.list().first?.saved == false)
        #expect(model.archiveRevision == revisionBefore)
    }

    @Test("renaming updates the store and the open banner; an empty name clears")
    func renameUpdatesStoreAndBanner() async {
        let (model, id) = await makeModel()
        model.openArchiveSession(id: id)

        model.renameArchive(id: id, name: "Lecture 3")
        #expect(model.archive.list().first?.name == "Lecture 3")
        #expect(model.openArchive?.summary.name == "Lecture 3")

        model.renameArchive(id: id, name: "  ")
        #expect(model.archive.list().first?.name == nil)
        #expect(model.openArchive?.summary.name == nil)
    }

    @Test("each failed archive command warns dismissibly without bumping the revision")
    func commandWriteFailuresWarn() async {
        let (store, root) = makeDegradedStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let cases: [(suffix: String, run: @MainActor (AppModel) -> Void)] = [
            ("This rename wasn't applied.", { model in model.renameArchive(id: 7, name: "Nope") }),
            ("This session wasn't saved.", { model in model.promoteArchive(id: 7) }),
            ("This session wasn't deleted.", { model in model.deleteArchive(id: 7) })
        ]

        for testCase in cases {
            let (model, _) = await makeModel(sentences: [], store: store)
            let revisionBefore = model.archiveRevision

            testCase.run(model)

            let warning = model.toasts.toasts.first { toast in
                toast.key == ToastKey.archiveUnavailable
            }
            #expect(
                warning?.body == "The session store couldn't be written to. " + testCase.suffix,
                "the failed command names its own outcome"
            )
            #expect(warning?.isClosable == true, "the command warning is dismissible")
            #expect(model.archiveRevision == revisionBefore, "a failed command bumps nothing")
        }
    }

    @Test("deleting the open session closes it first, then removes it")
    func deleteClosesAndRemoves() async {
        let (model, id) = await makeModel()
        model.openArchiveSession(id: id)

        model.deleteArchive(id: id)

        #expect(model.openArchive == nil)
        #expect(model.entries.isEmpty)
        #expect(model.archive.list().isEmpty)
        #expect(model.archive.load(id: id) == nil)
    }

    // MARK: - Finalize guard

    @Test("finalizing without a recording session persists nothing")
    func finalizeWithoutRecordingIsNoop() async {
        let (model, _) = await makeModel()
        let revisionBefore = model.archiveRevision

        let finalized = model.finalizeLiveSession(durationMS: 5000)

        #expect(!finalized)
        #expect(model.archiveRevision == revisionBefore)
        #expect(!model.toasts.toasts.contains { toast in toast.key == ToastKey.archiveUnavailable })
    }

    @Test("a healthy store reports the archive as available")
    func healthyStoreIsAvailable() async {
        let (model, _) = await makeModel()

        #expect(model.archiveAvailable)
        #expect(!model.archiveWriteFailed)
    }
}
