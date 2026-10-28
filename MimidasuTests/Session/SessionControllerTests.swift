import Foundation
@testable import Mimidasu
import Testing

/// Tests `SessionController` over the injected `makeEngine` / `makeCapture`
/// seams: `begin()` wiring and its failure arms, the
/// capture-chunk → engine-push path, the poll timer's event loop (latency
/// readback, partial → live state, final → sentence pipeline), the
/// engine/capture error callbacks, warm-up scheduling, and stop() teardown
/// ordering.
///
/// Excluded (audio HAL): the real `SystemAudioCapture.start()` tap
/// setup and the real
/// engine runtime — all are bypassed by injection here, not exercised.
@MainActor
@Suite("SessionController")
struct SessionControllerTests {

    // MARK: - Fixtures

    private let pendingPartial = "認識中"
    private let warmUpModelURL = URL(fileURLWithPath: "/tmp/mimidasu-warmup.gguf")
    private let sessionModelID = "test-model-GGUF"
    private let captureFailureDetail = "boom"
    private let engineFailureMessage = "decode failed"
    private let flushTailSentence = "終わりです"
    private let oneSecondInSamples = 16000

    // MARK: - Helpers

    /// Bounded wait proving absence of activity: gives a (buggy) warm-up
    /// spawn a window to run before asserting it did not.
    private func settle() async {
        try? await Task.sleep(for: .milliseconds(200))
    }

    private func makeSUT(
        resolveEngine: Bool = true,
        poll: [ASREvent] = [],
        finish: [ASREvent] = [],
        captureStartError: (any Error)? = nil,
        isMock: Bool = true
    ) -> SUT {
        let live = LivePartialState()
        let latency = LatencyState()
        let log = CallLog()
        let engine = ScriptedASREngine(log: log, poll: poll, finish: finish, isMock: isMock)
        let capture = ScriptedCapture(log: log, startError: captureStartError)
        let controller = SessionController(
            live: live, latency: latency, translationQueue: TranslationQueue(),
            makeEngine: { _, allowMock in
                log.record("factory allowMock=\(allowMock)")
                return resolveEngine ? engine : nil
            },
            makeCapture: { capture },
            warmUpEnabled: { true }
        )
        return SUT(
            controller: controller, live: live, latency: latency,
            engine: engine, capture: capture, log: log
        )
    }

    // MARK: - warmUpIfNeeded

    @Test("warm-up with no model URL does nothing")
    func warmUpNoModelURLDoesNothing() {
        let sut = makeSUT()

        sut.controller.warmUpIfNeeded(modelURL: nil)
        sut.controller.warmUpIfNeeded(modelURL: nil)

        #expect(sut.log.names.isEmpty)
        #expect(sut.live.partial == "")
        #expect(sut.controller.sessionMetadata == nil)
    }

