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

        private var remaining: [ASREvent]

        init(finals: [ASREvent]) {
            remaining = finals
        }

        /// Appends one more final; the poll tick picks it up on its next fire
        /// — the deterministic way to place a sentence in a chosen session.
        func enqueue(_ event: ASREvent) {
            remaining.append(event)
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
        let engine: ScriptedASREngine
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
        return SUT(model: model, store: store, engine: engine)
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

    /// A store whose database path sits under a regular file, so the open
    /// fails terminally and every write fails. Returns the temp root for the
    /// caller's cleanup.
    private func makeDegradedStore() -> (store: ArchiveStore, root: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mimidasu-archive-degraded-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let blocker = root.appendingPathComponent("blocker")
        try? Data().write(to: blocker)
        let store = ArchiveStore(location: blocker.appendingPathComponent("archives.sqlite"))
        return (store, root)
    }

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

    @Test("a second session with sentences gets its own archive row")
    func secondSessionGetsOwnRow() async {
        let sut = await makeSUT()
        await startRunning(sut)
        sut.engine.enqueue(sentenceFinal)
        #expect(await pollUntil { sut.model.recordingSessionID != nil }, "the first sentence persists")
        guard let firstID = sut.model.recordingSessionID else {
            Issue.record("the first session should own a recording row")
            return
        }
        await stop(sut)

        await startRunning(sut)
        sut.engine.enqueue(.final(text: "さようなら。", startSample: 16000, endSample: 32000, lang: "ja"))
        #expect(
            await pollUntil {
                sut.model.recordingSessionID != nil && sut.model.recordingSessionID != firstID
            },
            "the second session opens its own recording row"
        )
        guard let secondID = sut.model.recordingSessionID else {
            Issue.record("the second session should own a recording row")
            return
        }
        await stop(sut)

        let summaries = sut.store.list()
        #expect(summaries.count == 2, "two stopped sessions, two rows")
        #expect(Set(summaries.map(\.id)) == Set([firstID, secondID]))
        #expect(summaries.allSatisfy { summary in summary.sentenceCount == 1 })
    }

    @Test("a session stopped without sentences persists nothing")
    func emptySessionPersistsNothing() async {
        let sut = await makeSUT()
        await startRunning(sut)

        await stop(sut)

        #expect(sut.store.list().isEmpty)
        #expect(!sut.model.toasts.toasts.contains { toast in toast.key == ToastKey.archiveRecent })
    }

    // MARK: - Translation write-back

    @Test("a live translation persists mid-flight and survives the stop")
    func liveTranslationPersistsMidFlightAndAfterStop() async {
        let sut = await makeSUT(finals: [sentenceFinal])
        await startRunning(sut)
        #expect(await pollUntil { sut.model.recordingSessionID != nil }, "the sentence creates the row")
        guard let id = sut.model.recordingSessionID else {
            Issue.record("the recording row should exist")
            return
        }
        let translation = SentenceTranslation(lang: "en", text: "Hello", engine: .appleFast)

        sut.model.applyTranslation(index: 0, translation: translation)

        #expect(
            sut.store.load(id: id)?.entries.first?.translations == [translation],
            "the recording row carries the landing immediately"
        )

        await stop(sut)

        guard let reopened = sut.store.load(id: id) else {
            Issue.record("the stopped session should still load")
            return
        }
        #expect(reopened.summary.status == .complete)
        #expect(
            reopened.entries.first?.translations == [translation],
            "the finalize keeps the translation"
        )
    }

    @Test("a latched session skips translation upserts")
    func latchedSessionSkipsTranslationUpserts() async {
        let sut = await makeSUT(finals: [sentenceFinal])
        await startRunning(sut)
        #expect(await pollUntil { sut.model.recordingSessionID != nil })
        guard let id = sut.model.recordingSessionID else {
            Issue.record("the recording row should exist")
            return
        }
        // A real latch also stops sentence appends, so the row would not stay
        // healthy to receive a write; a healthy row plus the latch isolates
        // the guard itself.
        sut.model.archiveWriteFailed = true

        sut.model.applyTranslation(
            index: 0, translation: SentenceTranslation(lang: "en", text: "Hello")
        )

        #expect(
            sut.store.load(id: id)?.entries.first?.translations.isEmpty == true,
            "no orphan upsert is attempted once the latch is set"
        )

        await stop(sut)
    }

    @Test("a failed translation write latches the session")
    func failedLiveTranslationWriteLatches() async {
        let sut = await makeSUT(finals: [sentenceFinal])
        await startRunning(sut)
        #expect(await pollUntil { sut.model.recordingSessionID != nil })
        guard let id = sut.model.recordingSessionID else {
            Issue.record("the recording row should exist")
            return
        }
        #expect(sut.store.delete(id: id), "removing the row underneath makes the upsert fail")

        sut.model.applyTranslation(
            index: 0, translation: SentenceTranslation(lang: "en", text: "Hello")
        )

        #expect(sut.model.archiveWriteFailed, "the failed write latches")
        #expect(!sut.model.archiveAvailable)
        #expect(
            sut.model.toasts.toasts.filter { toast in toast.key == ToastKey.archiveUnavailable }.count == 1,
            "one warning for the session"
        )

        await stop(sut)
    }

    @Test("the write latch resets when the next session begins")
    func writeLatchResetsAtSessionBegin() async {
        let (store, root) = makeDegradedStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let sut = await makeSUT(finals: [sentenceFinal], store: store)
        await startRunning(sut)
        #expect(await pollUntil { sut.model.archiveWriteFailed }, "the failed append latches")

        await stop(sut)
        #expect(sut.model.archiveWriteFailed, "the latch outlives its own session")

        // The scripted engine's only final was consumed by the first session,
        // so the new session runs without sentences until the reset shows.
        await startRunning(sut)
        #expect(!sut.model.archiveWriteFailed, "a new session clears the latch")
        await stop(sut)
    }

    // MARK: - Pause persistence

    @Test("stop from paused persists the final pause span and excludes it from the duration")
    func pausedStopPersistsSpanAndExcludesItFromDuration() async {
        let sut = await makeSUT(finals: [sentenceFinal])
        await startRunning(sut)
        #expect(await pollUntil { sut.model.recordingSessionID != nil }, "the sentence creates the row")

        sut.model.pause()
        #expect(await pollUntil { sut.model.phase == .paused })
        try? await Task.sleep(for: .milliseconds(400))

        await stop(sut)

        #expect(sut.model.pauseStartedAt == nil, "the stop closes the open pause span")
        guard let summary = sut.store.list().first,
              let started = sut.model.sessionStartedAt,
              let ended = sut.model.sessionEndedAt
        else {
            Issue.record("the stopped session should be stored with its clock anchors")
            return
        }
        #expect(summary.pausedMS >= 400, "the stored paused time carries the final pause span")
        let activeMS = AppModel.milliseconds(of: ended - started) - summary.pausedMS
        #expect(
            abs((summary.durationS ?? 0) * 1000 - activeMS) <= 1000,
            "the stored duration excludes the paused span"
        )
    }

    // MARK: - Launch sweep

    @Test("the launch sweep turns an abandoned recording row into an interrupted recent")
    func launchSweepFlipsAbandonedRecording() async {
        let store = isolatedArchive()
        let abandoned = store.append(
            sentence: Sentence(index: 0, startS: 0, endS: 1.5, lang: "ja", text: "こんにちは"),
            sessionID: nil,
            metadata: SessionMetadata(
                startedAt: Date(timeIntervalSince1970: 500_000),
                sourceLang: "ja", targetLang: "en", model: "test-model", chunkMS: 160
            )
        )
        #expect(abandoned != nil, "the abandoned recording row is seeded first")

        let sut = await makeSUT(store: store)

        #expect(
            sut.store.list().first?.status == .interrupted,
            "the launch sweep runs from init, before anything can list the archive"
        )
        #expect(sut.model.archiveRevision != 0, "the sweep bumps the revision")
    }

    // MARK: - Degraded store

    @Test("a degraded store latches one warning toast and skips finalize")
    func degradedStoreLatchesOnce() async {
        let (store, root) = makeDegradedStore()
        defer { try? FileManager.default.removeItem(at: root) }
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
