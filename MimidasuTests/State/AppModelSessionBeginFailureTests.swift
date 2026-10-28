import Foundation
@testable import Mimidasu
import Testing

/// Tests `AppModel.start()`'s begin-failure surface over scripted engine and
/// capture doubles: a `prepare`/`openStream` failure lands the session on
/// `.failed` with the SESSION-failed card while the controller rolls the
/// half-built rig back (capture stopped, no metadata, no translation
/// activation), a failed begin starts cleanly on retry, and a stop arriving
/// while `begin()` is airborne winds the session down to `.idle` without a
/// failure card — the interruption branch tears down whatever the begin
/// brought up before the phase falls back.
@MainActor
@Suite(
    "AppModel session begin failures",
    .enabled(if: DictionaryStore.resolve() != nil && InstalledJMDict.url != nil)
)
struct AppModelSessionBeginFailureTests {

    // MARK: - Fixtures

    private final class ScriptedASREngine: ASREngine, @unchecked Sendable {
        let isMock = true
        var onEngineError: ((String) -> Void)?
        var processedSamples = 0
        var pushedSamples = 0

        private let log: CallLog
        private let lock = NSLock()
        private var prepareError: ASREngineError?
        private let openStreamError: ASREngineError?

        init(
            log: CallLog, prepareError: ASREngineError? = nil,
            openStreamError: ASREngineError? = nil
        ) {
            self.log = log
            self.prepareError = prepareError
            self.openStreamError = openStreamError
        }

        func clearPrepareError() {
            lock.withLock { prepareError = nil }
        }

        func prepare() throws(ASREngineError) {
            log.record("engine.prepare")
            let error = lock.withLock { prepareError }
            if let error {
                throw error
            }
        }

        func openStream() throws(ASREngineError) {
            log.record("engine.openStream")
            if let openStreamError {
                throw openStreamError
            }
        }

        func push(_ samples: [Float]) {}

        func poll() -> ASREvent? {
            nil
        }

        func finish() -> [ASREvent] {
            log.record("engine.finish")
            return []
        }

        func flushUtterance() -> [ASREvent] {
            []
        }
    }

    private final class ScriptedCapture: AudioCapturing, @unchecked Sendable {
        var onChunk: ((AudioChunk) -> Void)?
        var onIOError: ((CaptureError) -> Void)?

        private let log: CallLog
        private let startGate: StartGate?

        init(log: CallLog, startGate: StartGate? = nil) {
            self.log = log
            self.startGate = startGate
        }

        func start() async throws {
            log.record("capture.start")
            // Suspend (never block the main actor thread) until the test
            // opens the gate.
            if let startGate {
                await startGate.wait()
            }
        }

        func stop() {
            log.record("capture.stop")
        }

        func pause() async {
            log.record("capture.pause")
        }

        func resume() async throws {
            log.record("capture.resume")
        }
    }

    private struct SUT {
        let model: AppModel
        let controller: SessionController
        let engine: ScriptedASREngine
        let log: CallLog
    }

    private func makeSUT(
        prepareError: ASREngineError? = nil,
        openStreamError: ASREngineError? = nil,
        startGate: StartGate? = nil
    ) async -> SUT {
        let log = CallLog()
        let engine = ScriptedASREngine(
            log: log, prepareError: prepareError, openStreamError: openStreamError
        )
        let capture = ScriptedCapture(log: log, startGate: startGate)
        let model = AppModel(
            makeSessionController: { live, latency, _, translationQueue in
                SessionController(
                    live: live, latency: latency, translationQueue: translationQueue,
                    makeEngine: { _, allowMock in
                        log.record("factory allowMock=\(allowMock)")
                        return engine
                    },
                    makeCapture: { capture },
                    warmUpEnabled: { false },
                    // No `.translationTask` host exists in tests, so a landed
                    // sentence never drains; the short bound keeps a teardown
                    // from waiting out the production 5 s window.
                    translationDrainTimeout: 0.05
                )
            },
            translationSettings: isolatedTranslationSettings(
                suite: "test.AppModelSessionBeginFailure"
            ),
            asrModelSettings: isolatedASRModelSettings(
                suite: "test.AppModelSessionBeginFailure"
            ),
            favorites: isolatedFavorites(),
            archive: isolatedArchive(),
            // Hermetic: session start activates the Apple engine, whose probe
            // would otherwise hit the real LanguageAvailability.
            highFidelityProbe: { _ in false },
            initialModelResolve: { _ in nil },
            retireWarmEngine: { log.record("engine.retire") }
        )
        await model.initialModelCheck?.value
        await model.refreshModelAvailability(
            resolve: { _ in URL(fileURLWithPath: "/tmp/model.gguf") }
        )
        return SUT(
            model: model, controller: model.sessionController,
            engine: engine, log: log
        )
    }

