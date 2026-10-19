import Foundation
@testable import Mimidasu
import Testing

/// Counts the read model's typed reads so a test can pin exactly which reads
/// one operation triggered.
@MainActor
private final class LoadRecorder {
    var summariesCalls = 0
    var summaryCalls = 0
}

/// The read model's caching contract: construction loads once, a failed read
/// keeps the previous rows with a typed availability, and a landed mutation
/// bumps the revision with at most a single-row refresh.
@MainActor
@Suite("ArchiveReadModel")
struct ArchiveReadModelTests {

    // MARK: - Fixtures

    private func metadata(startedAt: TimeInterval = 1_000_000) -> SessionMetadata {
        SessionMetadata(
            startedAt: Date(timeIntervalSince1970: startedAt),
            sourceLang: "ja",
            targetLang: "en",
            model: "test-model",
            chunkMS: 160
        )
    }

    private func sentence(_ index: Int, text: String = "こんにちは") -> Sentence {
        Sentence(index: index, startS: 0, endS: 1.5, lang: "ja", text: text)
    }

    /// A finalized recent with one sentence, dated `startedAt`.
    @discardableResult
    private func finalizeSession(_ store: ArchiveStore, startedAt: TimeInterval) -> Int64? {
        guard let id = store.append(
            sentence: sentence(0), sessionID: nil, metadata: metadata(startedAt: startedAt)
        ) else { return nil }
        store.finalize(session: id, durationMS: 5000, saved: false)
        return id
    }

    /// A recording row with one sentence — absent from the list until it is
    /// finalized or swept.
    private func recordingSession(_ store: ArchiveStore, startedAt: TimeInterval) -> Int64? {
        store.append(sentence: sentence(0), sessionID: nil, metadata: metadata(startedAt: startedAt))
    }

    /// The model over `store` with counting reads for both entry points.
    private func makeModel(store: ArchiveStore, recorder: LoadRecorder) -> ArchiveReadModel {
        ArchiveReadModel(
            store: store,
            loadSummaries: {
                recorder.summariesCalls += 1
                return store.loadSummaries()
            },
            loadSummary: { id in
                recorder.summaryCalls += 1
                return store.summaryResult(id: id)
            }
        )
    }

    /// A store whose database cannot open: a file where the parent directory
    /// should be.
    private func degradedStore() -> (ArchiveStore, () -> Void) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mimidasu-archive-read-model-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let blocker = root.appendingPathComponent("blocker")
        try? Data().write(to: blocker)
        return (
            ArchiveStore(location: blocker.appendingPathComponent("archives.sqlite")),
            { try? FileManager.default.removeItem(at: root) }
        )
    }

    // MARK: - Loading

    @Test("init loads the summaries once and reports available")
    func initLoadsOnceAndAvailable() throws {
        let store = isolatedArchive()
        guard finalizeSession(store, startedAt: 1000) != nil else {
            Issue.record("seed should succeed")
            return
        }
        let recorder = LoadRecorder()
        let model = makeModel(store: store, recorder: recorder)

        let storeRows = try store.loadSummaries().get()
        #expect(recorder.summariesCalls == 1)
        #expect(recorder.summaryCalls == 0)
        #expect(model.summaries == storeRows)
        #expect(model.availability == .available)
        #expect(model.isAvailable)
    }

    @Test("a degraded store reports openFailed without calling the loader")
    func degradedStoreIsOpenFailed() {
        let (store, cleanup) = degradedStore()
        defer { cleanup() }
        let recorder = LoadRecorder()
        let model = makeModel(store: store, recorder: recorder)

        #expect(model.availability == .openFailed)
        #expect(!model.isAvailable)
        #expect(model.summaries.isEmpty)
        #expect(recorder.summariesCalls == 0)
        #expect(recorder.summaryCalls == 0)
    }

    @Test("a failed load is readFailed, not an empty archive")
    func failedLoadIsReadFailedNotEmpty() {
        let store = isolatedArchive()
        let recorder = LoadRecorder()
        let model = ArchiveReadModel(
            store: store,
            loadSummaries: {
                recorder.summariesCalls += 1
                return .failure(.readFailed)
            }
        )

        #expect(model.availability == .readFailed)
        #expect(!model.isAvailable)
        #expect(model.summaries.isEmpty)
        #expect(recorder.summariesCalls == 1)
    }

    @Test("reload recovers from a read failure without touching the revision")
    func reloadRecoversFromReadFailure() {
        let store = isolatedArchive()
        guard let id = finalizeSession(store, startedAt: 1000) else {
            Issue.record("seed should succeed")
            return
        }
        let recorder = LoadRecorder()
        let model = ArchiveReadModel(
            store: store,
            loadSummaries: {
                recorder.summariesCalls += 1
                if recorder.summariesCalls == 1 {
                    return .failure(.readFailed)
                }
                return store.loadSummaries()
            }
        )
        let revision = model.revision

        #expect(model.availability == .readFailed)
        model.reload()

        #expect(recorder.summariesCalls == 2)
        #expect(model.availability == .available)
        #expect(model.summaries.map(\.id) == [id])
        #expect(model.revision == revision)
    }

    @Test("reloadIfUnavailable retries only after a read failure")
    func reloadIfUnavailableRetriesOnlyAfterReadFailure() {
        let store = isolatedArchive()
        guard finalizeSession(store, startedAt: 1000) != nil else {
            Issue.record("seed should succeed")
            return
        }
        let recorder = LoadRecorder()
        let model = ArchiveReadModel(
            store: store,
            loadSummaries: {
                recorder.summariesCalls += 1
                if recorder.summariesCalls == 1 {
                    return .failure(.readFailed)
                }
                return store.loadSummaries()
            }
        )

        #expect(model.availability == .readFailed)
        model.reloadIfUnavailable()

        #expect(model.availability == .available)
        #expect(recorder.summariesCalls == 2)

        model.reloadIfUnavailable()
        #expect(recorder.summariesCalls == 2, "available rows never re-read on appear")
    }

    @Test("a landed write exposes the new summaries and revision to observers")
    func observationTracksRevisionAndSummaries() async {
        let store = isolatedArchive()
        let model = ArchiveReadModel(store: store)
        guard let id = model.append(sentence: sentence(0), sessionID: nil, metadata: metadata(startedAt: 1000)) else {
            Issue.record("append should succeed")
            return
        }
        let rows = ObservedValuesRecorder<[ArchivedSessionSummary]>(read: { model.summaries })
        let revision = ObservedValuesRecorder<Int>(read: { model.revision })

        #expect(model.finalize(session: id, durationMS: 4000, saved: false))

        #expect(await pollUntil { !rows.values.isEmpty })
        #expect(await pollUntil { revision.values.last == 1 })
        #expect(rows.values.last?.map(\.id) == [id])
    }
}

