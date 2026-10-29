import Foundation
@testable import Mimidasu
import Testing

/// The projection's availability contract: a load that cannot open the
/// archive, a refresh on a terminally degraded store, a refresh that clears a
/// transient read failure, and a refresh that cannot open the archive.
@MainActor
@Suite("ArchiveProjection availability")
struct ArchiveProjectionAvailabilityTests {

    // MARK: - Availability

    @Test("a load that cannot open the archive reports openFailed")
    func reloadReportsOpenFailed() {
        let store = isolatedArchive()
        let model = ArchiveProjection(
            store: store,
            loadSummaries: { .failure(.openFailed) },
            loadSummary: { _ in .failure(.openFailed) }
        )

        #expect(model.availability == .openFailed)
        #expect(!model.isAvailable)
        #expect(model.summaries.isEmpty)
    }

    @Test("a touch on a degraded store reports openFailed without reading")
    func refreshTouchedOnDegradedStoreReportsOpenFailed() {
        let (store, cleanup) = ArchiveProjectionFixtures.degradedStore()
        defer { cleanup() }
        let recorder = LoadRecorder()
        let model = ArchiveProjectionFixtures.makeProjection(store: store, recorder: recorder)

        model.refreshTouched(id: 1)

        #expect(model.availability == .openFailed)
        #expect(!model.isAvailable)
        #expect(recorder.summaryCalls == 0)
        #expect(model.summaries.isEmpty)
    }

    @Test("a touch that succeeds clears a read failure")
    func refreshTouchedClearsReadFailureAndSwapsTheRow() {
        let store = isolatedArchive()
        guard let id = ArchiveProjectionFixtures.finalizeSession(store, startedAt: 1000) else {
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
        let model = ArchiveProjection(
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

        model.refreshTouched(id: id)
        #expect(model.availability == .readFailed)
        model.refreshTouched(id: id)

        #expect(model.availability == .available)
        #expect(model.isAvailable)
        #expect(model.summaries.first { row in row.id == id }?.name == "Refreshed")
    }

    @Test("a touch that cannot open the archive reports openFailed and keeps the rows")
    func refreshTouchedOpenFailedKeepsTheCachedRows() {
        let store = isolatedArchive()
        guard let id = ArchiveProjectionFixtures.finalizeSession(store, startedAt: 1000) else {
            Issue.record("seed should succeed")
            return
        }
        let model = ArchiveProjection(
            store: store,
            loadSummaries: { store.loadSummaries() },
            loadSummary: { _ in .failure(.openFailed) }
        )
        let before = model.summaries

        model.refreshTouched(id: id)

        #expect(model.availability == .openFailed)
        #expect(!model.isAvailable)
        #expect(model.summaries == before)
    }
}