    @Test("repeated warm-up calls schedule exactly one background prepare")
    func warmUpPreparesOnce() async {
        let sut = makeSUT()

        sut.controller.warmUpIfNeeded(modelURL: warmUpModelURL)
        sut.controller.warmUpIfNeeded(modelURL: warmUpModelURL)

        #expect(
            await pollUntil { sut.log.names == ["factory allowMock=false", "engine.prepare"] }
        )
        #expect(sut.live.partial == "")
        #expect(sut.controller.sessionMetadata == nil)
    }

    /// A model switch must re-arm the warm-up (keyed on the warmed path):
    /// otherwise the next start loads the new GGUF on the main actor.
    @Test("warm-up re-arms when the model path changes")
    func warmUpRearmsForDifferentPath() async {
        let sut = makeSUT()
        let otherURL = URL(fileURLWithPath: "/tmp/mimidasu-warmup-other.gguf")

        sut.controller.warmUpIfNeeded(modelURL: warmUpModelURL)
        #expect(
            await pollUntil { sut.log.names == ["factory allowMock=false", "engine.prepare"] }
        )
        sut.controller.warmUpIfNeeded(modelURL: otherURL)

        #expect(
            await pollUntil {
                sut.log.names == [
                    "factory allowMock=false", "engine.prepare",
                    "factory allowMock=false", "engine.prepare"
                ]
            }
        )
    }

    /// Pins the production default: inside the unit-test host the warm-up is
    /// gated off (its detached engine construction would race the suites into
    /// a ggml-metal init wedge). The scheduling tests above opt back in via
    /// the `warmUpEnabled` seam.
    @Test("warm-up is suppressed by default in the unit-test host")
    func warmUpDefaultsSuppressedInTestHost() async {
        let log = CallLog()
        let controller = SessionController(
            live: LivePartialState(), latency: LatencyState(), translationQueue: TranslationQueue(),
            makeEngine: { _, allowMock in
                log.record("factory allowMock=\(allowMock)")
                return nil
            }
        )

        controller.warmUpIfNeeded(modelURL: warmUpModelURL)
        controller.warmUpIfNeeded(modelURL: warmUpModelURL)
        await settle()

        #expect(log.names.isEmpty)
    }

    // MARK: - stop() without a session

    @Test("stop without a session clears the partial, keeps metadata nil, and is safe twice")
    func stopWithoutSession() async {
        let sut = makeSUT()
        sut.live.partial = pendingPartial

        await sut.controller.stop()
        await sut.controller.stop()

        #expect(sut.live.partial == "")
        #expect(sut.controller.sessionMetadata == nil)
    }

    // MARK: - Timer lifecycle

    @Test("timers fire without a session as a no-op and stop tears them down")
    func timersWithoutSessionAreNoOpAndStopTearsDown() async {
        let sut = makeSUT()

        sut.controller.startTimers()
        await TimerPump.pumpTimers(seconds: 0.3)
        await sut.controller.stop()
        await TimerPump.pumpTimers(seconds: 0.3)

        #expect(sut.live.partial == "")
        #expect(sut.controller.sessionMetadata == nil)
    }

    // MARK: - begin()

    @Test("begin grants permission, starts capture, then prepares and opens the engine")
    func beginWiresUpSession() async throws {
        let sut = makeSUT()
        sut.live.partial = pendingPartial
        sut.latency.seconds = 0.3
        var sessionBegan = false
        var chosenIsMock: Bool?
        sut.controller.onSessionBegin = { sessionBegan = true }
        sut.controller.onEngineChosen = { isMock, _ in chosenIsMock = isMock }

        let started = try await sut.controller.begin(
            modelURL: warmUpModelURL, modelID: sessionModelID
        )

        #expect(started)
        #expect(
            sut.log.names ==
                ["factory allowMock=true", "capture.start", "engine.prepare", "engine.openStream"]
        )
        #expect(sessionBegan)
        #expect(chosenIsMock == true)
        #expect(sut.live.partial == "")
        #expect(sut.latency.seconds == 0)
    }

    @Test("begin records the mock marker or the passed modelID in the session metadata", arguments: [
        (isMock: true, expectedModel: "mock", targetLang: "zh-Hans"),
        (isMock: false, expectedModel: "test-model-GGUF", targetLang: "en")
    ])
    func beginRecordsModelMetadata(
        isMock: Bool, expectedModel: String, targetLang: String
    ) async throws {
        let sut = makeSUT(isMock: isMock)

        _ = try await sut.controller.begin(
            modelURL: warmUpModelURL, modelID: sessionModelID, targetLang: targetLang
        )
        let metadata = try #require(sut.controller.sessionMetadata)

        #expect(metadata.model == expectedModel)
        #expect(metadata.sourceLang == "ja")
        #expect(metadata.targetLang == targetLang)
        #expect(metadata.chunkMS == 160)
    }

    @Test("begin reports needsModel when no engine resolves")
    func beginWithoutEngineReturnsFalse() async throws {
        let sut = makeSUT(resolveEngine: false)

        let started = try await sut.controller.begin(
            modelURL: warmUpModelURL, modelID: sessionModelID
        )

        #expect(!started)
        #expect(sut.log.names == ["factory allowMock=true"])
        #expect(sut.controller.sessionMetadata == nil)
    }

    @Test("begin rethrows a capture start failure and rolls back the capture")
    func beginCaptureFailureThrows() async throws {
        let sut = makeSUT(captureStartError: CaptureError.setupFailed(captureFailureDetail))

        let thrown = await #expect(throws: CaptureError.self) {
            try await sut.controller.begin(modelURL: warmUpModelURL, modelID: sessionModelID)
        }

        #expect(
            thrown?.errorDescription == CaptureError.setupFailed(captureFailureDetail).errorDescription
        )
        #expect(sut.log.names == ["factory allowMock=true", "capture.start", "capture.stop"])
        #expect(sut.controller.sessionMetadata == nil, "a failed start must not keep metadata")
    }

    // MARK: - Capture chunk path

    @Test("capture chunks are pushed into the engine")
    func captureChunksPushIntoEngine() async throws {
        let sut = makeSUT()
        _ = try await sut.controller.begin(modelURL: warmUpModelURL, modelID: sessionModelID)

        sut.capture.onChunk?(AudioChunk(samples: [0.1, -0.2, 0.3], startSample: 0))

        #expect(sut.engine.allPushedChunks == [[0.1, -0.2, 0.3]])
    }

    /// Coverage for the DEBUG `logIngressEnergy` body: driven to its 50-chunk
    /// print boundary and beyond is unreachable without real audio; the log
    /// line itself is not asserted.
    @Test("fifty chunks drive the ingress-energy debug path and accumulate latency")
    func fiftyChunksDriveIngressEnergyPath() async throws {
        let sut = makeSUT()
        _ = try await sut.controller.begin(modelURL: warmUpModelURL, modelID: sessionModelID)

        for index in 0 ..< 50 {
            sut.capture.onChunk?(
                AudioChunk(samples: [Float](repeating: 0.1, count: 2560), startSample: index * 2560)
            )
        }
        sut.controller.startTimers()
        let surfaced = await TimerPump.pumpTimers(until: sut.latency.seconds == 8.0)

        #expect(surfaced, "the poll tick must accumulate the full ingress latency")
        #expect(sut.engine.allPushedChunks.count == 50)
        #expect(sut.controller.sessionMetadata != nil)
        #expect(sut.latency.seconds == 8.0)
    }

    @Test("capture errors surface through onCaptureError")
    func captureErrorsSurface() async throws {
        let sut = makeSUT()
        var messages: [String] = []
        sut.controller.onCaptureError = { message in messages.append(message) }
        _ = try await sut.controller.begin(modelURL: warmUpModelURL, modelID: sessionModelID)

        sut.capture.onIOError?(.setupFailed(captureFailureDetail))

        #expect(await pollUntil { !messages.isEmpty }, "the capture error surfaces")
        #expect(messages.first == CaptureError.setupFailed(captureFailureDetail).errorDescription)
    }

    @Test("engine errors surface through onEngineError")
    func engineErrorsSurface() async throws {
        let sut = makeSUT()
        var messages: [String] = []
        sut.controller.onEngineError = { message in messages.append(message) }
        _ = try await sut.controller.begin(modelURL: warmUpModelURL, modelID: sessionModelID)

        sut.engine.onEngineError?(engineFailureMessage)

        #expect(await pollUntil { !messages.isEmpty }, "the engine error surfaces")
        #expect(messages == [engineFailureMessage])
    }

    // MARK: - Poll timer event loop

    @Test("the poll timer surfaces a partial to the live state and stop clears it")
    func pollTimerSurfacesPartialAndStopClears() async throws {
        let sut = makeSUT(poll: [.partial(text: pendingPartial)])
        _ = try await sut.controller.begin(modelURL: warmUpModelURL, modelID: sessionModelID)
        sut.controller.startTimers()
        let surfaced = await TimerPump.pumpTimers(until: sut.live.partial == pendingPartial)
        #expect(surfaced, "the poll timer must surface the scripted partial")
        let surfacedPartial = sut.live.partial

        await sut.controller.stop()

        #expect(surfacedPartial == pendingPartial)
        #expect(sut.live.partial == "")
    }

    /// Kana-only finals count as Japanese script — the final re-decode often
    /// renders kanji words as kana even when the partial showed kanji — so
    /// they flow through exactly like kanji-bearing ones.
    @Test("the poll timer routes a final into the sentence pipeline", arguments: [
        "今日は良い天気です。", "こんにちは。"
    ])
    func pollTimerEmitsSentence(finalText: String) async throws {
        let sut = makeSUT(poll: [
            .final(text: finalText, startSample: 0, endSample: oneSecondInSamples, lang: "ja")
        ])
        var sentences: [Sentence] = []

        sut.controller.onSentence = { sentence in sentences.append(sentence) }
        _ = try await sut.controller.begin(modelURL: warmUpModelURL, modelID: sessionModelID)
        sut.controller.startTimers()
        let emitted = await TimerPump.pumpTimers(until: !sentences.isEmpty)
        await sut.controller.stop()

        #expect(emitted, "the poll timer must route the final into the sentence pipeline")
        #expect(
            sentences == [
                Sentence(index: 0, startS: 0.0, endS: 1.0, lang: "ja", text: finalText)
            ]
        )
    }

    /// Latin- and symbol-only finals carry no Japanese script, so neither
    /// may enter the sentence pipeline.
    @Test("a final without Japanese script never reaches the sentence pipeline", arguments: [
        "Is this new?", "..."
    ])
    func finalWithoutJapaneseNeverEmits(finalText: String) async throws {
        let sut = makeSUT(poll: [
            .final(text: finalText, startSample: 0, endSample: oneSecondInSamples, lang: "ja")
        ])
        var sentences: [Sentence] = []

        sut.controller.onSentence = { sentence in sentences.append(sentence) }
        _ = try await sut.controller.begin(modelURL: warmUpModelURL, modelID: sessionModelID)
        sut.controller.startTimers()
        await TimerPump.pumpTimers(seconds: 0.5)
        await sut.controller.stop()

        #expect(sentences.isEmpty)
    }

    // MARK: - stop() teardown ordering

    @Test("stop stops capture, drains the engine, then flushes the buffer")
    func stopOrderingAndFlush() async throws {
        let sut = makeSUT(finish: [
            .final(
                text: flushTailSentence, startSample: 0,
                endSample: oneSecondInSamples, lang: "ja"
            )
        ])
        var sentences: [Sentence] = []
        sut.controller.onSentence = { sentence in sentences.append(sentence) }
        _ = try await sut.controller.begin(modelURL: warmUpModelURL, modelID: sessionModelID)

        await sut.controller.stop()

        #expect(
            sut.log.names == [
                "factory allowMock=true", "capture.start", "engine.prepare",
                "engine.openStream", "capture.stop", "engine.finish"
            ]
        )
        #expect(
            sentences == [
                Sentence(index: 0, startS: 0.0, endS: 1.0, lang: "ja", text: flushTailSentence)
            ]
        )
        #expect(sut.live.partial == "")
    }
}