// MARK: - Mutations

extension ArchiveReadModelTests {

    @Test("append and syncPaused neither reload nor bump")
    func appendAndSyncPausedDoNotReloadOrBump() {
        let store = isolatedArchive()
        let recorder = LoadRecorder()
        let model = makeModel(store: store, recorder: recorder)
        let summariesCalls = recorder.summariesCalls
        let revision = model.revision

        guard let id = model.append(sentence: sentence(0), sessionID: nil, metadata: metadata()) else {
            Issue.record("append should succeed")
            return
        }
        #expect(model.syncPaused(session: id, pausedMS: 4200))

        #expect(recorder.summariesCalls == summariesCalls)
        #expect(recorder.summaryCalls == 0)
        #expect(model.revision == revision)
        #expect(!model.summaries.contains { row in row.id == id })
    }

    @Test("an upsert on a listed row refreshes just that row and bumps")
    func upsertListedRowRefreshesAndBumps() throws {
        let store = isolatedArchive()
        guard let id = finalizeSession(store, startedAt: 1000) else {
            Issue.record("seed should succeed")
            return
        }
        let recorder = LoadRecorder()
        let model = makeModel(store: store, recorder: recorder)

        #expect(model.upsert(translation: SentenceTranslation(lang: "fr", text: "Bonjour"), index: 0, session: id))

        #expect(recorder.summaryCalls == 1)
        #expect(recorder.summariesCalls == 1)
        #expect(model.revision == 1)
        let cached = model.summaries.first { row in row.id == id }
        let stored = try store.loadSummaries().get().first { row in row.id == id }
        #expect(cached == stored)
        #expect(cached?.languageCount(for: "fr")?.translated == 1)
    }

    @Test("an upsert on a recording row bumps without any read")
    func upsertRecordingRowBumpsWithoutReads() {
        let store = isolatedArchive()
        guard let id = recordingSession(store, startedAt: 1000) else {
            Issue.record("seed should succeed")
            return
        }
        let recorder = LoadRecorder()
        let model = makeModel(store: store, recorder: recorder)

        #expect(model.upsert(translation: SentenceTranslation(lang: "fr", text: "Bonjour"), index: 0, session: id))

        #expect(recorder.summaryCalls == 0)
        #expect(recorder.summariesCalls == 1, "init is the only list read")
        #expect(model.revision == 1)
        #expect(model.summaries.isEmpty)
    }

