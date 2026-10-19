import Foundation
@testable import Mimidasu
import Testing

/// Tests `SessionController`'s serial transition queue: pause / resume /
/// restart / stop run in request order, and a stop latched while a capture
/// call is airborne waits that call out and owns the teardown — no pause
/// flush starts, no watchdog re-arms, and the rebuilt capture of an airborne
/// restart is fenced. Parked scripted doubles pin the interleavings and
/// concurrent stops are one-shot; nothing waits on a fixed delay.
@MainActor
@Suite("SessionController transitions")
struct SessionControllerTransitionsTests {

    private let flushTailSentence = "終わりです"
    private let finishTailSentence = "おわりました"

    /// The captures are handed out in factory order: the first `makeCapture`
    /// call builds the session, the second (a restart) gets the `rebuilt`
    /// capture whose `start` can be parked.
    private func makeSUT(
        pauseGate: PermitGate? = nil,
        resumeGate: PermitGate? = nil,
        rebuiltStartGate: PermitGate? = nil,
        silenceGracePeriod: Duration = SessionController.noAudioWarningDelay,
        flush: [ASREvent] = [],
        finish: [ASREvent] = []
    ) -> TransitionSUT {
        let log = TransitionCallLog()
        let engine = TransitionScriptedEngine(log: log, flush: flush, finish: finish)
        let capture = TransitionScriptedCapture(
            log: log, name: "capture", pauseGate: pauseGate, resumeGate: resumeGate
        )
        let rebuilt = TransitionScriptedCapture(
            log: log, name: "rebuilt", startGate: rebuiltStartGate
        )
        var available = [capture, rebuilt]
        let sentences = TransitionSentenceSink()
        let controller = SessionController(
            live: LivePartialState(), latency: LatencyState(),
            translationQueue: TranslationQueue(),
            makeEngine: { _, _ in engine },
            makeCapture: {
                guard !available.isEmpty else { return capture }
                return available.removeFirst()
            },
            warmUpEnabled: { false },
            silenceGracePeriod: silenceGracePeriod
        )
        controller.onSentence = { sentence in sentences.record(sentence) }
        return TransitionSUT(
            controller: controller, engine: engine, log: log, sentences: { sentences.all }
        )
    }

    // MARK: - Stop while the capture pause is airborne

    @Test("a stop while the capture pause is airborne waits and skips the flush")
    func stopWhilePauseCaptureAirborneWaitsAndSkipsFlush() async throws {
        let gate = PermitGate()
        // Registered before the gate wait: an aborted test still releases the
        // park, so a suspended transition cannot linger.
        defer { gate.release() }
        let sut = makeSUT(
            pauseGate: gate,
            flush: [.final(text: flushTailSentence, startSample: 0, endSample: 16000, lang: "ja")],
            finish: [.final(text: finishTailSentence, startSample: 0, endSample: 32000, lang: "ja")]
        )
        _ = try await sut.controller.begin(modelURL: nil, modelID: "test-model")

        let pauseTask = Task { await sut.controller.pause() }
        try #require(
            await pollUntil { sut.log.contains(inOrder: ["capture.pause"]) },
            "the capture pause is airborne"
        )

