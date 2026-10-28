import Foundation
@testable import Mimidasu
import Testing

/// Tests `SessionController.begin()` as a transaction: each acquisition
/// (capture start, engine prepare, stream open) is checked against the stop
/// latch, and any failure rolls the half-built session back — the capture is
/// stopped, owned surfaces are cleared, and the engine is never finished or
/// flushed. A stop requested mid-begin cancels the remaining setup so the
/// queued stop owns the teardown, and a rolled-back controller begins again
/// cleanly.
@MainActor
@Suite("SessionController begin rollback")
struct SessionControllerBeginTests {

    // MARK: - Fixtures

    private let warmUpModelURL = URL(fileURLWithPath: "/tmp/mimidasu-warmup.gguf")
    private let sessionModelID = "test-model-GGUF"

    private final class ScriptedASREngine: ASREngine, @unchecked Sendable {
        let isMock = true
        var onEngineError: ((String) -> Void)?
        var processedSamples = 0
        var pushedSamples = 0

        private let log: CallLog
        private let lock = NSLock()
        private var prepareError: ASREngineError?
        private let openStreamError: ASREngineError?

        init(log: CallLog, prepareError: ASREngineError? = nil, openStreamError: ASREngineError? = nil) {
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
            log.record("engine.flushUtterance")
            return []
        }
    }

    private final class ScriptedCapture: AudioCapturing, @unchecked Sendable {
        var onChunk: ((AudioChunk) -> Void)?
        var onIOError: ((CaptureError) -> Void)?
        /// When set, `start()` parks on this gate instead of returning.
        var startGate: StartGate?

        private let log: CallLog

        init(log: CallLog) {
            self.log = log
        }

        func start() async throws {
            log.record("capture.start")
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
        let controller: SessionController
        let engine: ScriptedASREngine
        let capture: ScriptedCapture
        let log: CallLog
    }

    private func makeSUT(
        prepareError: ASREngineError? = nil,
        openStreamError: ASREngineError? = nil
    ) -> SUT {
        let log = CallLog()
        let engine = ScriptedASREngine(
            log: log, prepareError: prepareError, openStreamError: openStreamError
        )
        let capture = ScriptedCapture(log: log)
        let controller = SessionController(
            live: LivePartialState(), latency: LatencyState(), translationQueue: TranslationQueue(),
            makeEngine: { _, allowMock in
                log.record("factory allowMock=\(allowMock)")
                return engine
            },
            makeCapture: { capture },
            warmUpEnabled: { false }
        )
        return SUT(controller: controller, engine: engine, capture: capture, log: log)
    }

    // MARK: - Acquisition failures

    @Test("a prepare failure rolls back the capture and rethrows")
    func prepareFailureRollsBackCapture() async throws {
        let sut = makeSUT(prepareError: ASREngineError.createFailed("model load failed"))

        await #expect(throws: ASREngineError.self) {
            try await sut.controller.begin(modelURL: warmUpModelURL, modelID: sessionModelID)
        }

