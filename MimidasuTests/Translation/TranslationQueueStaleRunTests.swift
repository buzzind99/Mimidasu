import Foundation
@testable import Mimidasu
import Synchronization
import Testing

/// Tests the queue's stale-run and worker-lifecycle invariants that the
/// manual retry and the stop path rest on: an in-flight marker is owned by
/// its *flight* (a stale run retires its own and never touches a newer
/// run's, so `drain` neither stalls nor cuts a tail), the worker attach/
/// release handler fires on both edges (the seam `AppModel` mirrors into
/// observable state), and a batch airborne across a session boundary is
/// dropped — its sentences belong to a discarded transcript. Self-contained
/// doubles, mirroring `TranslationQueueTests`' hermetic style.
@MainActor
@Suite("TranslationQueue stale runs")
struct TranslationQueueStaleRunTests {

    // MARK: - Fixtures

    private let sentenceText = "テスト"
    private let resultTimeout: TimeInterval = 5
    /// How long to poll for a *negative* before concluding it never will
    /// happen. Polling for a positive returns the moment it holds.
    private let settleTimeout: TimeInterval = 0.4

    // MARK: - Helpers

    private func makeSentence(index: Int, text: String) -> Sentence {
        Sentence(index: index, startS: 0, endS: 1, lang: "ja", text: text)
    }

    private func makeEchoEngine() -> MockStaleRunEngine {
        MockStaleRunEngine { texts in
            texts.map { text in "EN:\(text)" }
        }
    }

    // MARK: - In-flight ownership

    /// A stale run whose batch *succeeds* must still retire its own flight.
    /// The shared-state resets are generation-guarded because a live run owns
    /// them — but if the stale run is the last thing in the air (the newer run
    /// parked on an empty `pending`), nobody else would ever clear the flag,
    /// and every later `drain` (each stop) would spin out its full timeout.
    /// The in-flight marker is therefore owned by the flight, not the run.
    @Test("a stale run's successful batch releases in-flight so drain is not stalled")
    func staleRunSuccessReleasesInFlight() async {
        let engine = GatedStaleRunEngine()
        let queue = TranslationQueue()
        let sink = StaleRunSink()
        queue.setHandlers(
            result: { index, translation in
                sink.receive(index: index, translation: translation)
            },
            status: { status in sink.receive(status: status) }
        )

        let stale = Task { await queue.run(with: engine) }
        queue.enqueue(makeSentence(index: 0, text: sentenceText))
        #expect(
            await pollUntil(timeout: resultTimeout) { engine.isEntered },
            "the batch is airborne"
        )
        #expect(queue.inFlight, "the flight is in the air")