        let stopTask = Task { await sut.controller.stop() }
        try #require(
            await pollUntil { sut.controller.stopRequested },
            "the stop latched while the pause is airborne"
        )
        gate.release()
        await stopTask.value
        await pauseTask.value

        #expect(
            sut.log.contains(
                inOrder: ["capture.pause", "capture.pauseReturned", "capture.stop", "engine.finish"]
            ),
            "the stop waits the airborne pause out before tearing down"
        )
        #expect(
            sut.log.names.filter { name in name == "engine.flushUtterance" }.isEmpty,
            "the stop owns the final flush"
        )
        #expect(sut.sentences().map { sentence in sentence.text } == [finishTailSentence])
    }

    // MARK: - Stop while the resume is airborne

    @Test("a stop while the resume is airborne waits for the resume then stops")
    func stopWhileResumeAirborneWaitsForResumeThenStops() async throws {
        let gate = PermitGate()
        // Registered before the gate wait: an aborted test still releases the
        // park, so a suspended transition cannot linger.
        defer { gate.release() }
        let sut = makeSUT(
            resumeGate: gate,
            silenceGracePeriod: .milliseconds(20),
            finish: [.final(text: finishTailSentence, startSample: 0, endSample: 32000, lang: "ja")]
        )
        _ = try await sut.controller.begin(modelURL: nil, modelID: "test-model")
        await sut.controller.pause()
        let warning = TransitionWarningFlag()
        sut.controller.onNoAudioDetected = { warning.fire() }

        let resumeTask = Task { try? await sut.controller.resume() }
        try #require(
            await pollUntil { sut.log.contains(inOrder: ["capture.resume"]) },
            "the capture resume is airborne"
        )

        let stopTask = Task { await sut.controller.stop() }
        try #require(
            await pollUntil { sut.controller.stopRequested },
            "the stop latched while the resume is airborne"
        )
        gate.release()
        await stopTask.value
        await resumeTask.value

        #expect(
            sut.log.contains(
                inOrder: ["capture.resume", "capture.resumeReturned", "capture.stop", "engine.finish"]
            ),
            "the HAL start completes before the teardown"
        )
        let warned = await pollUntil(timeout: 0.2) { warning.fired }
        #expect(!warned, "the stop-owned resume must not arm a watchdog after teardown")
    }

    // MARK: - Stop during an airborne restart

    @Test("a stop during the restart waits then stops the rebuilt capture")
    func stopDuringRestartWaitsThenStopsRebuiltCapture() async throws {
        let gate = PermitGate()
        // Registered before the gate wait: an aborted test still releases the
        // park, so a suspended transition cannot linger.
        defer { gate.release() }
        let sut = makeSUT(
            rebuiltStartGate: gate,
            finish: [.final(text: finishTailSentence, startSample: 0, endSample: 32000, lang: "ja")]
        )
        _ = try await sut.controller.begin(modelURL: nil, modelID: "test-model")

        let restartTask = Task { try? await sut.controller.restartCapture() }
        try #require(
            await pollUntil { sut.log.contains(inOrder: ["rebuilt.start"]) },
            "the rebuilt capture start is airborne"
        )

        let stopTask = Task { await sut.controller.stop() }
        try #require(
            await pollUntil { sut.controller.stopRequested },
            "the stop latched while the rebuild is airborne"
        )
        gate.release()
        await stopTask.value
        await restartTask.value

        #expect(
            sut.log.contains(
                inOrder: ["capture.stop", "rebuilt.start", "rebuilt.startReturned", "rebuilt.stop"]
            ),
            "the rebuilt capture is started and then fenced by the queued stop"
        )
        #expect(sut.log.names.filter { name in name == "rebuilt.start" }.count == 1)
        #expect(sut.log.names.filter { name in name == "engine.finish" }.count == 1)
    }

    // MARK: - Concurrent stops

    @Test("concurrent stops tear the session down once")
    func concurrentStopsTearDownOnce() async throws {
        let sut = makeSUT(
            flush: [.final(text: flushTailSentence, startSample: 0, endSample: 16000, lang: "ja")],
            finish: [.final(text: finishTailSentence, startSample: 0, endSample: 32000, lang: "ja")]
        )
        _ = try await sut.controller.begin(modelURL: nil, modelID: "test-model")
        let park = FlushPark()
        sut.engine.finishPark = park

        let firstStop = Task { await sut.controller.stop() }
        try #require(await pollUntil { sut.controller.hasStopped }, "the first teardown started")
        let secondStop = Task { await sut.controller.stop() }
        await Task.yield()
        park.open()
        await firstStop.value
        await secondStop.value

        #expect(park.callCount == 1, "the engine finishes exactly once")
        #expect(sut.sentences().map { sentence in sentence.text } == [finishTailSentence])
    }

    // MARK: - Pause after stop

    @Test("a pause after a stop does not start a flush")
    func pauseAfterStopDoesNotFlush() async throws {
        let sut = makeSUT()
        _ = try await sut.controller.begin(modelURL: nil, modelID: "test-model")
        await sut.controller.stop()

        await sut.controller.pause()

        #expect(
            sut.log.names.filter { name in name == "engine.flushUtterance" }.isEmpty,
            "the stopped session must not decode a pause flush"
        )
        #expect(sut.log.names.filter { name in name == "engine.finish" }.count == 1)
    }

    // MARK: - Double pause

    @Test("a second pause while the flush is airborne decodes once")
    func doublePauseWhileFlushAirborneFlushesOnce() async throws {
        let sut = makeSUT(
            flush: [.final(text: flushTailSentence, startSample: 0, endSample: 16000, lang: "ja")]
        )
        let park = FlushPark()
        sut.engine.flushPark = park
        _ = try await sut.controller.begin(modelURL: nil, modelID: "test-model")

        let firstPause = Task { await sut.controller.pause() }
        defer { park.open() }
        try #require(await pollUntil { park.isEntered }, "the pause flush is airborne")

        let secondPause = Task { await sut.controller.pause() }
        await Task.yield()
        park.open()
        await firstPause.value
        await secondPause.value

        #expect(park.callCount == 1, "the flush decode ran exactly once")
        #expect(sut.sentences().map { sentence in sentence.text } == [flushTailSentence])
    }

    // MARK: - Stop from paused

    @Test("a stop from paused still delivers the finish final")
    func stopFromPausedStillDeliversFinishFinal() async throws {
        let sut = makeSUT(
            flush: [.final(text: flushTailSentence, startSample: 0, endSample: 16000, lang: "ja")],
            finish: [.final(text: finishTailSentence, startSample: 0, endSample: 32000, lang: "ja")]
        )
        _ = try await sut.controller.begin(modelURL: nil, modelID: "test-model")

        await sut.controller.pause()
        // The completed pause stays awaitable through the read surface the
        // deferred resume uses.
        await sut.controller.awaitPauseCompletion()
        await sut.controller.stop()

        #expect(sut.log.names.filter { name in name == "engine.flushUtterance" }.count == 1)
        #expect(sut.log.names.filter { name in name == "engine.finish" }.count == 1)
        #expect(
            sut.sentences().map { sentence in sentence.text }
                == [flushTailSentence, finishTailSentence]
        )
    }
}

