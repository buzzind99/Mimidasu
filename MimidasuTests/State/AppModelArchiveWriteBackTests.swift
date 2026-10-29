import Foundation
@testable import Mimidasu
import Testing

/// Pins `AppModel`'s one write-back seam — upsert, one projection refresh of
/// the listed row and/or the open summary, landed report — directly and
/// through the three landing paths that funnel through it (per-row archive
/// mode, the live recording, and bulk runs), plus the agreement case: a
/// per-row and a bulk lost write leave the same facts behind.
@MainActor
@Suite("AppModel archive write-back")
struct AppModelArchiveWriteBackTests {

    private let runTimeout: TimeInterval = 5

    /// The three translations a full `fr` run of the default harness
    /// fixture lands, in sentence order.
    private let expectedFRResults = [
        SentenceTranslation(lang: "fr", text: "T:こんにちは", engine: .google),
        SentenceTranslation(lang: "fr", text: "T:さようなら", engine: .google),
        SentenceTranslation(lang: "fr", text: "T:おはよう", engine: .google)
    ]

    // MARK: - Fixtures

    /// A model over one stored recording row with a matching pane row: the
    /// deterministic live-session fixture, no start/stop orchestration.
    private struct LiveSUT {
        let model: AppModel
        let store: ArchiveStore
        let recordingID: Int64
    }