        // A newer run attaches and parks: `pending` is empty — the batch left
        // the array before its flight — so the live run will never touch the
        // in-flight marker itself.
        let live = Task { await queue.run(with: makeEchoEngine()) }
        defer {
            engine.openGate()
            live.cancel()
        }
        #expect(
            await pollUntil(timeout: resultTimeout) { queue.hasWorker },
            "the live run attached"
        )

        engine.openGate()
        #expect(
            await pollUntil(timeout: resultTimeout) { sink.results.count == 1 },
            "the stale run's results are delivered (deliver is unguarded)"
        )

        // The discriminator: with the flight left dangling, this would spin
        // out the whole timeout and return false.
        let drained = await queue.drain(timeout: 2)
        #expect(drained, "the stale flight retired its own in-flight marker")
        #expect(!queue.inFlight)
    }

    /// The queue reports worker attach/release to its handler — the seam
    /// `AppModel` mirrors into observable state for the retry gate.
    @Test("the worker handler observes engine attach and release")
    func workerHandlerObservesAttachAndRelease() async {
        let queue = TranslationQueue()
        let sink = StaleRunSink()
        queue.setHandlers(
            result: { index, translation in sink.receive(index: index, translation: translation) },
            status: { status in sink.receive(status: status) },
            workerChanged: { active in sink.receive(workerActive: active) }
        )

        let worker = Task { await queue.run(with: makeEchoEngine()) }
        #expect(
            await pollUntil(timeout: resultTimeout) { sink.workerEvents.first == true },
            "attach is reported"
        )
        // Awaited, not just cancelled: the release event fires in the run's
        // `defer`, so the value's return is what makes the assertion below
        // deterministic.
        worker.cancel()
        await worker.value

        #expect(sink.workerEvents == [true, false], "release is reported: \(sink.workerEvents)")
    }

    // MARK: - Airborne batch across a session boundary

    /// A batch that left `pending` *before* `resetForNewSession` is invisible
    /// to it, so the queue itself must retire the batch when its results come
    /// back — otherwise one session's translations land on the next session's
    /// rows of the same indexes. Success variant: results are dropped.
    @Test("a batch airborne across a session boundary delivers nothing")
    func sessionBoundaryDropsAnAirborneSuccess() async {
        let engine = GatedStaleRunEngine()
        let echo = makeEchoEngine()
        let queue = TranslationQueue()
        let sink = StaleRunSink()
        queue.setHandlers(
            result: { index, translation in
                sink.receive(index: index, translation: translation)
            },
            status: { status in sink.receive(status: status) }
        )

        let stale = Task { await queue.run(with: engine) }
        queue.enqueue(makeSentence(index: 0, text: sentenceText))
        #expect(
            await pollUntil(timeout: resultTimeout) { engine.isEntered },
            "the old session's batch is airborne"
        )

        // The boundary passes mid-flight; a new session's run attaches and
        // parks with nothing to do.
        queue.resetForNewSession()
        let live = Task { await queue.run(with: echo) }
        defer {
            engine.openGate()
            live.cancel()
        }
        #expect(
            await pollUntil(timeout: resultTimeout) { queue.hasWorker },
            "the new session's run attached"
        )

        engine.openGate()
        #expect(
            await pollUntil(timeout: settleTimeout) { !sink.results.isEmpty } == false,
            "the old session's results have no destination — they must be dropped"
        )
        #expect(
            echo.recordedBatches.isEmpty,
            "the new session's run must never pump the dropped batch: \(echo.recordedBatches)"
        )
    }

    /// Failure variant: a stale run whose batch fails across the boundary must
    /// neither re-queue it (the parked new run would pump it) nor nudge the
    /// new run's wake — both would replay old-session indexes onto the new
    /// session's rows.
    @Test("a batch failing across a session boundary is dropped, not re-queued")
    func sessionBoundaryDropsAnAirborneFailure() async {
        let engine = GatedStaleRunEngine(failsOnRelease: true)
        let echo = makeEchoEngine()
        let queue = TranslationQueue()
        let sink = StaleRunSink()
        queue.setHandlers(
            result: { index, translation in
                sink.receive(index: index, translation: translation)
            },
            status: { status in sink.receive(status: status) }
        )

        let stale = Task { await queue.run(with: engine) }
        queue.enqueue(makeSentence(index: 0, text: sentenceText))
        #expect(
            await pollUntil(timeout: resultTimeout) { engine.isEntered },
            "the old session's batch is airborne"
        )

        queue.resetForNewSession()
        let live = Task { await queue.run(with: echo) }
        defer {
            engine.openGate()
            live.cancel()
        }
        #expect(
            await pollUntil(timeout: resultTimeout) { queue.hasWorker },
            "the new session's run attached and parked"
        )

        engine.openGate()
        #expect(
            await pollUntil(timeout: settleTimeout) {
                !sink.results.isEmpty || !echo.recordedBatches.isEmpty
            } == false,
            "the failed batch must not re-enter the new session's pending: results=\(sink.results) batches=\(echo.recordedBatches)"
        )
    }
}