private struct TransitionSUT {
    let controller: SessionController
    let engine: TransitionScriptedEngine
    let log: TransitionCallLog
    var sentences: () -> [Sentence]
}

private final class TransitionCallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []

    func record(_ name: String) {
        lock.withLock { entries.append(name) }
    }

    var names: [String] {
        lock.withLock { entries }
    }

    func contains(inOrder needle: [String]) -> Bool {
        var index = 0
        for entry in names where index < needle.count {
            if entry == needle[index] {
                index += 1
            }
        }
        return index == needle.count
    }
}

private final class TransitionScriptedEngine: ASREngine, @unchecked Sendable {
    let isMock = true
    var onEngineError: ((String) -> Void)?
    var processedSamples = 0
    var pushedSamples = 0

    private let log: TransitionCallLog
    private let flushScript: [ASREvent]
    private let finishScript: [ASREvent]
    /// Set by a race test: the call parks until `open()`.
    var flushPark: FlushPark?
    var finishPark: FlushPark?

    init(log: TransitionCallLog, flush: [ASREvent] = [], finish: [ASREvent] = []) {
        self.log = log
        flushScript = flush
        finishScript = finish
    }

    func prepare() {}

    func openStream() {}

    func push(_ samples: [Float]) {}

    func poll() -> ASREvent? {
        nil
    }

    func finish() -> [ASREvent] {
        log.record("engine.finish")
        finishPark?.park()
        return finishScript
    }

    func flushUtterance() -> [ASREvent] {
        log.record("engine.flushUtterance")
        flushPark?.park()
        return flushScript
    }
}

private final class TransitionScriptedCapture: AudioCapturing, @unchecked Sendable {
    var onChunk: ((AudioChunk) -> Void)?
    var onIOError: ((CaptureError) -> Void)?

    let name: String
    private let log: TransitionCallLog
    private let pauseGate: PermitGate?
    private let resumeGate: PermitGate?
    private let startGate: PermitGate?

    init(
        log: TransitionCallLog, name: String,
        pauseGate: PermitGate? = nil, resumeGate: PermitGate? = nil,
        startGate: PermitGate? = nil
    ) {
        self.log = log
        self.name = name
        self.pauseGate = pauseGate
        self.resumeGate = resumeGate
        self.startGate = startGate
    }

    func start() async throws {
        log.record("\(name).start")
        if let startGate {
            await startGate.acquire()
        }
        log.record("\(name).startReturned")
    }

    func stop() {
        log.record("\(name).stop")
    }

    func pause() async {
        log.record("\(name).pause")
        if let pauseGate {
            await pauseGate.acquire()
        }
        log.record("\(name).pauseReturned")
    }

    func resume() async throws {
        log.record("\(name).resume")
        if let resumeGate {
            await resumeGate.acquire()
        }
        log.record("\(name).resumeReturned")
    }
}

private final class TransitionSentenceSink: @unchecked Sendable {
    private let lock = NSLock()
    private var sentences: [Sentence] = []

    func record(_ sentence: Sentence) {
        lock.withLock { sentences.append(sentence) }
    }

    var all: [Sentence] {
        lock.withLock { sentences }
    }
}

private final class TransitionWarningFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func fire() {
        lock.withLock { value = true }
    }

    var fired: Bool {
        lock.withLock { value }
    }
}
