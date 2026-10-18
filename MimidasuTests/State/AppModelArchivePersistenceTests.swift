import Foundation
@testable import Mimidasu
import Testing

/// `AppModel`'s continuous persistence over a begin-driven live session
/// (scripted capture/engine): the lazy recording row, the stop-time
/// finalize + Recent toast, the empty-session no-op, the launch sweep, and
/// the degraded-store latch (one warning toast, no finalize, no toast on
/// stop).
@MainActor
@Suite(
    "AppModel archive persistence",
    .enabled(if: DictionaryStore.resolve() != nil && InstalledJMDict.url != nil)
)
struct AppModelArchivePersistenceTests {

    // MARK: - Fixtures

    private final class ScriptedASREngine: ASREngine, @unchecked Sendable {
        let isMock = true
        var onEngineError: ((String) -> Void)?
        var processedSamples = 0
        var pushedSamples = 0

        private let finals: [ASREvent]
        private var remaining: [ASREvent]

        init(finals: [ASREvent]) {
            self.finals = finals
            remaining = finals
        }

        func prepare() {}

        func openStream() {}

        func push(_ samples: [Float]) {}

        func poll() -> ASREvent? {
            remaining.isEmpty ? nil : remaining.removeFirst()
        }

        func finish() -> [ASREvent] {
            []
        }

        func flushUtterance() -> [ASREvent] {
            []
        }
    }

    private final class ScriptedCapture: AudioCapturing, @unchecked Sendable {
        var onChunk: ((AudioChunk) -> Void)?
        var onIOError: ((CaptureError) -> Void)?

        func start() async throws {}
        func stop() {}
        func pause() async {}
        func resume() async throws {}
    }

    private struct SUT {
        let model: AppModel
        let store: ArchiveStore
    }

    /// A model whose session engine emits `finals` (one per poll) over
    /// scripted doubles, persisting into `store`.
    private func makeSUT(
        finals: [ASREvent] = [], store: ArchiveStore = isolatedArchive()
    ) async -> SUT {
        let engine = ScriptedASREngine(finals: finals)
        let capture = ScriptedCapture()
        let model = AppModel(
            makeSessionController: { live, latency, _, translationQueue in
                SessionController(
                    live: live, latency: latency, translationQueue: translationQueue,
                    makeEngine: { _, _ in engine },
                    makeCapture: { capture },
                    warmUpEnabled: { false }
                )
            },
            translationSettings: isolatedTranslationSettings(suite: "test.AppModelArchivePersistence"),
            asrModelSettings: isolatedASRModelSettings(suite: "test.AppModelArchivePersistence"),
            favorites: isolatedFavorites(),
            archive: store,
            highFidelityProbe: { _ in false },
            initialModelResolve: { _ in nil },
            retireWarmEngine: {}
        )
        await model.initialModelCheck?.value
        await model.refreshModelAvailability(
            resolve: { _ in URL(fileURLWithPath: "/tmp/model.gguf") }
        )
        return SUT(model: model, store: store)
    }

    private func startRunning(_ sut: SUT) async {
        sut.model.start()
        #expect(await pollUntil { sut.model.phase == .running }, "session comes up")
    }

    private func stop(_ sut: SUT) async {
        sut.model.stop()
        // Stop's queue drain is bounded by `SessionController.translationDrainTimeout`
        // (5 s): with a landed sentence and no hosted `.translationTask` in
        // tests, nothing consumes the backlog, so the stop waits it out.
        #expect(await pollUntil(timeout: 8) { sut.model.phase == .idle }, "stop winds down")
    }

    private let sentenceFinal = ASREvent.final(
        text: "こんにちは。", startSample: 0, endSample: 16000, lang: "ja"
    )

    // MARK: - Lazy recording row

