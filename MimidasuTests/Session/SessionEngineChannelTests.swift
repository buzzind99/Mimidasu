import Foundation
@testable import Mimidasu
import Testing

/// Tests `SessionEngineChannel` directly: the pause-flush handoff, the
/// exactly-once flush/finish delivery, and the phase doors — delivery while
/// live, supersession by a stop or a second pause, the one-shot finish, and
/// the reset/started/markLive reopenings. The tasks are pinned by a parked
/// scripted engine, never by sleeps.
@MainActor
@Suite("SessionEngineChannel")
struct SessionEngineChannelTests {

    // MARK: - Fixtures

    private let flushFinal = ASREvent.final(
        text: "flush", startSample: 0, endSample: 16000, lang: "ja"
    )
    private let finishFinal = ASREvent.final(
        text: "finish", startSample: 16000, endSample: 32000, lang: "ja"
    )

    private final class ScriptedEngine: ASREngine, @unchecked Sendable {
        let isMock = true
        var onEngineError: ((String) -> Void)?
        var processedSamples = 0
        var pushedSamples = 0

        private let flushScript: [ASREvent]
        private let finishScript: [ASREvent]
        private let lock = NSLock()
        private var flushes = 0
        private var finishes = 0
        var flushPark: FlushPark?
        var finishPark: FlushPark?

        init(flush: [ASREvent] = [], finish: [ASREvent] = []) {
            flushScript = flush
            finishScript = finish
        }

        func prepare() {}
        func openStream() {}
        func push(_ samples: [Float]) {}

        func poll() -> ASREvent? {
            nil
        }

        func flushUtterance() -> [ASREvent] {
            lock.withLock { flushes += 1 }
            flushPark?.park()
            return flushScript
        }

        func finish() -> [ASREvent] {
            lock.withLock { finishes += 1 }
            finishPark?.park()
            return finishScript
        }

        var flushCount: Int {
            lock.withLock { flushes }
        }

        var finishCount: Int {
            lock.withLock { finishes }
        }
    }

    private func deliveredEvents(_ outcome: SessionEngineChannel.PauseOutcome) -> [ASREvent]? {
        guard case let .delivered(events) = outcome else { return nil }
        return events
    }

    private func isSuperseded(_ outcome: SessionEngineChannel.PauseOutcome) -> Bool {
        if case .superseded = outcome {
            return true
        }
        return false
    }

    /// Event labels in order — `ASREvent` carries no equality, and the order
    /// is the exactly-once property under test.
    private func labels(of events: [ASREvent]) -> [String] {
        events.map { event in
            switch event {
            case let .partial(text):
                "partial:\(text)"
            case let .final(text, _, _, _):
                "final:\(text)"
            }
        }
    }

    // MARK: - Pause flush

    @Test("a live pause flush delivers its events once")
    func pauseFlushDeliversOnceWhileLive() async {
        let engine = ScriptedEngine(flush: [flushFinal])
        let channel = SessionEngineChannel()
        channel.started()

        let outcome = await channel.pauseFlush(engine: engine)

        #expect(labels(of: deliveredEvents(outcome) ?? []) == ["final:flush"])
        #expect(engine.flushCount == 1)
    }

    @Test("a stop before the flush starts suppresses the pause flush")
    func stopBeforeFlushStartsSuppressesFlush() async {
        let engine = ScriptedEngine(finish: [finishFinal])
        let channel = SessionEngineChannel()
        channel.started()
        channel.requestStop()

        let outcome = await channel.pauseFlush(engine: engine)
        let events = await channel.finish(engine: engine)

        #expect(isSuperseded(outcome))
        #expect(engine.flushCount == 0)
        #expect(labels(of: events) == ["final:finish"])
    }