/// Engine whose `translate` blocks until the gate opens: lets tests hold a
/// batch mid-flight across a newer run attaching or a session boundary.
/// `Mutex` guards the state because `translate` runs off the main actor.
///
/// Waiters are queued in a list behind a one-way `open` flag rather than held
/// in a single slot, so a second `openGate()` has nothing left to resume (a
/// double resume is a continuation-misuse crash) and a second concurrent
/// `translate` cannot orphan the first.
private struct GatedStaleRunEngineState {
    var open = false
    var entered = false
    var batches: [[String]] = []
    var waiters: [CheckedContinuation<Void, Never>] = []
    /// When set, a released flight resolves as a failure instead of a
    /// translation — lets the session-boundary tests drop an airborne
    /// *failure* into the post-reset queue, not just an airborne success.
    var failsOnRelease = false
}

private final class GatedStaleRunEngine: TranslationEngine, @unchecked Sendable {
    let preferredBatchSize: Int
    var onRetry: (@Sendable (RetryProgress) -> Void)?

    private let state = Mutex(GatedStaleRunEngineState())

    init(failsOnRelease: Bool = false) {
        preferredBatchSize = 16
        state.withLock { gateState in gateState.failsOnRelease = failsOnRelease }
    }

    var isEntered: Bool {
        state.withLock { gateState in gateState.entered }
    }

    var recordedBatches: [[String]] {
        state.withLock { gateState in gateState.batches }
    }

    /// Releases every suspended `translate`, and any that arrives later.
    /// Repeat calls are no-ops.
    func openGate() {
        let parked = state.withLock { gateState -> [CheckedContinuation<Void, Never>] in
            gateState.open = true
            let parked = gateState.waiters
            gateState.waiters.removeAll()
            return parked
        }
        for waiter in parked {
            waiter.resume()
        }
    }

    func translate(_ texts: [String]) async throws -> [String] {
        state.withLock { gateState in
            gateState.batches.append(texts)
            gateState.entered = true
        }
        await withCheckedContinuation { continuation in
            let immediate = state.withLock { gateState -> CheckedContinuation<Void, Never>? in
                guard !gateState.open else { return continuation }
                gateState.waiters.append(continuation)
                return nil
            }
            immediate?.resume()
        }
        let fail = state.withLock { gateState in gateState.failsOnRelease }
        if fail {
            throw TranslationEngineError.network
        }
        return texts.map { text in "EN:\(text)" }
    }
}

/// Closure-backed `TranslationEngine` so the tests stay hermetic. The mutex
/// guards the batch recording because `translate` runs off the main actor.
private final class MockStaleRunEngine: TranslationEngine, @unchecked Sendable {
    let preferredBatchSize: Int
    var onRetry: (@Sendable (RetryProgress) -> Void)?

    private let handler: @Sendable ([String]) async throws -> [String]
    private let state = Mutex(MockStaleRunEngineState())

    init(handler: @escaping @Sendable ([String]) async throws -> [String]) {
        preferredBatchSize = 16
        self.handler = handler
    }

    var recordedBatches: [[String]] {
        state.withLock { mockState in mockState.batches }
    }

    func translate(_ texts: [String]) async throws -> [String] {
        state.withLock { mockState in mockState.batches.append(texts) }
        return try await handler(texts)
    }
}

private struct MockStaleRunEngineState {
    var batches: [[String]] = []
}

/// Records handler callbacks so the tests assert on real deliveries.
private final class StaleRunSink {
    private(set) var results: [(index: Int, translation: SentenceTranslation)] = []
    private(set) var statuses: [TranslationStatus] = []
    private(set) var workerEvents: [Bool] = []

    func receive(index: Int, translation: SentenceTranslation) {
        results.append((index, translation))
    }

    func receive(status: TranslationStatus) {
        statuses.append(status)
    }

    func receive(workerActive: Bool) {
        workerEvents.append(workerActive)
    }
}