    @Test("an upsert on one listed row leaves the other rows alone")
    func foreignListedRowRefreshes() {
        let store = isolatedArchive()
        guard let first = finalizeSession(store, startedAt: 1000),
              let second = finalizeSession(store, startedAt: 2000)
        else {
            Issue.record("seed should succeed")
            return
        }
        let recorder = LoadRecorder()
        let model = makeModel(store: store, recorder: recorder)

        #expect(model.upsert(translation: SentenceTranslation(lang: "fr", text: "Bonjour"), index: 0, session: second))

        #expect(recorder.summaryCalls == 1)
        #expect(recorder.summariesCalls == 1)
        #expect(model.revision == 1)
        #expect(model.summaries.first { row in row.id == second }?.languageCount(for: "fr") != nil)
        #expect(model.summaries.first { row in row.id == first }?.languageCount(for: "fr") == nil)
    }

    @Test("addLanguage, rename, and promote each refresh their listed row")
    func addLanguageRenamePromoteRefreshListedRows() {
        let store = isolatedArchive()
        guard let id = finalizeSession(store, startedAt: 1000) else {
            Issue.record("seed should succeed")
            return
        }
        let recorder = LoadRecorder()
        let model = makeModel(store: store, recorder: recorder)

        #expect(model.addLanguage(id: id, lang: "fr"))
        #expect(model.revision == 1)
        #expect(recorder.summaryCalls == 1)
        #expect(model.summaries.first { row in row.id == id }?.languageCount(for: "fr") != nil)

        #expect(model.rename(id: id, name: "  Interview  "))
        #expect(model.revision == 2)
        #expect(recorder.summaryCalls == 2)
        #expect(model.summaries.first { row in row.id == id }?.name == "Interview")

        #expect(model.promote(id: id))
        #expect(model.revision == 3)
        #expect(recorder.summaryCalls == 3)
        #expect(model.summaries.first { row in row.id == id }?.saved == true)
        #expect(recorder.summariesCalls == 1, "no full re-read on any of the three")
    }

    @Test("delete drops the cached row without any read")
    func deleteRemovesRowWithoutRead() {
        let store = isolatedArchive()
        guard let id = finalizeSession(store, startedAt: 1000) else {
            Issue.record("seed should succeed")
            return
        }
        let recorder = LoadRecorder()
        let model = makeModel(store: store, recorder: recorder)

        #expect(model.delete(id: id))

        #expect(model.summaries.isEmpty)
        #expect(model.revision == 1)
        #expect(recorder.summaryCalls == 0)
        #expect(recorder.summariesCalls == 1)
    }

    @Test("finalize reloads and lists the new row at the store's order")
    func finalizeReloadsAndInserts() throws {
        let store = isolatedArchive()
        let recorder = LoadRecorder()
        let model = makeModel(store: store, recorder: recorder)

        guard let id = model.append(sentence: sentence(0), sessionID: nil, metadata: metadata(startedAt: 1000)) else {
            Issue.record("append should succeed")
            return
        }
        #expect(model.summaries.isEmpty)

        #expect(model.finalize(session: id, durationMS: 4000, saved: false))

        #expect(recorder.summariesCalls == 2)
        #expect(model.revision == 1)
        let storedIDs = try store.loadSummaries().get().map(\.id)
        #expect(storedIDs == [id])
        #expect(model.summaries.map(\.id) == storedIDs)
    }

    @Test("the sweep reloads and flips the cached row to interrupted")
    func sweepReloadsAndFlipsStatus() {
        let store = isolatedArchive()
        guard let id = recordingSession(store, startedAt: 1000) else {
            Issue.record("seed should succeed")
            return
        }
        let recorder = LoadRecorder()
        let model = makeModel(store: store, recorder: recorder)
        #expect(model.summaries.isEmpty)

        #expect(model.sweepInterrupted())

        #expect(recorder.summariesCalls == 2)
        #expect(model.revision == 1)
        #expect(model.summaries.first { row in row.id == id }?.status == .interrupted)
    }

    @Test("a row refresh drops a row the store no longer holds")
    func refreshRowRemovesRowMissingFromTheStore() {
        let store = isolatedArchive()
        guard let id = finalizeSession(store, startedAt: 1000) else {
            Issue.record("seed should succeed")
            return
        }
        let recorder = LoadRecorder()
        let model = makeModel(store: store, recorder: recorder)

        #expect(store.delete(id: id))
        model.refreshRow(id: id)

        #expect(model.summaries.isEmpty)
        #expect(model.availability == .available)
        #expect(model.revision == 0)
        #expect(recorder.summaryCalls == 1)
        #expect(recorder.summariesCalls == 1)
    }

    @Test("a failed write changes neither the revision nor the cache")
    func lostWritesChangeNothing() {
        let store = isolatedArchive()
        guard let id = finalizeSession(store, startedAt: 1000) else {
            Issue.record("seed should succeed")
            return
        }
        let recorder = LoadRecorder()
        let model = makeModel(store: store, recorder: recorder)
        let before = model.summaries
        let revision = model.revision

        #expect(store.delete(id: id), "the row vanishes underneath the model")
        #expect(model.upsert(translation: SentenceTranslation(lang: "fr", text: "Bonjour"), index: 0, session: id) == false)

        #expect(model.revision == revision)
        #expect(model.summaries == before)
        #expect(recorder.summaryCalls == 0)
        #expect(recorder.summariesCalls == 1)
    }