    private func makeLiveSUT() async throws -> LiveSUT {
        let store = isolatedArchive()
        let metadata = SessionMetadata(
            startedAt: Date(timeIntervalSince1970: 1_000_000),
            sourceLang: "ja", targetLang: "en", model: "test-model", chunkMS: 160
        )
        let sentence = Sentence(index: 0, startS: 0, endS: 1, lang: "ja", text: "こんにちは")
        let model = makeIdleModel(suite: "test.AppModelArchiveWriteBack", archive: store)
        await model.initialModelCheck?.value
        let recordingID = try #require(
            store.append(sentence: sentence, sessionID: nil, metadata: metadata),
            "the live fixture seeds its recording row after launch"
        )
        model.recordingSessionID = recordingID
        model.entries = [SessionEntry(sentence: sentence)]
        model.entryPositionBySentence = [sentence.index: 0]
        return LiveSUT(model: model, store: store, recordingID: recordingID)
    }

    private func archiveWarnings(_ model: AppModel) -> [ToastCenter.Toast] {
        model.toasts.toasts.filter { toast in toast.key == ToastKey.archiveUnavailable }
    }

    /// The reporting half of the lost-write contract, identical for the
    /// per-row caller and the bulk run.
    private func assertLostWriteReport(
        perRow: AppModel, bulk: AppModel, perRowReported: Bool
    ) {
        #expect(archiveWarnings(perRow).count == 1, "per-row: one warning card")
        #expect(archiveWarnings(bulk).count == 1, "bulk: one warning card for the run")
        #expect(archiveWarnings(perRow).first?.isClosable == true, "per-row: dismissible")
        #expect(archiveWarnings(bulk).first?.isClosable == true, "bulk: dismissible")
        #expect(
            archiveWarnings(perRow).first?.body == AppModel.lostTranslationWriteWarning,
            "per-row: the shared copy"
        )
        #expect(
            archiveWarnings(bulk).first?.body == AppModel.lostTranslationWriteWarning,
            "bulk: the shared copy"
        )
        #expect(
            perRow.entries.first?.translation(for: "fr")?.text == "Seed",
            "per-row: the previous text stays"
        )
        #expect(
            bulk.entries.first?.translation(for: "fr")?.text == "Seed",
            "bulk: the previous text stays"
        )
        #expect(
            bulk.entries.dropFirst().allSatisfy { entry in
                entry.translation(for: "fr") == nil
            },
            "bulk: no row shows a translation the store lacks"
        )
        // The loss is reported per path: the per-row caller sees false, the
        // bulk run counts each lost sentence as a retryable failure.
        #expect(!perRowReported, "the per-row landing reports the loss")
        #expect(bulk.archiveTranslationJob.translatedCount == 0, "no success is counted")
        #expect(bulk.archiveTranslationJob.failureIndexes == [1, 2], "each lost write fails")
    }

    // MARK: - The seam directly

    @Test("the seam lands for the open archive: store row and both cached surfaces")
    func seamLandsForOpenArchive() async {
        let sut = await makeSUT()
        let translation = SentenceTranslation(lang: "fr", text: "First")

        let landed = sut.model.writeBackTranslation(translation, index: 0, session: sut.id)

        #expect(landed, "a stored session's write reports its landing")
        #expect(
            sut.store.load(id: sut.id)?.entries.first?.translations == [translation],
            "the row reads back from the store"
        )
        #expect(
            sut.model.openArchive?.summary.languageCount(for: "fr")
                == ArchiveLanguageCount(lang: "fr", translated: 1),
            "the open summary's count refreshes"
        )
        #expect(
            sut.model.archiveProjection.summaries.first { summary in summary.id == sut.id }?
                .languageCount(for: "fr") == ArchiveLanguageCount(lang: "fr", translated: 1),
            "the listed row's count refreshes"
        )
        #expect(
            sut.model.openArchive?.summary == sut.model.archiveProjection.openSummary,
            "the open summary is the projection's one copy"
        )
        #expect(
            sut.model.archiveProjection.summaries.first { summary in summary.id == sut.id }
                == sut.model.archiveProjection.openSummary,
            "the listed row and the open summary agree"
        )
    }

    @Test("the seam refuses a lost write with no side effects")
    func seamRefusesLostWrite() async {
        let sut = await makeSUT(translations: [0: "Seed"])
        let summariesBefore = sut.model.archiveProjection.summaries
        let openSummaryBefore = sut.model.archiveProjection.openSummary
        let langsBefore = sut.model.openArchive?.summary.langs
        #expect(sut.store.delete(id: sut.id), "the session row is removed underneath")

        let landed = sut.model.writeBackTranslation(
            SentenceTranslation(lang: "fr", text: "Next"), index: 0, session: sut.id
        )

        #expect(!landed, "the lost write reports itself")
        #expect(sut.model.archiveProjection.summaries == summariesBefore, "the cached list is untouched")
        #expect(sut.model.archiveProjection.openSummary == openSummaryBefore, "the open summary is untouched")
        #expect(sut.model.openArchive?.summary == openSummaryBefore, "the pane reads the unchanged summary")
        #expect(sut.model.openArchive?.summary.langs == langsBefore, "the open summary is untouched")
        #expect(sut.store.load(id: sut.id) == nil, "the store still holds nothing")
        #expect(archiveWarnings(sut.model).isEmpty, "the seam itself posts no warning")
    }

    @Test("the seam lands a foreign session without touching the open summary")
    func seamLandsForeignSession() async {
        let sut = await makeSUT()
        let second = appendArchive(to: sut.store)
        sut.model.archiveProjection.reload()
        let translation = SentenceTranslation(lang: "fr", text: "Foreign")
        let langsBefore = sut.model.openArchive?.summary.langs
        let openSummaryBefore = sut.model.archiveProjection.openSummary

        let landed = sut.model.writeBackTranslation(translation, index: 0, session: second)

        #expect(landed, "a foreign session's write reports its landing")
        #expect(
            sut.model.openArchive?.summary.langs == langsBefore,
            "a foreign target never refreshes the open pane"
        )
        #expect(sut.model.archiveProjection.openSummary == openSummaryBefore, "the open summary is untouched")
        #expect(
            sut.model.archiveProjection.summaries.first { summary in summary.id == second }?
                .languageCount(for: "fr") == ArchiveLanguageCount(lang: "fr", translated: 1),
            "the foreign session's listed row refreshes"
        )
        #expect(
            sut.model.archiveProjection.summaries.first { summary in summary.id == second }
                == sut.store.summary(id: second),
            "the listed row matches the store"
        )
        #expect(
            sut.store.load(id: second)?.entries.first?.translations == [translation],
            "the foreign row reads back"
        )
        #expect(
            sut.store.summary(id: second)?.languageCount(for: "fr")
                == ArchiveLanguageCount(lang: "fr", translated: 1),
            "the foreign session's own summary counts it"
        )
    }

    @Test("the seam lands with no archive open")
    func seamLandsWithNoArchiveOpen() async {
        let sut = await makeSUT()
        sut.model.closeArchive()
        let translation = SentenceTranslation(lang: "fr", text: "After close")

        let landed = sut.model.writeBackTranslation(translation, index: 0, session: sut.id)

        #expect(landed, "the write lands against the stored session")
        #expect(sut.model.openArchive == nil, "nothing opens on the write")
        #expect(sut.model.archiveProjection.openSummary == nil, "no open summary is stored")
        #expect(
            sut.store.load(id: sut.id)?.entries.first?.translations == [translation],
            "the closed session's row reads back"
        )
        #expect(
            sut.model.archiveProjection.summaries.first { summary in summary.id == sut.id }?
                .languageCount(for: "fr") == ArchiveLanguageCount(lang: "fr", translated: 1),
            "the closed session's listed row still refreshes"
        )
    }

    @Test("repeat landed writes replace in place and refresh both surfaces")
    func repeatLandedWritesReplaceInPlace() async {
        let sut = await makeSUT()

        let first = sut.model.writeBackTranslation(
            SentenceTranslation(lang: "fr", text: "First"), index: 0, session: sut.id
        )
        let second = sut.model.writeBackTranslation(
            SentenceTranslation(lang: "fr", text: "Second"), index: 0, session: sut.id
        )

        #expect(first && second, "both repeats land")
        #expect(
            sut.store.load(id: sut.id)?.entries.first?.translations
                == [SentenceTranslation(lang: "fr", text: "Second")],
            "the repeat replaced the row in place"
        )
        #expect(
            sut.model.openArchive?.summary.languageCount(for: "fr")
                == ArchiveLanguageCount(lang: "fr", translated: 1),
            "the sentence tally stays one"
        )
        #expect(
            sut.model.archiveProjection.summaries.first { summary in summary.id == sut.id }?
                .languageCount(for: "fr") == ArchiveLanguageCount(lang: "fr", translated: 1),
            "the listed row's tally stays one"
        )
        #expect(
            sut.model.archiveProjection.summaries.first { summary in summary.id == sut.id }
                == sut.model.archiveProjection.openSummary,
            "the listed row and the open summary agree"
        )
    }
}