    @Test("a second pause while the flush is airborne flushes once")
    func doublePauseWhileFlushAirborneFlushesOnce() async throws {
        let engine = ScriptedEngine(flush: [flushFinal])
        let park = FlushPark()
        engine.flushPark = park
        let channel = SessionEngineChannel()
        channel.started()

        let first = Task { await channel.pauseFlush(engine: engine) }
        // Registered before the gate wait: an aborted test still opens the
        // park so the detached flush cannot block a thread forever.
        defer { park.open() }
        try #require(await pollUntil { park.isEntered }, "the pause flush is airborne")

        let second = await channel.pauseFlush(engine: engine)
        park.open()
        let firstOutcome = await first.value

        #expect(isSuperseded(second))
        #expect(labels(of: deliveredEvents(firstOutcome) ?? []) == ["final:flush"])
        #expect(engine.flushCount == 1)
    }

    // MARK: - Stop and finish

    @Test("a stop during an airborne flush returns the flush then the finish")
    func stopDuringAirborneFlushReturnsFlushThenFinish() async throws {
        let engine = ScriptedEngine(flush: [flushFinal], finish: [finishFinal])
        let park = FlushPark()
        engine.flushPark = park
        let channel = SessionEngineChannel()
        channel.started()

        let pauseTask = Task { await channel.pauseFlush(engine: engine) }
        // Registered before the gate wait: an aborted test still opens the
        // park so the detached flush cannot block a thread forever.
        defer { park.open() }
        try #require(await pollUntil { park.isEntered }, "the pause flush is airborne")
        channel.requestStop()

        let finishTask = Task { await channel.finish(engine: engine) }
        await Task.yield()
        park.open()
        let events = await finishTask.value
        let outcome = await pauseTask.value

        #expect(labels(of: events) == ["final:flush", "final:finish"])
        #expect(engine.flushCount == 1)
        #expect(engine.finishCount == 1)
        #expect(isSuperseded(outcome))
    }

    @Test("a second finish waits out the one-shot and returns no events")
    func doubleFinishIsOneShot() async throws {
        let engine = ScriptedEngine(finish: [finishFinal])
        let park = FlushPark()
        engine.finishPark = park
        let channel = SessionEngineChannel()
        channel.started()

        let first = Task { await channel.finish(engine: engine) }
        // Registered before the gate wait: an aborted test still opens the
        // park so the detached finish cannot block a thread forever.
        defer { park.open() }
        try #require(await pollUntil { park.isEntered }, "the finish is airborne")

        let second = Task { await channel.finish(engine: engine) }
        await Task.yield()
        park.open()
        let firstEvents = await first.value
        let secondEvents = await second.value

        #expect(labels(of: firstEvents) == ["final:finish"])
        #expect(secondEvents.isEmpty)
        #expect(engine.finishCount == 1)
    }

    @Test("a pause after the finish is superseded")
    func pauseAfterFinishIsSuperseded() async {
        let engine = ScriptedEngine(flush: [flushFinal], finish: [finishFinal])
        let channel = SessionEngineChannel()
        channel.started()

        _ = await channel.finish(engine: engine)
        let outcome = await channel.pauseFlush(engine: engine)

        #expect(isSuperseded(outcome))
        #expect(engine.flushCount == 0)
    }

    // MARK: - Reopening the pause path

    @Test("reset then started opens the pause path again")
    func resetThenStartedAllowsPauseAgain() async {
        let engine = ScriptedEngine(flush: [flushFinal])
        let channel = SessionEngineChannel()
        channel.started()
        _ = await channel.pauseFlush(engine: engine)

        channel.reset()
        channel.started()
        let outcome = await channel.pauseFlush(engine: engine)

        #expect(labels(of: deliveredEvents(outcome) ?? []) == ["final:flush"])
        #expect(engine.flushCount == 2)
    }

    @Test("markLive after a delivered pause allows a second pause")
    func markLiveAfterPauseAllowsSecondPause() async {
        let engine = ScriptedEngine(flush: [flushFinal])
        let channel = SessionEngineChannel()
        channel.started()
        _ = await channel.pauseFlush(engine: engine)

        channel.markLive()
        let outcome = await channel.pauseFlush(engine: engine)

        #expect(labels(of: deliveredEvents(outcome) ?? []) == ["final:flush"])
        #expect(engine.flushCount == 2)
    }
}