    @Test("failed mutations on a degraded store change nothing")
    func degradedStoreMutationsFailWithoutReadsOrBumps() {
        let (store, cleanup) = degradedStore()
        defer { cleanup() }
        let recorder = LoadRecorder()
        let model = makeModel(store: store, recorder: recorder)

        #expect(model.append(sentence: sentence(0), sessionID: 1, metadata: metadata()) == nil)
        #expect(model.syncPaused(session: 1, pausedMS: 10) == false)
        #expect(model.upsert(translation: SentenceTranslation(lang: "fr", text: "x"), index: 0, session: 1) == false)
        #expect(model.finalize(session: 1, durationMS: 10, saved: false) == false)
        #expect(model.sweepInterrupted() == false)
        #expect(model.addLanguage(id: 1, lang: "fr") == false)
        #expect(model.rename(id: 1, name: "x") == false)
        #expect(model.promote(id: 1) == false)
        #expect(model.delete(id: 1) == false)

        #expect(model.revision == 0)
        #expect(recorder.summariesCalls == 0)
        #expect(recorder.summaryCalls == 0)
        #expect(model.summaries.isEmpty)
        #expect(model.availability == .openFailed)
    }

    @Test("a failed row refresh keeps the old row and reports readFailed")
    func failedRowRefreshKeepsOldRowAndSetsReadFailed() {
        let store = isolatedArchive()
        guard let id = finalizeSession(store, startedAt: 1000) else {
            Issue.record("seed should succeed")
            return
        }
        let recorder = LoadRecorder()
        let model = ArchiveReadModel(
            store: store,
            loadSummaries: {
                recorder.summariesCalls += 1
                return store.loadSummaries()
            },
            loadSummary: { _ in
                recorder.summaryCalls += 1
                return .failure(.readFailed)
            }
        )
        let before = model.summaries

        #expect(model.upsert(translation: SentenceTranslation(lang: "fr", text: "Bonjour"), index: 0, session: id))

        #expect(model.revision == 1)
        #expect(recorder.summaryCalls == 1)
        #expect(model.summaries == before)
        #expect(model.availability == .readFailed)
        #expect(!model.isAvailable)
    }

    @Test("a row inserted by refresh keeps the newest-first order")
    func incrementalInsertKeepsNewestFirstOrder() throws {
        let store = isolatedArchive()
        guard let first = finalizeSession(store, startedAt: 1000) else {
            Issue.record("seed should succeed")
            return
        }
        let recorder = LoadRecorder()
        let model = makeModel(store: store, recorder: recorder)

        guard let second = recordingSession(store, startedAt: 2000) else {
            Issue.record("second seed should succeed")
            return
        }
        #expect(store.finalize(session: second, durationMS: 4000, saved: false))

        model.refreshRow(id: second)

        #expect(recorder.summaryCalls == 1)
        #expect(recorder.summariesCalls == 1)
        #expect(model.revision == 0)
        let storedIDs = try store.loadSummaries().get().map(\.id)
        #expect(storedIDs == [second, first])
        #expect(model.summaries.map(\.id) == storedIDs)
    }
}

// MARK: - Typed reads

/// The typed-read mapping on the store itself, kept in the store's suite from
/// this file: the suite's own file sits two lines under the lint ceiling.
extension ArchiveStoreTests {

    @Test("read failure mapping separates a terminal open from a transient read")
    func readFailureMappingDistinguishesOpenFromTransient() {
        let success: Result<Int, ArchiveStore.ReadFailure> = ArchiveStore.mapReadFailure({ 7 }, isDegraded: false)
        #expect(success == .success(7))

        let throwingBody = { () throws -> Int in
            throw ArchiveStore.ReadFailure.readFailed
        }
        #expect(ArchiveStore.mapReadFailure(throwingBody, isDegraded: true) == .failure(.openFailed))
        #expect(ArchiveStore.mapReadFailure(throwingBody, isDegraded: false) == .failure(.readFailed))
    }

    @Test("typed reads on a degraded store report an open failure")
    func loadSummariesOnADegradedStoreIsOpenFailed() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mimidasu-archive-typed-blocked-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // A *file* where the database's parent directory should be: the open
        // can never succeed.
        let blocker = root.appendingPathComponent("blocker")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? Data().write(to: blocker)

        let store = ArchiveStore(location: blocker.appendingPathComponent("archives.sqlite"))

        #expect(store.loadSummaries() == .failure(.openFailed))
        #expect(store.summaryResult(id: 1) == .failure(.openFailed))
        #expect(store.list().isEmpty)
        #expect(store.summary(id: 1) == nil)
    }
}
