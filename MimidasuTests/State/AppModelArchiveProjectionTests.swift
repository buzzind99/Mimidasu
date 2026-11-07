import Foundation
@testable import Mimidasu
import Testing

/// Pins `AppModel`'s archive commands onto the cached read surface: every
/// landed mutation routes through `ArchiveProjection`, so the cached row and
/// the open summary move together from one refresh, a live recording write
/// never joins the window list, and a failed command leaves both alone.
@MainActor
@Suite("AppModel archive projection")
struct AppModelArchiveProjectionTests {

    private struct SUT {
        let model: AppModel
        let store: ArchiveStore
        let id: Int64
    }

    // MARK: - Fixtures

    /// One finalized, listed session of `sentences` sentences.
    private func seedFinalized(_ store: ArchiveStore, sentences: [String] = ["こんにちは"]) -> Int64? {
        var id: Int64?
        for (index, text) in sentences.enumerated() {
            id = store.append(
                sentence: archiveSentence(index, text: text), sessionID: id, metadata: archiveMetadata(target: "en")
            )
        }
        guard let id else { return nil }
        store.finalize(session: id, durationMS: 60000, saved: false)
        return id
    }

    /// One unlisted `recording` row with a single sentence.
    private func seedRecording(_ store: ArchiveStore) -> Int64? {
        store.append(sentence: archiveSentence(0, text: "こんにちは"), sessionID: nil, metadata: archiveMetadata(target: "en"))
    }