    private var prepareFailureMessage: String {
        ASREngineError.createFailed("model load failed").localizedDescription
    }

    // MARK: - Acquisition failures

    @Test("a prepare failure fails the start visibly and rolls the rig back")
    func prepareFailureFailsStart() async {
        let message = prepareFailureMessage
        let sut = await makeSUT(prepareError: ASREngineError.createFailed("model load failed"))

        sut.model.start()

        #expect(
            await pollUntil { sut.model.phase == .failed(message) },
            "the prepare failure fails the start"
        )
        #expect(
            sut.log.contains(inOrder: [
                "factory allowMock=true", "capture.start", "engine.prepare", "capture.stop"
            ]),
            "the rollback stops the capture and never opens the stream"
        )
        #expect(!sut.log.names.contains("engine.openStream"))
        #expect(sut.controller.sessionMetadata == nil, "a failed start must not keep metadata")
        // `onSessionBegin` marked the coordinators before acquisition began;
        // translation itself never activated.
        #expect(sut.model.translationConfig == nil, "translation never activated")
        let toast = sut.model.toasts.toasts.first { toast in toast.key == ToastKey.sessionFailed }
        #expect(toast?.style == .redPersistent)
        #expect(toast?.body == message)
        #expect(toast?.action == nil)
    }

    @Test("an openStream failure fails the start the same way")
    func openStreamFailureFailsStart() async {
        let message = ASREngineError.createFailed("stream open failed").localizedDescription
        let sut = await makeSUT(openStreamError: ASREngineError.createFailed("stream open failed"))

        sut.model.start()

        #expect(
            await pollUntil { sut.model.phase == .failed(message) },
            "the stream failure fails the start"
        )
        #expect(
            sut.log.contains(inOrder: [
                "factory allowMock=true", "capture.start", "engine.prepare",
                "engine.openStream", "capture.stop"
            ]),
            "the rollback stops the capture after the stream open threw"
        )
        #expect(!sut.log.names.contains("engine.finish"), "rollback never finishes the engine")
        #expect(sut.controller.sessionMetadata == nil, "a failed start must not keep metadata")
        #expect(sut.model.translationConfig == nil, "translation never activated")
        let toast = sut.model.toasts.toasts.first { toast in toast.key == ToastKey.sessionFailed }
        #expect(toast?.style == .redPersistent)
        #expect(toast?.body == message)
        #expect(toast?.action == nil)
    }

    // MARK: - Retry after rollback

    @Test("a failed prepare can be retried and the next start runs clean")
    func retryAfterPrepareFailureRunsClean() async {
        let message = prepareFailureMessage
        let sut = await makeSUT(prepareError: ASREngineError.createFailed("model load failed"))
        let wiredBegin = sut.controller.onSessionBegin
        var sessionBegins = 0
        sut.controller.onSessionBegin = {
            wiredBegin?()
            sessionBegins += 1
        }

        sut.model.start()
        #expect(
            await pollUntil { sut.model.phase == .failed(message) },
            "the first attempt fails"
        )
        #expect(sessionBegins == 1)

        sut.engine.clearPrepareError()
        sut.model.start()

        #expect(await pollUntil { sut.model.phase == .running }, "the retry brings the session up")
        #expect(sessionBegins == 2, "the retried begin re-fires the session-begin wiring")
        #expect(
            sut.log.names.filter { name in name == "capture.start" }.count == 2,
            "the rollback did not poison the controller: the retry starts a fresh capture"
        )
        #expect(sut.controller.sessionMetadata != nil, "the retry records its metadata")
        #expect(sut.model.translationConfig != nil, "the successful retry activates translation")
    }

    // MARK: - Stop during begin

    @Test("a stop requested during begin winds down to idle with no failure card")
    func stopDuringBeginWindsDownWithoutFailureCard() async {
        let gate = StartGate()
        let sut = await makeSUT(startGate: gate)
        // An aborted test still opens the gate so the parked start cannot
        // hang the suite.
        defer { gate.open() }

        sut.model.start()
        #expect(
            await pollUntil { sut.log.names.contains("capture.start") },
            "begin is suspended in capture start"
        )
        #expect(sut.model.phase == .starting)

        sut.model.stop()
        #expect(sut.model.phase == .stopping)

        gate.open()
        #expect(
            await pollUntil(timeout: 5) { sut.model.phase == .idle },
            "the stop winds the session down to idle"
        )

        #expect(sut.model.toasts.toasts.isEmpty, "an interrupted begin posts no failure card")
        #expect(sut.controller.sessionMetadata == nil, "the cancelled begin leaves no metadata")
        #expect(sut.model.translationConfig == nil, "translation never activated")
        #expect(
            sut.log.contains(inOrder: ["capture.start", "capture.stop"]),
            "the teardown stopped the capture"
        )
    }

    /// The stop's phase write lands while `begin()` is airborne: the
    /// interruption branch owns the controller teardown, so a begin that
    /// completes against a `.stopping` phase must wind the session down to
    /// `.idle` after tearing down — never to `.failed`, never with
    /// translation activated. (A stop that also latches the controller
    /// cancels `begin()` itself; that interleaving is the test above.)
    @Test("a stop phase landing during begin tears down through the interruption path")
    func stopPhaseDuringBeginTearsDownThroughInterruption() async {
        let gate = StartGate()
        let sut = await makeSUT(startGate: gate)
        defer { gate.open() }

        sut.model.start()
        #expect(
            await pollUntil { sut.log.names.contains("capture.start") },
            "begin is suspended in capture start"
        )
        #expect(sut.model.phase == .starting)

        sut.model.phase = .stopping

        gate.open()
        #expect(
            await pollUntil(timeout: 5) { sut.model.phase == .idle },
            "the interrupted begin winds down to idle"
        )

        #expect(sut.model.toasts.toasts.isEmpty, "an interrupted begin posts no failure card")
        #expect(sut.model.translationConfig == nil, "the interruption returns before translation activates")
        #expect(
            sut.log.contains(inOrder: [
                "factory allowMock=true", "capture.start", "engine.prepare",
                "engine.openStream", "capture.stop"
            ]),
            "begin completed, then the interruption tore the session down"
        )
        #expect(sut.log.names.contains("engine.finish"), "the teardown drained the engine")
    }

    @Test("a stop during a begin whose prepare fails still winds down to idle with no card")
    func stopDuringFailingPrepareWindsDownWithoutFailureCard() async {
        let gate = StartGate()
        let sut = await makeSUT(
            prepareError: ASREngineError.createFailed("model load failed"),
            startGate: gate
        )
        defer { gate.open() }

        sut.model.start()
        #expect(
            await pollUntil { sut.log.names.contains("capture.start") },
            "begin is suspended in capture start"
        )
        #expect(sut.model.phase == .starting)

        sut.model.stop()
        #expect(sut.model.phase == .stopping)

        gate.open()
        #expect(
            await pollUntil(timeout: 5) { sut.model.phase == .idle },
            "the stop winds the failing begin down to idle"
        )

        // Depending on the interleaving the stop latch cancels begin before
        // `prepare` runs, or the prepare error wins; both end the same way.
        #expect(sut.model.toasts.toasts.isEmpty, "an interrupted failed begin posts no failure card")
        #expect(sut.controller.sessionMetadata == nil, "the cancelled begin leaves no metadata")
        #expect(sut.model.translationConfig == nil, "translation never activated")
    }
}
