import Foundation
@testable import Mimidasu
import Testing

/// Pins `AppModel`'s archive commands onto the cached read surface: every
/// landed mutation routes through `ArchiveReadModel`, so the cached rows and
/// the forwarded revision move together, a live recording write bumps
/// without joining the window list, and a failed command leaves both alone.
@MainActor
@Suite("AppModel archive read model")
struct AppModelArchiveReadModelTests {

    private struct SUT {
        let model: AppModel
        let store: ArchiveStore
        let id: Int64
    }

    // MARK: - Fixtures

    private func metadata(
        target: String = "en", startedAt: TimeInterval = 1_000_000
    ) -> SessionMetadata {
        SessionMetadata(
            startedAt: Date(timeIntervalSince1970: startedAt),
            sourceLang: "ja", targetLang: target, model: "test-model", chunkMS: 160
        )
    }

    private func sentence(_ index: Int, text: String) -> Sentence {
        Sentence(index: index, startS: Double(index), endS: Double(index) + 1, lang: "ja", text: text)
    }

    /// One finalized, listed session of `sentences` sentences.
    private func seedFinalized(_ store: ArchiveStore, sentences: [String] = ["こんにちは"]) -> Int64? {
        var id: Int64?
        for (index, text) in sentences.enumerated() {
            id = store.append(
                sentence: sentence(index, text: text), sessionID: id, metadata: metadata()
            )
        }
        guard let id else { return nil }
        store.finalize(session: id, durationMS: 60000, saved: false)
        return id
    }

    /// One unlisted `recording` row with a single sentence.
    private func seedRecording(_ store: ArchiveStore) -> Int64? {
        store.append(sentence: sentence(0, text: "こんにちは"), sessionID: nil, metadata: metadata())
    }

    private func makeModel(store: ArchiveStore) async -> AppModel {
        let model = AppModel(
            translationSettings: isolatedTranslationSettings(suite: "test.AppModelArchiveReadModel"),
            asrModelSettings: isolatedASRModelSettings(suite: "test.AppModelArchiveReadModel"),
            favorites: isolatedFavorites(),
            archive: store,
            highFidelityProbe: { _ in false },
            initialModelResolve: { _ in nil }
        )
        await model.initialModelCheck?.value
        return model
    }

    /// A model over one finalized two-sentence `en` session, not opened.
    private func makeListedSUT() async throws -> SUT {
        let store = isolatedArchive()
        let id = try #require(seedFinalized(store, sentences: ["こんにちは", "さようなら"]))
        let model = await makeModel(store: store)
        return SUT(model: model, store: store, id: id)
    }