// MARK: - Landing paths

extension AppModelArchiveWriteBackTests {

    // MARK: - Per-row archive mode

    @Test("a per-row archive delivery funnels through the seam")
    func perRowDeliveryFunnelsThroughSeam() async {
        let sut = await makeSUT()
        let translation = SentenceTranslation(lang: "fr", text: "First")

        let landed = sut.model.applyTranslation(index: 0, translation: translation)

        #expect(landed, "the per-row landing reports its row swap")
        #expect(
            sut.store.load(id: sut.id)?.entries.first?.translations == [translation],
            "the store row reads back"
        )
        #expect(
            sut.model.openArchive?.summary.languageCount(for: "fr")
                == ArchiveLanguageCount(lang: "fr", translated: 1),
            "the tally refreshes from the store"
        )
        #expect(
            sut.model.archiveProjection.summaries.first { summary in summary.id == sut.id }?
                .languageCount(for: "fr") == ArchiveLanguageCount(lang: "fr", translated: 1),
            "the listed row's tally refreshes too"
        )
        #expect(
            sut.model.entries.first?.translation(for: "fr") == translation,
            "the pane row swaps"
        )
        #expect(
            sut.model.archiveProjection.summaries.first { summary in summary.id == sut.id }
                == sut.model.archiveProjection.openSummary,
            "the listed row and the open summary agree"
        )
    }

    @Test("a per-row archive loss keeps the previous text, warns, and changes neither surface")
    func perRowLossKeepsPreviousTextAndWarns() async {
        let sut = await makeSUT(translations: [0: "Seed"])
        let summariesBefore = sut.model.archiveProjection.summaries
        let openSummaryBefore = sut.model.archiveProjection.openSummary
        #expect(sut.store.delete(id: sut.id), "the row is removed underneath the open pane")

        let landed = sut.model.applyTranslation(
            index: 0, translation: SentenceTranslation(lang: "fr", text: "Next")
        )

        #expect(!landed, "the lost write reports itself")
        #expect(
            sut.model.entries.first?.translation(for: "fr")?.text == "Seed",
            "the row keeps its previous text"
        )
        let warnings = archiveWarnings(sut.model)
        #expect(warnings.count == 1, "one warning for the operation")
        #expect(warnings.first?.isClosable == true, "the archive-mode warning is dismissible")
        #expect(
            warnings.first?.body == AppModel.lostTranslationWriteWarning,
            "the card carries the shared copy"
        )
        #expect(!sut.model.archiveWriteFailed, "an archive-mode loss never latches the live session")
        #expect(sut.model.archiveProjection.summaries == summariesBefore, "a lost write leaves the cached rows alone")
        #expect(
            sut.model.archiveProjection.openSummary == openSummaryBefore,
            "a lost write leaves the open summary alone"
        )
    }

    // MARK: - Live recording

    @Test("a live recording delivery funnels through the seam")
    func liveDeliveryFunnelsThroughSeam() async throws {
        let sut = try await makeLiveSUT()
        let translation = SentenceTranslation(lang: "en", text: "Hello")

        let landed = sut.model.applyTranslation(index: 0, translation: translation)

        #expect(landed, "the live landing reports its row swap")
        #expect(
            sut.store.load(id: sut.recordingID)?.entries.first?.translations == [translation],
            "the recording row carries the landed write"
        )
        #expect(
            sut.model.entries.first?.translation(for: "en") == translation,
            "the pane row swaps to the landed text"
        )
        #expect(sut.model.archiveProjection.summaries.isEmpty, "the recording row never joins the window list")
        #expect(sut.model.archiveProjection.openSummary == nil, "a live write opens no session")
        #expect(!sut.model.archiveWriteFailed, "a landed write never latches")
    }

    @Test("a live loss latches and still swaps the row")
    func liveLossLatchesAndSwapsRow() async throws {
        let sut = try await makeLiveSUT()
        let translation = SentenceTranslation(lang: "en", text: "Hello")
        let summariesBefore = sut.model.archiveProjection.summaries
        #expect(sut.store.delete(id: sut.recordingID), "the recording row is removed underneath")

        let landed = sut.model.applyTranslation(index: 0, translation: translation)

        #expect(landed, "the display-from-memory swap still reports itself")
        #expect(sut.model.archiveWriteFailed, "the lost write latches the session")
        #expect(!sut.model.archiveAvailable, "the latched session reads as unavailable")
        let warnings = archiveWarnings(sut.model)
        #expect(warnings.count == 1, "one warning for the session")
        #expect(warnings.first?.isClosable == false, "the live warning is a persistent condition")
        #expect(
            sut.model.entries.first?.translation(for: "en") == translation,
            "the row is swapped although the store lacks the write"
        )
        #expect(sut.model.archiveProjection.summaries == summariesBefore, "a lost write leaves the window list alone")
        #expect(sut.model.archiveProjection.openSummary == nil, "a lost live write opens nothing")
    }

    // MARK: - Bulk runs

    @Test("a bulk run funnels through the seam")
    func bulkRunFunnelsThroughSeam() async {
        let sut = await makeSUT()
        let engine = ScriptedArchiveEngine()
        install(engine, for: .google, on: sut.model)
        let expectedLandings = expectedFRResults.map { translation in [translation] }

        sut.model.beginArchiveTranslation(engine: .google, lang: "fr")

        #expect(
            await pollUntil(timeout: runTimeout) { runFinished(sut.model, translated: 3) },
            "the run lands every sentence through the seam"
        )
        #expect(engine.recordedBatches == [["こんにちは"], ["さようなら"], ["おはよう"]])
        #expect(
            sut.store.load(id: sut.id)?.entries.map { entry in entry.translations }
                == expectedLandings,
            "every landed pull persists in the store"
        )
        #expect(
            sut.model.entries.map { entry in entry.translations } == expectedLandings,
            "the pane swaps each row to its landed translation"
        )
        #expect(
            sut.model.openArchive?.summary.languageCount(for: "fr")
                == ArchiveLanguageCount(lang: "fr", translated: 3),
            "the banner's language count refreshes from the projection"
        )
        #expect(
            sut.model.archiveProjection.summaries.first { summary in summary.id == sut.id }?
                .languageCount(for: "fr") == ArchiveLanguageCount(lang: "fr", translated: 3),
            "the listed row carries the same count"
        )
        #expect(
            sut.model.archiveProjection.summaries.first { summary in summary.id == sut.id }
                == sut.model.archiveProjection.openSummary,
            "the listed row and the open summary agree"
        )
        #expect(
            sut.model.archiveTranslationJob.translatedCount == 3,
            "the run counts every landing"
        )
        #expect(
            sut.model.archiveTranslationJob.failureIndexes.isEmpty,
            "no sentence counts as failed"
        )

        sut.model.closeArchive()
        sut.model.openArchiveSession(id: sut.id)
        #expect(
            sut.model.entries.compactMap { entry in entry.translation(for: "fr")?.text }
                == ["T:こんにちは", "T:さようなら", "T:おはよう"],
            "a reopen reads every write-back out of the store"
        )
    }

    @Test("both landing paths agree on the lost-write contract")
    func pathsAgreeOnLostWriteContract() async {
        let perRow = await makeSUT(translations: [0: "Seed"])
        let perRowSummariesBefore = perRow.model.archiveProjection.summaries
        let perRowOpenSummaryBefore = perRow.model.archiveProjection.openSummary
        #expect(perRow.store.delete(id: perRow.id), "the open archive's row vanishes")
        let perRowReported = perRow.model.applyTranslation(
            index: 0, translation: SentenceTranslation(lang: "fr", text: "Next")
        )

        let bulk = await makeSUT(translations: [0: "Seed"])
        let bulkSummariesBefore = bulk.model.archiveProjection.summaries
        let bulkOpenSummaryBefore = bulk.model.archiveProjection.openSummary
        let engine = ScriptedArchiveEngine()
        install(engine, for: .google, on: bulk.model)
        #expect(bulk.store.delete(id: bulk.id), "the run's row vanishes underneath")
        bulk.model.beginArchiveTranslation(engine: .google, lang: "fr")
        #expect(
            await pollUntil(timeout: runTimeout) { runFinished(bulk.model, translated: 0) },
            "the run winds down on the lost writes"
        )

        // The identical facts, asserted for both paths side by side: the
        // store holds nothing, neither cached surface changes, one closable
        // card carries the shared copy, and no pane row claims a translation
        // the store lacks.
        #expect(perRow.store.load(id: perRow.id) == nil, "per-row: the store holds no session")
        #expect(bulk.store.load(id: bulk.id) == nil, "bulk: the store holds no session")
        #expect(
            perRow.model.archiveProjection.summaries == perRowSummariesBefore,
            "per-row: the cached rows are unchanged"
        )
        #expect(
            perRow.model.archiveProjection.openSummary == perRowOpenSummaryBefore,
            "per-row: the open summary is unchanged"
        )
        #expect(
            bulk.model.archiveProjection.summaries == bulkSummariesBefore,
            "bulk: the cached rows are unchanged"
        )
        #expect(
            bulk.model.archiveProjection.openSummary == bulkOpenSummaryBefore,
            "bulk: the open summary is unchanged"
        )
        assertLostWriteReport(perRow: perRow.model, bulk: bulk.model, perRowReported: perRowReported)
    }
}
