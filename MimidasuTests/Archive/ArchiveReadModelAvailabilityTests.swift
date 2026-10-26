import Foundation
@testable import Mimidasu
import Testing

/// The read model's availability contract: a load that cannot open the
/// archive, a refresh on a terminally degraded store, a refresh that clears a
/// transient read failure, and a refresh that cannot open the archive.
@MainActor
@Suite("ArchiveReadModel availability")
struct ArchiveReadModelAvailabilityTests {

    // MARK: - Availability

    @Test("a load that cannot open the archive reports openFailed")
    func reloadReportsOpenFailed() {
        let store = isolatedArchive()
        let model = ArchiveReadModel(
            store: store,
            loadSummaries: { .failure(.openFailed) },
            loadSummary: { _ in .failure(.openFailed) }
        )

        #expect(model.availability == .openFailed)
        #expect(!model.isAvailable)
        #expect(model.summaries.isEmpty)
    }

    @Test("a row refresh on a degraded store reports openFailed without reading")
    func refreshRowOnDegradedStoreReportsOpenFailed() {
        let (store, cleanup) = ArchiveReadModelFixtures.degradedStore()
        defer { cleanup() }
        let recorder = LoadRecorder()
        let model = ArchiveReadModelFixtures.makeModel(store: store, recorder: recorder)

        model.refreshRow(id: 1)

        #expect(model.availability == .openFailed)
        #expect(!model.isAvailable)
        #expect(recorder.summaryCalls == 0)
        #expect(model.summaries.isEmpty)
    }

    @Test("a row refresh that succeeds clears a read failure")
    func refreshRowClearsReadFailure() {
        let store = isolatedArchive()
        guard let id = ArchiveReadModelFixtures.finalizeSession(store, startedAt: 1000) else {
            Issue.record("seed should succeed")
            return
        }
        let refreshed = ArchivedSessionSummary(
            id: id,
            status: .complete,
            saved: false,
            startedAt: Date(timeIntervalSince1970: 1000),
            durationS: 5,
            pausedMS: 0,
            sentenceCount: 1,
            targetLang: "en",
            model: "test-model",
            chunkMS: 160,
            name: "Refreshed",
            firstSentence: "こんにちは"
        )
        let recorder = LoadRecorder()
        let model = ArchiveReadModel(
            store: store,
            loadSummaries: { store.loadSummaries() },
            loadSummary: { _ in
                recorder.summaryCalls += 1
                if recorder.summaryCalls == 1 {
                    return .failure(.readFailed)
                }
                return .success(refreshed)
            }
        )

        model.refreshRow(id: id)
        #expect(model.availability == .readFailed)
        model.refreshRow(id: id)

        #expect(model.availability == .available)
        #expect(model.isAvailable)
        #expect(model.summaries.first { row in row.id == id }?.name == "Refreshed")
    }

    @Test("a row refresh that cannot open the archive reports openFailed and keeps the rows")
    func refreshRowOpenFailedKeepsTheCachedRows() {
        let store = isolatedArchive()
        guard let id = ArchiveReadModelFixtures.finalizeSession(store, startedAt: 1000) else {
            Issue.record("seed should succeed")
            return
        }
        let model = ArchiveReadModel(
            store: store,
            loadSummaries: { store.loadSummaries() },
            loadSummary: { _ in .failure(.openFailed) }
        )
        let before = model.summaries

        model.refreshRow(id: id)

        #expect(model.availability == .openFailed)
        #expect(!model.isAvailable)
        #expect(model.summaries == before)
    }
}