private struct SUT {
    let controller: SessionController
    let live: LivePartialState
    let latency: LatencyState
    let engine: ScriptedASREngine
    let capture: ScriptedCapture
    let log: CallLog
}

private final class ScriptedASREngine: ASREngine, @unchecked Sendable {
    let isMock: Bool
    var onEngineError: ((String) -> Void)?
    var processedSamples = 0

    private let log: CallLog
    private let lock = NSLock()
    private var pollQueue: [ASREvent]
    private let finishQueue: [ASREvent]
    private var pushedChunks: [[Float]] = []
    private var pushedTotal = 0

    init(log: CallLog, poll: [ASREvent] = [], finish: [ASREvent] = [], isMock: Bool = true) {
        self.log = log
        self.isMock = isMock
        pollQueue = poll
        finishQueue = finish
    }

    func prepare() {
        log.record("engine.prepare")
    }

    func openStream() {
        log.record("engine.openStream")
    }

    func push(_ samples: [Float]) {
        lock.withLock {
            pushedChunks.append(samples)
            pushedTotal += samples.count
        }
    }

    var pushedSamples: Int {
        lock.withLock { pushedTotal }
    }

    func poll() -> ASREvent? {
        log.record("engine.poll")
        lock.lock()
        defer { lock.unlock() }
        guard !pollQueue.isEmpty else { return nil }
        return pollQueue.removeFirst()
    }

    func finish() -> [ASREvent] {
        log.record("engine.finish")
        return finishQueue
    }

    func flushUtterance() -> [ASREvent] {
        log.record("engine.flushUtterance")
        return []
    }

    var allPushedChunks: [[Float]] {
        lock.withLock { pushedChunks }
    }
}

private final class ScriptedCapture: AudioCapturing, @unchecked Sendable {
    var onChunk: ((AudioChunk) -> Void)?
    var onIOError: ((CaptureError) -> Void)?

    private let log: CallLog
    private let startError: (any Error)?

    init(log: CallLog, startError: (any Error)? = nil) {
        self.log = log
        self.startError = startError
    }

    func start() async throws {
        log.record("capture.start")
        if let startError {
            throw startError
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