    private func makeModel(store: ArchiveStore) async -> AppModel {
        let model = makeIdleModel(suite: "test.AppModelArchiveProjection", archive: store)
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
            .appendingPathComponent("mimidasu-appmodel-projection-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let blocker = root.appendingPathComponent("blocker")
        try? Data().write(to: blocker)
        return (
            ArchiveStore(location: blocker.appendingPathComponent("archives.sqlite")),
            { try? FileManager.default.removeItem(at: root) }
        )
    }

    private func cachedRow(_ model: AppModel, id: Int64) -> ArchivedSessionSummary? {
        model.archiveProjection.summaries.first { row in row.id == id }
    }

    // MARK: - The window's cached surface

    @Test("finalize joins the cached list with the complete row")
    func finalizeJoinsTheCachedList() async throws {
        let store = isolatedArchive()
        let model = await makeModel(store: store)
        let id = try #require(seedRecording(store), "the live fixture seeds its recording row")
        model.recordingSessionID = id
        #expect(cachedRow(model, id: id) == nil, "the recording row is not listed yet")

        let finalized = model.finalizeLiveSession(durationMS: 4000)

        #expect(finalized, "the finalize lands against the seeded row")
        let row = cachedRow(model, id: id)
        #expect(row?.status == .complete, "the finalized row joins the cache")
        #expect(row == store.summary(id: id), "the cached row matches a fresh store read")
        #expect(model.archiveProjection.openSummary == nil, "finalizing opens no session")
        #expect(model.pane.openArchive == nil, "the pane stays empty")
    }

    @Test("an archive write-back refreshes both the cached row and the open banner")
    func writeBackUpdatesTheCachedRowAndBanner() async throws {
        let sut = try await makeListedSUT()
        sut.model.openArchiveSession(id: sut.id)

        let landed = sut.model.applyTranslation(
            index: 0, translation: SentenceTranslation(lang: "fr", text: "Bonjour")
        )

        #expect(landed, "the write-back lands against the open archive")
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
            sut.model.pane.openArchive?.summary.languageCount(for: "fr")
                == ArchiveLanguageCount(lang: "fr", translated: 1),
            "the open summary refreshes from the projection"
        )
        #expect(
            sut.model.pane.openArchive?.summary == sut.model.archiveProjection.openSummary,
            "the open summary is the projection's one copy"
        )
        #expect(
            cachedRow(sut.model, id: sut.id) == sut.model.archiveProjection.openSummary,
            "the listed row and the open summary agree"
        )
    }

    @Test("promote, rename, and delete update the cached row and the open summary")
    func promoteRenameDeleteTrackTheCache() async throws {
        let sut = try await makeListedSUT()
        sut.model.openArchiveSession(id: sut.id)
        #expect(sut.model.pane.openArchive?.summary.saved == false)

        sut.model.promoteArchive(id: sut.id)

        #expect(cachedRow(sut.model, id: sut.id)?.saved == true, "the cached row flips to saved")
        #expect(sut.model.pane.openArchive?.summary.saved == true, "the open summary flips to saved")
        #expect(
            cachedRow(sut.model, id: sut.id) == sut.model.archiveProjection.openSummary,
            "the promotion updates both surfaces from one value"
        )

        sut.model.renameArchive(id: sut.id, name: "  Interview  ")

        #expect(
            cachedRow(sut.model, id: sut.id)?.name == "Interview",
            "the cached row carries the trimmed name"
        )
        #expect(sut.model.pane.openArchive?.summary.name == "Interview", "the open summary carries the trimmed name")
        #expect(
            cachedRow(sut.model, id: sut.id) == sut.model.archiveProjection.openSummary,
            "the rename updates both surfaces from one value"
        )

        sut.model.deleteArchive(id: sut.id)

        #expect(cachedRow(sut.model, id: sut.id) == nil, "the deleted row leaves the cache")
        #expect(sut.model.archiveProjection.openSummary == nil, "the deleted open summary clears")
        #expect(sut.model.pane.openArchive == nil, "the pane closes with the deleted session")
        #expect(sut.store.summary(id: sut.id) == nil, "the store holds nothing")
    }

    @Test("a live recording write lands in its row and adds no window row")
    func liveRecordingWriteAddsNoWindowRow() async throws {
        let store = isolatedArchive()
        let model = await makeModel(store: store)
        let id = try #require(seedRecording(store))
        model.recordingSessionID = id
        let seed = archiveSentence(0, text: "こんにちは")
        model.pane.append(seed)
        #expect(model.archiveProjection.summaries.isEmpty, "the recording row is not listed")

        let landed = model.applyTranslation(
            index: 0, translation: SentenceTranslation(lang: "en", text: "Hello")
        )

        #expect(landed, "the live row swap reports its landing")
        #expect(model.archiveProjection.summaries.isEmpty, "the window list gains no recording row")
        #expect(model.archiveProjection.openSummary == nil, "a live write opens no session")
        #expect(model.pane.openArchive == nil, "the pane stays empty")
        #expect(
            store.load(id: id)?.entries.first?.translations
                == [SentenceTranslation(lang: "en", text: "Hello")],
            "the recording row carries the write"
        )
    }

    // MARK: - Launch sweep and failures

    @Test("the launch sweep flips a cached recording row to interrupted")
    func launchSweepFlipsTheCachedRow() async throws {
        let store = isolatedArchive()
        let id = try #require(seedRecording(store), "the abandoned row is seeded before launch")
        let model = await makeModel(store: store)
        // Construction's own launch pass already flipped the abandoned row.
        #expect(cachedRow(model, id: id)?.status == .interrupted)

        model.sweepArchivesOnLaunch()

        #expect(cachedRow(model, id: id)?.status == .interrupted, "the cached row keeps its status")
        #expect(
            cachedRow(model, id: id) == store.summary(id: id),
            "the cached row matches a fresh store read"
        )
        #expect(model.archiveProjection.openSummary == nil, "the sweep opens no session")
    }

    @Test("a failed command warns but changes neither the cache nor the open summary")
    func failedCommandLeavesTheCacheAlone() async {
        let (store, cleanup) = degradedArchive()
        defer { cleanup() }
        let model = await makeModel(store: store)
        let summariesBefore = model.archiveProjection.summaries
        let openSummaryBefore = model.archiveProjection.openSummary

        model.deleteArchive(id: 7)

        #expect(model.archiveProjection.summaries == summariesBefore, "the cache keeps its rows")
        #expect(model.archiveProjection.openSummary == openSummaryBefore, "the open summary is unchanged")
        #expect(model.pane.openArchive == nil, "the pane stays empty")
        #expect(
            model.archiveProjection.availability == .openFailed,
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

    // MARK: - Landed commands

    @Test("finalize and open keep the listed row and the open summary in agreement")
    func finalizeAndOpenKeepBothSurfacesInAgreement() async throws {
        let store = isolatedArchive()
        let model = await makeModel(store: store)
        let recordingID = try #require(seedRecording(store), "the recording row is seeded after launch")
        let archiveID = try #require(
            seedFinalized(store, sentences: ["こんにちは", "さようなら"]),
            "the finalized row is seeded alongside"
        )
        model.recordingSessionID = recordingID

        #expect(model.finalizeLiveSession(durationMS: 4000), "finalize lands")
        #expect(cachedRow(model, id: recordingID)?.status == .complete, "the finalized row joins the cache")
        #expect(cachedRow(model, id: recordingID) == store.summary(id: recordingID))
        #expect(model.archiveProjection.openSummary == nil, "finalizing opens no session")

        model.openArchiveSession(id: archiveID)
        #expect(model.archiveProjection.openSummary?.id == archiveID, "opening stores the projection's open summary")
        #expect(
            model.pane.openArchive?.summary == model.archiveProjection.openSummary,
            "the pane reads the projection's open summary"
        )
    }

    @Test("language adds and write-backs keep the listed row and the open summary in agreement")
    func languageWritesKeepBothSurfacesInAgreement() async throws {
        let sut = try await makeListedSUT()
        sut.model.openArchiveSession(id: sut.id)

        #expect(sut.model.addArchiveLanguage(id: sut.id, lang: "fr"), "the membership add lands")
        #expect(
            cachedRow(sut.model, id: sut.id)?.languageCount(for: "fr")
                == ArchiveLanguageCount(lang: "fr", translated: 0),
            "the listed row carries the new membership"
        )
        #expect(
            sut.model.pane.openArchive?.summary.languageCount(for: "fr")
                == ArchiveLanguageCount(lang: "fr", translated: 0),
            "the open summary carries the new membership"
        )
        #expect(cachedRow(sut.model, id: sut.id) == sut.model.archiveProjection.openSummary)

        #expect(
            sut.model.applyTranslation(
                index: 0, translation: SentenceTranslation(lang: "fr", text: "First")
            ),
            "the first write-back lands"
        )
        #expect(
            sut.model.applyTranslation(
                index: 1, translation: SentenceTranslation(lang: "fr", text: "Second")
            ),
            "the second write-back lands"
        )
        #expect(
            cachedRow(sut.model, id: sut.id)?.languageCount(for: "fr")
                == ArchiveLanguageCount(lang: "fr", translated: 2),
            "the listed row counts both landings"
        )
        #expect(
            sut.model.openArchiveLanguageSet?.isComplete("fr") == true
                && sut.model.openArchiveLanguageSet?.sendCount("fr") == 2,
            "the open language set reads complete and re-sends the full session"
        )
        #expect(cachedRow(sut.model, id: sut.id) == sut.model.archiveProjection.openSummary)
    }

    @Test("promote, rename, and delete keep the listed row and the open summary in agreement")
    func commandsKeepBothSurfacesInAgreement() async throws {
        let sut = try await makeListedSUT()
        sut.model.openArchiveSession(id: sut.id)

        sut.model.promoteArchive(id: sut.id)
        #expect(cachedRow(sut.model, id: sut.id)?.saved == true, "the listed row flips to saved")
        #expect(sut.model.pane.openArchive?.summary.saved == true, "the open summary flips to saved")
        #expect(cachedRow(sut.model, id: sut.id) == sut.model.archiveProjection.openSummary)

        sut.model.renameArchive(id: sut.id, name: "Named")
        #expect(cachedRow(sut.model, id: sut.id)?.name == "Named", "the listed row carries the new name")
        #expect(sut.model.pane.openArchive?.summary.name == "Named", "the open summary carries the new name")
        #expect(cachedRow(sut.model, id: sut.id) == sut.model.archiveProjection.openSummary)

        sut.model.deleteArchive(id: sut.id)
        #expect(cachedRow(sut.model, id: sut.id) == nil, "the deleted row leaves the cache")
        #expect(sut.model.archiveProjection.openSummary == nil, "the deleted open summary clears")
        #expect(sut.model.pane.openArchive == nil, "the pane closes with the deleted session")
        #expect(sut.store.summary(id: sut.id) == nil, "the store holds nothing")
    }

    @Test("append and pause leave the cached list and the open summary alone")
    func passiveWritesLeaveBothSurfacesAlone() async throws {
        let store = isolatedArchive()
        let model = await makeModel(store: store)
        let recordingID = try #require(seedRecording(store))
        let summariesBefore = model.archiveProjection.summaries

        let appended = model.archiveProjection.append(
            sentence: archiveSentence(1, text: "おはよう"), sessionID: recordingID, metadata: archiveMetadata(target: "en")
        )
        #expect(appended == recordingID, "the projection's append lands against the row")
        #expect(
            model.archiveProjection.syncPaused(session: recordingID, pausedMS: 2000),
            "the pause sync lands"
        )
        #expect(model.archiveProjection.summaries == summariesBefore, "append and syncPaused leave the list alone")
        #expect(model.archiveProjection.openSummary == nil, "append and syncPaused leave the open summary alone")
    }
}