    /// A store whose database cannot open: a file where the parent directory
    /// should be.
    private func degradedArchive() -> (store: ArchiveStore, cleanup: () -> Void) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mimidasu-appmodel-read-model-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let blocker = root.appendingPathComponent("blocker")
        try? Data().write(to: blocker)
        return (
            ArchiveStore(location: blocker.appendingPathComponent("archives.sqlite")),
            { try? FileManager.default.removeItem(at: root) }
        )
    }

    private func cachedRow(_ model: AppModel, id: Int64) -> ArchivedSessionSummary? {
        model.archiveRead.summaries.first { row in row.id == id }
    }

    // MARK: - The window's cached surface

    @Test("finalize joins the cached list and bumps the forwarded revision once")
    func windowReadsTheModelNotTheStore() async throws {
        let store = isolatedArchive()
        let model = await makeModel(store: store)
        let id = try #require(seedRecording(store), "the live fixture seeds its recording row")
        model.recordingSessionID = id
        let revisionBefore = model.archiveRevision
        #expect(cachedRow(model, id: id) == nil, "the recording row is not listed yet")

        let finalized = model.finalizeLiveSession(durationMS: 4000)

        #expect(finalized, "the finalize lands against the seeded row")
        #expect(model.archiveRevision == revisionBefore + 1, "the landed finalize bumps exactly once")
        #expect(cachedRow(model, id: id)?.status == .complete, "the finalized row joins the cache")
    }

    @Test("an archive write-back refreshes both the cached row and the open banner")
    func writeBackUpdatesTheCachedRowAndBanner() async throws {
        let sut = try await makeListedSUT()
        sut.model.openArchiveSession(id: sut.id)
        let revisionBefore = sut.model.archiveRevision

        let landed = sut.model.applyTranslation(
            index: 0, translation: SentenceTranslation(lang: "fr", text: "Bonjour")
        )

        #expect(landed, "the write-back lands against the open archive")
        #expect(sut.model.archiveRevision == revisionBefore + 1, "the landed write bumps once")
        #expect(
            cachedRow(sut.model, id: sut.id)?.languageCount(for: "fr")
                == ArchiveLanguageCount(lang: "fr", translated: 1),
            "the cached row carries the new language count"
        )
        #expect(
            cachedRow(sut.model, id: sut.id) == sut.store.summary(id: sut.id),
            "the cached row matches a fresh store read"
        )
        #expect(
            sut.model.openArchive?.summary.languageCount(for: "fr")
                == ArchiveLanguageCount(lang: "fr", translated: 1),
            "the open banner's payload refreshes in place"
        )
    }

    @Test("promote, rename, and delete each track the cached row and bump once")
    func promoteRenameDeleteTrackTheCache() async throws {
        let sut = try await makeListedSUT()
        let revisionBefore = sut.model.archiveRevision

        sut.model.promoteArchive(id: sut.id)

        #expect(sut.model.archiveRevision == revisionBefore + 1, "the promotion bumps once")
        #expect(cachedRow(sut.model, id: sut.id)?.saved == true, "the cached row flips to saved")

        sut.model.renameArchive(id: sut.id, name: "  Interview  ")

        #expect(sut.model.archiveRevision == revisionBefore + 2, "the rename bumps once")
        #expect(
            cachedRow(sut.model, id: sut.id)?.name == "Interview",
            "the cached row carries the trimmed name"
        )

        sut.model.deleteArchive(id: sut.id)

        #expect(sut.model.archiveRevision == revisionBefore + 3, "the delete bumps once")
        #expect(cachedRow(sut.model, id: sut.id) == nil, "the deleted row leaves the cache")
        #expect(sut.store.summary(id: sut.id) == nil, "the store holds nothing")
    }

    @Test("a live recording write bumps once and adds no window row")
    func liveRecordingWriteBumpsButAddsNoWindowRow() async throws {
        let store = isolatedArchive()
        let model = await makeModel(store: store)
        let id = try #require(seedRecording(store))
        model.recordingSessionID = id
        let seed = sentence(0, text: "こんにちは")
        model.entries = [SessionEntry(sentence: seed)]
        model.entryPositionBySentence = [seed.index: 0]
        let revisionBefore = model.archiveRevision
        #expect(model.archiveRead.summaries.isEmpty, "the recording row is not listed")

        let landed = model.applyTranslation(
            index: 0, translation: SentenceTranslation(lang: "en", text: "Hello")
        )

        #expect(landed, "the live row swap reports its landing")
        #expect(model.archiveRevision == revisionBefore + 1, "the landed write bumps once")
        #expect(model.archiveRead.summaries.isEmpty, "the window list gains no recording row")
        #expect(
            store.load(id: id)?.entries.first?.translations
                == [SentenceTranslation(lang: "en", text: "Hello")],
            "the recording row carries the write"
        )
    }

    // MARK: - Launch sweep and failures

    @Test("the launch sweep flips a cached recording row to interrupted and bumps")
    func launchSweepFlipsTheCachedRow() async throws {
        let store = isolatedArchive()
        let id = try #require(seedRecording(store), "the abandoned row is seeded before launch")
        let model = await makeModel(store: store)
        // Construction's own launch pass already flipped the abandoned row.
        #expect(cachedRow(model, id: id)?.status == .interrupted)
        let revisionBefore = model.archiveRevision

        model.sweepArchivesOnLaunch()

        #expect(model.archiveRevision == revisionBefore + 1, "the landed sweep bumps once")
        #expect(cachedRow(model, id: id)?.status == .interrupted, "the cached row keeps its status")
    }

    @Test("a failed command warns but changes neither the cache nor the revision")
    func failedCommandLeavesTheCacheAlone() async {
        let (store, cleanup) = degradedArchive()
        defer { cleanup() }
        let model = await makeModel(store: store)
        let revisionBefore = model.archiveRevision
        let summariesBefore = model.archiveRead.summaries

        model.deleteArchive(id: 7)

        #expect(model.archiveRevision == revisionBefore, "a failed write bumps nothing")
        #expect(model.archiveRead.summaries == summariesBefore, "the cache keeps its rows")
        #expect(
            model.archiveRead.availability == .openFailed,
            "the degraded store reads as unopenable"
        )
        let warning = model.toasts.toasts.first { toast in toast.key == ToastKey.archiveUnavailable }
        #expect(warning?.isClosable == true, "the command warning is dismissible")
        #expect(
            warning?.body
                == "The session store couldn't be written to. This session wasn't deleted.",
            "the failed command names its own outcome"
        )
    }

    // MARK: - Exact bump accounting

    @Test("one bump per landed command: the exact legacy total, and zero for append/pause")
    func exactBumpCountsMatchTheLegacySequence() async throws {
        let store = isolatedArchive()
        let recordingID = try #require(seedRecording(store), "the recording row is seeded first")
        let archiveID = try #require(
            seedFinalized(store, sentences: ["こんにちは", "さようなら"]),
            "the finalized row is seeded alongside"
        )
        let model = await makeModel(store: store)
        model.recordingSessionID = recordingID
        let revisionBefore = model.archiveRevision

        #expect(model.finalizeLiveSession(durationMS: 4000), "finalize lands")
        model.openArchiveSession(id: archiveID)
        #expect(model.archiveRevision == revisionBefore + 1, "opening an archive bumps nothing")
        #expect(model.addArchiveLanguage(id: archiveID, lang: "fr"), "the membership add lands")
        #expect(
            model.applyTranslation(
                index: 0, translation: SentenceTranslation(lang: "fr", text: "First")
            ),
            "the first write-back lands"
        )
        #expect(
            model.applyTranslation(
                index: 1, translation: SentenceTranslation(lang: "fr", text: "Second")
            ),
            "the second write-back lands"
        )
        model.promoteArchive(id: archiveID)
        model.renameArchive(id: archiveID, name: "Named")
        model.deleteArchive(id: archiveID)

        #expect(model.archiveRevision == revisionBefore + 7, "one bump per landed command")

        let afterCommands = model.archiveRevision
        let appended = model.archiveRead.append(
            sentence: sentence(1, text: "おはよう"), sessionID: recordingID, metadata: metadata()
        )
        #expect(appended == recordingID, "the read model's append lands against the row")
        #expect(
            model.archiveRead.syncPaused(session: recordingID, pausedMS: 2000),
            "the pause sync lands"
        )
        #expect(model.archiveRevision == afterCommands, "append and syncPaused add no bump")
    }
}
