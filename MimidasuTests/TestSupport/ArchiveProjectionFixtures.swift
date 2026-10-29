import Foundation
@testable import Mimidasu

/// Counts the projection's typed reads so a test can pin exactly which reads
/// one operation triggered.
@MainActor
final class LoadRecorder {
    var summariesCalls = 0
    var summaryCalls = 0
    var sessionCalls = 0
}

/// Shared seeds for the projection's suites: a sentence and its metadata, a
/// finalized recent, a counting projection, and a store whose database cannot
/// open.
@MainActor
enum ArchiveProjectionFixtures {
    static func metadata(startedAt: TimeInterval = 1_000_000) -> SessionMetadata {
        SessionMetadata(
            startedAt: Date(timeIntervalSince1970: startedAt),
            sourceLang: "ja",
            targetLang: "en",
            model: "test-model",
            chunkMS: 160
        )
    }

    static func sentence(_ index: Int, text: String = "こんにちは") -> Sentence {
        Sentence(index: index, startS: 0, endS: 1.5, lang: "ja", text: text)
    }

    /// A finalized recent with one sentence, dated `startedAt`.
    @discardableResult
    static func finalizeSession(_ store: ArchiveStore, startedAt: TimeInterval) -> Int64? {
        guard let id = store.append(
            sentence: sentence(0), sessionID: nil,
            metadata: metadata(startedAt: startedAt)
        ) else { return nil }
        store.finalize(session: id, durationMS: 5000, saved: false)
        return id
    }

    /// The projection over `store` with counting reads for all three entry
    /// points.
    static func makeProjection(store: ArchiveStore, recorder: LoadRecorder) -> ArchiveProjection {
        ArchiveProjection(
            store: store,
            loadSummaries: {
                recorder.summariesCalls += 1
                return store.loadSummaries()
            },
            loadSummary: { id in
                recorder.summaryCalls += 1
                return store.summaryResult(id: id)
            },
            loadSession: { id in
                recorder.sessionCalls += 1
                return store.load(id: id)
            }
        )
    }

    /// A store whose database cannot open: a file where the parent directory
    /// should be.
    static func degradedStore(
        prefix: String = "mimidasu-archive-projection"
    ) -> (ArchiveStore, () -> Void) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let blocker = root.appendingPathComponent("blocker")
        try? Data().write(to: blocker)
        return (
            ArchiveStore(location: blocker.appendingPathComponent("archives.sqlite")),
            { try? FileManager.default.removeItem(at: root) }
        )
    }
}