    @Test("the first sentence creates the recording row; stop finalizes it")
    func firstSentenceCreatesAndStopFinalizes() async {
        let sut = await makeSUT(finals: [sentenceFinal])
        await startRunning(sut)
        #expect(sut.model.recordingSessionID == nil)

        #expect(await pollUntil { sut.model.recordingSessionID != nil }, "first sentence persists")
        #expect(sut.model.entries.count == 1)
        #expect(sut.store.list().isEmpty, "a recording row is not listed")

        await stop(sut)

        #expect(sut.model.recordingSessionID == nil)
        guard let summary = sut.store.list().first else {
            Issue.record("stop finalizes the session into the archive")
            return
        }
        #expect(summary.status == .complete)
        #expect(summary.saved == false)
        #expect(summary.sentenceCount == 1)
        #expect(summary.durationS != nil)
        #expect(sut.model.toasts.toasts.contains { toast in toast.key == ToastKey.archiveRecent })
    }

    @Test("later sentences reuse the recording row and keep appending")
    func laterSentencesAppendToSameRow() async {
        let sut = await makeSUT(finals: [
            sentenceFinal,
            .final(text: "さようなら。", startSample: 16000, endSample: 32000, lang: "ja")
        ])
        await startRunning(sut)
        #expect(await pollUntil { sut.model.entries.count == 2 }, "both sentences land")

        guard let id = sut.model.recordingSessionID,
              let loaded = sut.store.load(id: id)
        else {
            Issue.record("recording session should load mid-flight")
            return
        }
        #expect(loaded.entries.count == 2)
        #expect(loaded.summary.status == .recording)

        await stop(sut)
        #expect(sut.store.list().first?.sentenceCount == 2)
    }

    @Test("a session stopped without sentences persists nothing")
    func emptySessionPersistsNothing() async {
        let sut = await makeSUT()
        await startRunning(sut)

        await stop(sut)

        #expect(sut.store.list().isEmpty)
        #expect(!sut.model.toasts.toasts.contains { toast in toast.key == ToastKey.archiveRecent })
    }

    // MARK: - Launch sweep

    @Test("the launch sweep turns an abandoned recording row into an interrupted recent")
    func sweepFlipsAbandonedRecording() async {
        let store = isolatedArchive()
        let sut = await makeSUT(store: store)
        let abandoned = store.append(
            sentence: Sentence(index: 0, startS: 0, endS: 1.5, lang: "ja", text: "こんにちは"),
            sessionID: nil,
            metadata: SessionMetadata(
                startedAt: Date(timeIntervalSince1970: 500_000),
                sourceLang: "ja", targetLang: "en", model: "test-model", chunkMS: 160
            )
        )
        #expect(abandoned != nil)
        let revisionBefore = sut.model.archiveRevision

        sut.model.sweepArchivesOnLaunch()

        #expect(sut.store.list().first?.status == .interrupted)
        #expect(sut.model.archiveRevision != revisionBefore)
    }

    // MARK: - Degraded store

    @Test("a degraded store latches one warning toast and skips finalize")
    func degradedStoreLatchesOnce() async {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mimidasu-archive-degraded-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let blocker = root.appendingPathComponent("blocker")
        try? Data().write(to: blocker)
        let store = ArchiveStore(location: blocker.appendingPathComponent("archives.sqlite"))
        #expect(store.isDegraded)

        let sut = await makeSUT(finals: [
            sentenceFinal,
            .final(text: "さようなら。", startSample: 16000, endSample: 32000, lang: "ja")
        ], store: store)
        await startRunning(sut)
        #expect(await pollUntil { sut.model.archiveWriteFailed }, "the failed write latches")
        #expect(!sut.model.archiveAvailable)
        #expect(await pollUntil { sut.model.entries.count == 2 }, "transcription continues regardless")

        let warnings = sut.model.toasts.toasts.filter { toast in toast.key == ToastKey.archiveUnavailable }
        #expect(warnings.count == 1, "one warning for the whole session")

        await stop(sut)
        #expect(sut.store.list().isEmpty)
        #expect(!sut.model.toasts.toasts.contains { toast in toast.key == ToastKey.archiveRecent })
    }
}
