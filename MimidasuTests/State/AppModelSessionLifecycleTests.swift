import Foundation
@testable import Mimidasu
import Testing

/// `AppModel.performStop` running through the ordered end seam: the host
/// completion stamps the end anchor and clears the chrome exactly once per
/// stop, the Recent toast stays gated on a finalized row, and the finalize
/// observes the controller drain — a sentence only the drain flushes still
/// lands in the finalized row, and the toast it posts survives the chrome
/// clear that ran before it.
@MainActor
@Suite(
    "AppModel session lifecycle",
    .enabled(if: DictionaryStore.resolve() != nil && InstalledJMDict.url != nil)
)
struct AppModelSessionLifecycleTests {

    // MARK: - Fixtures

    private final class ScriptedASREngine: ASREngine, @unchecked Sendable {
        let isMock = true
        var onEngineError: ((String) -> Void)?
        var processedSamples = 0
        var pushedSamples = 0

        private var polled: [ASREvent]
        private var drained: [ASREvent]

        /// `polled` surfaces through the poll tick while the session runs;
        /// `drained` surfaces exactly once from `finish()` — i.e. out of the
        /// controller's teardown drain.
        init(polled: [ASREvent] = [], drained: [ASREvent] = []) {
            self.polled = polled
            self.drained = drained
        }

        func prepare() {}
        func openStream() {}
        func push(_ samples: [Float]) {}

        func poll() -> ASREvent? {
            polled.isEmpty ? nil : polled.removeFirst()
        }

        func finish() -> [ASREvent] {
            let events = drained
            drained = []
            return events
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

    private func makeSUT(
        polled: [ASREvent] = [],
        drained: [ASREvent] = [],
        store: ArchiveStore = isolatedArchive()
    ) async -> SUT {
        let engine = ScriptedASREngine(polled: polled, drained: drained)
        let capture = ScriptedCapture()
        let model = AppModel(
            makeSessionController: { live, latency, _, translationQueue in
                SessionController(
                    live: live, latency: latency, translationQueue: translationQueue,
                    makeEngine: { _, _ in engine },
                    makeCapture: { capture },
                    warmUpEnabled: { false },
                    // No `.translationTask` host exists in tests, so a landed
                    // sentence never drains; the short bound keeps `stop` from
                    // waiting out the production 5 s window.
                    translationDrainTimeout: 0.05
                )
            },
            translationSettings: isolatedTranslationSettings(
                suite: "test.AppModelSessionLifecycle"
            ),
            asrModelSettings: isolatedASRModelSettings(
                suite: "test.AppModelSessionLifecycle"
            ),
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

    private func stopAndWait(_ sut: SUT) async {
        sut.model.stop()
        #expect(await pollUntil(timeout: 8) { sut.model.phase == .idle }, "stop winds down")
    }

    private let sentenceFinal = ASREvent.final(
        text: "こんにちは。", startSample: 0, endSample: 16000, lang: "ja"
    )
    private let preStopToastKey = "test.lifecycle.preStop"
    private let postStopToastKey = "test.lifecycle.postStop"

    // MARK: - Host completion

    @Test("a stop stamps the end anchor, clears the chrome, and never repeats")
    func stopRunsTheHostCompletionOnce() async {
        let sut = await makeSUT()
        await startRunning(sut)
        sut.model.toasts.post(
            key: preStopToastKey, style: .yellowPersistent,
            title: "Pre-stop", body: "posted before the teardown"
        )
        sut.model.notices.post(message: "Pre-stop notice")

        await stopAndWait(sut)

        #expect(sut.model.sessionEndedAt != nil, "the host completion stamped the end anchor")
        #expect(
            !sut.model.toasts.toasts.contains { toast in toast.key == preStopToastKey },
            "the chrome clear removed the pre-stop card"
        )
        #expect(sut.model.notices.message == nil, "the notice pill cleared with the chrome")

        // A stop from `.idle` is refused by the machine: no second teardown
        // may restamp the anchor or sweep chrome posted after the first one.
        let stamped = sut.model.sessionEndedAt
        sut.model.toasts.post(
            key: postStopToastKey, style: .yellowPersistent,
            title: "Post-stop", body: "posted after the teardown"
        )
        sut.model.stop()

        #expect(sut.model.phase == .idle, "the refused stop leaves the phase alone")
        #expect(sut.model.sessionEndedAt == stamped, "the refused stop must not restamp")
        #expect(
            sut.model.toasts.toasts.contains { toast in toast.key == postStopToastKey },
            "no second chrome clear ran"
        )
    }

    // MARK: - Archive toast gate

    @Test("a stop without a recording row posts no archived-recent toast")
    func stopWithoutRecordingRowPostsNoRecentToast() async {
        let sut = await makeSUT()
        await startRunning(sut)

        await stopAndWait(sut)

        #expect(sut.store.list().isEmpty, "an empty session persists nothing")
        #expect(
            !sut.model.toasts.toasts.contains { toast in toast.key == ToastKey.archiveRecent },
            "no finalize, no Recent toast"
        )
    }

    @Test("a stop whose finalize fails posts no archived-recent toast")
    func failedFinalizePostsNoRecentToast() async {
        let sut = await makeSUT(polled: [sentenceFinal])
        await startRunning(sut)
        #expect(await pollUntil { sut.model.recordingSessionID != nil }, "the sentence creates the row")
        // A latched write makes `finalizeLiveSession` refuse the row while
        // the rest of the teardown still runs.
        sut.model.archiveWriteFailed = true

        await stopAndWait(sut)

        #expect(sut.model.sessionEndedAt != nil, "the host completion runs regardless")
        #expect(sut.store.list().isEmpty, "the latched row is never finalized")
        #expect(
            !sut.model.toasts.toasts.contains { toast in toast.key == ToastKey.archiveRecent },
            "a rejected finalize must not announce itself"
        )
    }

    // MARK: - Observable parity

    @Test("the finalize observes the drain, and its toast outlives the chrome clear")
    func finalizeObservesDrainAndKeepsItsToast() async {
        // The only sentence in this session comes out of the teardown drain:
        // the poll script is empty, so nothing persists until `stop()`
        // flushes the engine. The finalized row below exists only if the
        // drain ran (and persisted) before the archive finalize.
        let sut = await makeSUT(drained: [sentenceFinal])
        await startRunning(sut)
        #expect(sut.model.recordingSessionID == nil, "nothing persisted before the stop")
        sut.model.toasts.post(
            key: preStopToastKey, style: .yellowPersistent,
            title: "Pre-stop", body: "posted before the teardown"
        )
        sut.model.notices.post(message: "Pre-stop notice")

        await stopAndWait(sut)

        guard let summary = sut.store.list().first else {
            Issue.record("the drain-flushed sentence should finalize into a Recent row")
            return
        }
        #expect(summary.status == .complete)
        #expect(summary.sentenceCount == 1, "the drain-flushed sentence is in the finalized row")
        #expect(sut.model.pane.entries.count == 1)
        #expect(sut.model.sessionEndedAt != nil, "the end anchor is stamped")
        #expect(
            sut.model.toasts.toasts.contains { toast in toast.key == ToastKey.archiveRecent },
            "the finalize posted the Recent toast"
        )
        #expect(
            !sut.model.toasts.toasts.contains { toast in toast.key == preStopToastKey },
            "the chrome clear ran before the finalize's toast survived it"
        )
        #expect(sut.model.notices.message == nil, "the notice pill cleared with the chrome")
    }
}