        #expect(
            sut.log.names == ["factory allowMock=true", "capture.start", "engine.prepare", "capture.stop"],
            "the failed begin stops the capture and never opens the engine stream"
        )
        #expect(sut.controller.sessionMetadata == nil, "a failed start must not keep metadata")
    }

    @Test("an openStream failure rolls back the capture and rethrows")
    func openStreamFailureRollsBackCapture() async throws {
        let sut = makeSUT(openStreamError: ASREngineError.createFailed("stream open failed"))

        await #expect(throws: ASREngineError.self) {
            try await sut.controller.begin(modelURL: warmUpModelURL, modelID: sessionModelID)
        }

        #expect(
            sut.log.names == [
                "factory allowMock=true", "capture.start", "engine.prepare",
                "engine.openStream", "capture.stop"
            ],
            "the failed begin stops the capture after the stream open threw"
        )
        #expect(!sut.log.names.contains("engine.finish"), "rollback never finishes the engine")
        #expect(sut.controller.sessionMetadata == nil, "a failed start must not keep metadata")
    }

    // MARK: - Stop during begin

    @Test("a stop during begin cancels the start and the session winds down to idle")
    func stopDuringBeginCancelsStart() async throws {
        let sut = makeSUT()
        let gate = StartGate()
        sut.capture.startGate = gate

        let beginTask = Task {
            try await sut.controller.begin(modelURL: warmUpModelURL, modelID: sessionModelID)
        }
        // Registered before the gate wait: an aborted test still opens the
        // gate so the parked start cannot hang the suite.
        defer { gate.open() }
        // `#require`, not `#expect`: a start that never parks must abort the
        // test — continuing would race a stop against an un-parked begin.
        try #require(await pollUntil { gate.isEntered }, "begin is suspended in startCapture")

        let stopTask = Task { await sut.controller.stop() }
        try #require(
            await pollUntil { sut.log.names.contains("capture.stop") },
            "the queued stop fenced the capture while begin was parked"
        )
        gate.open()

        await #expect(throws: CancellationError.self) {
            try await beginTask.value
        }
        await stopTask.value

        #expect(!sut.log.names.contains("engine.openStream"), "the aborted begin never opens the stream")
        #expect(sut.controller.sessionMetadata == nil, "the aborted start leaves no metadata")
        #expect(
            sut.log.names.filter { name in name == "engine.finish" }.count == 1,
            "exactly one finish — the queued stop's — consumes the engine"
        )

        let started = try await sut.controller.begin(
            modelURL: warmUpModelURL, modelID: sessionModelID
        )

        #expect(started, "after the wind-down the controller begins again cleanly")
        #expect(
            sut.log.contains(inOrder: [
                "factory allowMock=true", "capture.start", "engine.prepare", "engine.openStream"
            ]),
            "the retry's happy-path acquisition order stays intact"
        )
    }

    // MARK: - Retry after rollback

    @Test("a failed prepare can be retried and the next begin starts cleanly")
    func retryAfterPrepareFailureStartsCleanly() async throws {
        let sut = makeSUT(prepareError: ASREngineError.createFailed("model load failed"))

        await #expect(throws: ASREngineError.self) {
            try await sut.controller.begin(modelURL: warmUpModelURL, modelID: sessionModelID)
        }
        #expect(sut.controller.sessionMetadata == nil)

        sut.engine.clearPrepareError()
        let started = try await sut.controller.begin(
            modelURL: warmUpModelURL, modelID: sessionModelID
        )

        #expect(started)
        #expect(
            sut.log.names == [
                "factory allowMock=true", "capture.start", "engine.prepare", "capture.stop",
                "factory allowMock=true", "capture.start", "engine.prepare", "engine.openStream"
            ],
            "the rollback did not poison the controller: the retry runs the happy path in order"
        )
    }
}

/// Async gate that holds a capture `start()` until `open()`: the parked call
/// suspends rather than blocking a thread, so the main actor stays free for
/// the test to drive a concurrent stop. Once opened, later waits pass
/// straight through; an aborted test still opens via `defer` so nothing
/// parks forever.
final class StartGate: @unchecked Sendable {
    private let lock = NSLock()
    private var enteredFlag = false
    private var openFlag = false
    private var continuation: CheckedContinuation<Void, Never>?

    var isEntered: Bool {
        lock.withLock { enteredFlag }
    }

    func wait() async {
        let alreadyOpen = lock.withLock { () -> Bool in
            enteredFlag = true
            return openFlag
        }
        if alreadyOpen {
            return
        }
        await withCheckedContinuation { continuation in
            let resumeNow: Bool = lock.withLock {
                if openFlag {
                    return true
                }
                self.continuation = continuation
                return false
            }
            if resumeNow {
                continuation.resume()
            }
        }
    }

    func open() {
        let pending: CheckedContinuation<Void, Never>? = lock.withLock {
            openFlag = true
            defer { self.continuation = nil }
            return self.continuation
        }
        pending?.resume()
    }
}
