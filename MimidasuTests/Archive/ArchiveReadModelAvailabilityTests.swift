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

/// The read model's availability contract: a load that cannot open the
/// archive, a refresh on a terminally degraded store, a refresh that clears a
/// transient read failure, and a refresh that cannot open the archive.
@MainActor
@Suite("ArchiveReadModel availability")
struct ArchiveReadModelAvailabilityTests {

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
            .appendingPathComponent("mimidasu-archive-read-availability-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let blocker = root.appendingPathComponent("blocker")
        try? Data().write(to: blocker)
        return (
            ArchiveStore(location: blocker.appendingPathComponent("archives.sqlite")),
            { try? FileManager.default.removeItem(at: root) }
        )
    }

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
        let (store, cleanup) = degradedStore()
        defer { cleanup() }
        let recorder = LoadRecorder()
        let model = makeModel(store: store, recorder: recorder)

        model.refreshRow(id: 1)

        #expect(model.availability == .openFailed)
        #expect(!model.isAvailable)
        #expect(recorder.summaryCalls == 0)
        #expect(model.summaries.isEmpty)
    }

    @Test("a row refresh that succeeds clears a read failure")
    func refreshRowClearsReadFailure() {
        let store = isolatedArchive()
        guard let id = finalizeSession(store, startedAt: 1000) else {
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
        guard let id = finalizeSession(store, startedAt: 1000) else {
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
