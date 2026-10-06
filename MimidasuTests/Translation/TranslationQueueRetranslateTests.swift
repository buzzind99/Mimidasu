import Foundation
@testable import Mimidasu
import Synchronization
import Testing

/// Tests `TranslationQueue.retranslate(_:)` — the transcript row's manual
/// retry: a delivered sentence re-runs through the engine (cache evicted),
/// and a sentence a failed batch left in `pending` flies exactly once. Also
/// covers the two queue-side conditions that retry correctness rests on: a
/// short engine response fails the batch instead of stranding its ids, and
/// `resetForNewSession()` drops a backlog the retry guard would otherwise
/// inherit across a session. Self-contained doubles, mirroring
/// `TranslationQueueTests`' hermetic style.
@MainActor
@Suite("TranslationQueue retranslate")
struct TranslationQueueRetranslateTests {

    // MARK: - Fixtures

    private let sentenceText = "テスト"
    private let otherSentenceText = "こんにちは"
    private let resultTimeout: TimeInterval = 5
    /// How long to let a *duplicate* batch appear before concluding it never
    /// will. Polling for a negative has to wait out the window; polling for a
    /// positive returns the moment it holds.
    private let settleTimeout: TimeInterval = 0.4

    // MARK: - Helpers

    private func makeSentence(index: Int, text: String) -> Sentence {
        Sentence(index: index, startS: 0, endS: 1, lang: "ja", text: text)
    }

    private func makeEchoEngine() -> MockRetranslateEngine {
        MockRetranslateEngine { texts in
            texts.map { text in "EN:\(text)" }
        }
    }

    // MARK: - Cache bypass

    /// The manual retry must bypass the app-run cache: a sentence already
    /// delivered re-enters the worker for a fresh engine round-trip instead
    /// of the synchronous cached result at `enqueue` time.
    @Test("retranslate re-runs a translated sentence through the engine")
    func retranslateBypassesCacheAndRerunsEngine() async {
        let engine = makeEchoEngine()
        let queue = TranslationQueue()
        let sink = RetranslateSink()
        await confirmation("results delivered", expectedCount: 2) { delivered in
            queue.setHandlers(
                result: { index, translation in
                    sink.receive(index: index, translation: translation)
                    delivered()
                },
                status: { status in sink.receive(status: status) }
            )
            let worker = Task { await queue.run(with: engine) }
            defer { worker.cancel() }

            queue.enqueue(makeSentence(index: 0, text: sentenceText))
            #expect(
                await pollUntil(timeout: resultTimeout) { sink.results.count == 1 },
                "the sentence translates once"
            )

            queue.retranslate(makeSentence(index: 0, text: sentenceText))
            #expect(
                await pollUntil(timeout: resultTimeout) { sink.results.count == 2 },
                "the retry rounds through the engine again"
            )
        }

        #expect(engine.recordedBatches.count == 2, "the cache must not serve the retry")
        #expect(sink.results.last?.index == 0)
        #expect(sink.results.last?.translation.text == "EN:\(sentenceText)")
    }

    // MARK: - Pending dedupe

    /// A sentence a failed batch re-inserted into `pending` must not queue
    /// twice: `retranslate` drops the stale copy, so the replay produces
    /// exactly one flight and one result.
    @Test("retranslate drops a pending copy so a failed sentence cannot fly twice")
    func retranslateDeduplicatesPendingCopy() async {
        let failing = MockRetranslateEngine { _ in throw TranslationEngineError.network }
        let echo = makeEchoEngine()
        let queue = TranslationQueue()
        let sink = RetranslateSink()
        await confirmation("unavailable status") { failed in
            queue.setHandlers(
                result: { index, translation in
                    sink.receive(index: index, translation: translation)
                },
                status: { status in
                    sink.receive(status: status)
                    if case .unavailable = status {
                        failed()
                    }
                }
            )

            let worker = Task { await queue.run(with: failing) }
            queue.enqueue(makeSentence(index: 0, text: sentenceText))
            #expect(
                await pollUntil(timeout: resultTimeout) {
                    if case .unavailable = queue.status {
                        return true
                    }
                    return false
                },
                "the first run fails out with the sentence still pending"
            )
            // Awaited, not just cancelled: `engine` is still attached until the
            // run's `defer` runs, and a `pending` copy with a live engine reads
            // as "awaiting" — so an early `retranslate` would no-op on the
            // awaiting guard and never exercise the dedupe.
            worker.cancel()
            await worker.value

            queue.retranslate(makeSentence(index: 0, text: sentenceText))
            let replay = Task { await queue.run(with: echo) }
            defer { replay.cancel() }
            #expect(
                await pollUntil(timeout: resultTimeout) { sink.results.count == 1 },
                "the replayed retry delivers exactly one result"
            )
        }

        #expect(sink.results.count == 1, "no duplicate flight from the pending copy")
        #expect(sink.results.first?.index == 0)
        #expect(echo.recordedBatches.map(\.count) == [1])
    }

    /// The other half of the dedupe precondition: with the engine gone, a
    /// sentence parked in `pending` is explicitly *not* awaiting, so a retry
    /// re-queues it instead of being refused. This is what lets a user re-run
    /// a line after a failed batch.
    @Test("a stranded sentence with no worker is retryable, not awaiting")
    func strandedSentenceWithoutWorkerIsNotAwaiting() async {
        let queue = TranslationQueue()
        let sink = RetranslateSink()
        queue.setHandlers(
            result: { index, translation in sink.receive(index: index, translation: translation) },
            status: { status in sink.receive(status: status) }
        )
        let sentence = makeSentence(index: 0, text: sentenceText)

        let worker = Task { await queue.run(with: MockRetranslateEngine { _ in
            throw TranslationEngineError.network
        }) }
        queue.enqueue(sentence)
        #expect(
            await pollUntil(timeout: resultTimeout) {
                if case .unavailable = queue.status {
                    return true
                }
                return false
            },
            "the sentence is stranded in pending by the failure"
        )
        worker.cancel()
        await worker.value

        #expect(!queue.hasWorker, "the failed run released its engine")
        #expect(
            !queue.isAwaitingTranslation(sentence),
            "a stranded sentence with no worker must not read as awaiting"
        )
        #expect(sink.results.isEmpty, "the failed run delivered nothing")

        queue.retranslate(sentence)
        let replay = Task { await queue.run(with: makeEchoEngine()) }
        defer { replay.cancel() }
        #expect(
            await pollUntil(timeout: resultTimeout) { sink.results.count == 1 },
            "the retry re-queues the stranded sentence and it lands"
        )
    }

    // MARK: - Idempotency (retry while already translating)

    /// A sentence popped into the worker's batch is invisible to `pending`;
    /// the retry must no-op — a re-queued copy would fly twice (replace on
    /// the first result, append on the second).
    @Test("retranslate while the sentence is mid-flight is a no-op")
    func retranslateWhileMidFlightIsNoOp() async {
        let engine = GatedRetranslateEngine()
        let queue = TranslationQueue()
        let sink = RetranslateSink()
        await confirmation("translation delivered") { delivered in
            queue.setHandlers(
                result: { index, translation in
                    sink.receive(index: index, translation: translation)
                    delivered()
                },
                status: { status in sink.receive(status: status) }
            )
            let worker = Task { await queue.run(with: engine) }
            defer { worker.cancel() }

            queue.enqueue(makeSentence(index: 0, text: sentenceText))
            #expect(
                await pollUntil(timeout: resultTimeout) { engine.isEntered },
                "the batch is airborne"
            )

            let sentence = makeSentence(index: 0, text: sentenceText)
            #expect(queue.isAwaitingTranslation(sentence), "mid-flight counts as awaiting")
            queue.retranslate(sentence)

            engine.openGate()
            #expect(
                await pollUntil(timeout: resultTimeout) { sink.results.count == 1 },
                "the original flight delivers exactly one result"
            )
            // A duplicate copy would be pumped after the batch above resolves,
            // so the negative has to be polled for a window rather than
            // asserted at an instant.
            #expect(
                await pollUntil(timeout: settleTimeout) { engine.recordedBatches.count > 1 } == false,
                "the retry must not start a second flight"
            )
        }

        #expect(engine.recordedBatches.map(\.count) == [1], "no duplicate flight was queued")
        #expect(sink.results.count == 1)
        #expect(sink.results.first?.index == 0)
    }

    /// A sentence queued behind a busy worker will translate imminently;
    /// the retry must no-op rather than move it or double-queue it.
    @Test("retranslate while queued behind a live worker is a no-op")
    func retranslateWhileQueuedBehindLiveWorkerIsNoOp() async {
        let engine = GatedRetranslateEngine()
        let queue = TranslationQueue()
        let sink = RetranslateSink()
        await confirmation("translations delivered", expectedCount: 2) { delivered in
            queue.setHandlers(
                result: { index, translation in
                    sink.receive(index: index, translation: translation)
                    delivered()
                },
                status: { status in sink.receive(status: status) }
            )
            let worker = Task { await queue.run(with: engine) }
            defer { worker.cancel() }

            queue.enqueue(makeSentence(index: 0, text: sentenceText))
            #expect(
                await pollUntil(timeout: resultTimeout) { engine.isEntered },
                "the first batch is airborne"
            )
            // Sits in `pending` while the worker is busy on the gate.
            queue.enqueue(makeSentence(index: 1, text: otherSentenceText))

            let sentence = makeSentence(index: 1, text: otherSentenceText)
            #expect(queue.isAwaitingTranslation(sentence), "queued behind a live worker counts as awaiting")
            queue.retranslate(sentence)

            engine.openGate()
            #expect(
                await pollUntil(timeout: resultTimeout) { sink.results.count == 2 },
                "both sentences deliver"
            )
            // Same reason as the mid-flight test: a duplicate copy would only
            // be pumped after the confirmation closes, so wait it out first.
            #expect(
                await pollUntil(timeout: settleTimeout) {
                    engine.recordedBatches.flatMap { batch in batch }.count > 2
                } == false,
                "the queued sentence must not fly a second time"
            )
        }

        #expect(sink.results.map(\.index) == [0, 1])
        #expect(
            engine.recordedBatches
                .flatMap { batch in batch }
                .filter { text in text == otherSentenceText }
                .count == 1,
            "the retried sentence flew exactly once: batches were \(engine.recordedBatches)"
        )
    }

    // MARK: - Count mismatch

    /// An engine that answers with fewer strings than it was given used to end
    /// the batch quietly: `zip` paired what it could and dropped the rest, and
    /// their ids stayed in `translatingIDs`, so those rows read as permanently
    /// mid-flight and their retry button did nothing. A short answer is a
    /// failed batch now — the whole batch re-queues and the index is released.
    @Test("a short engine response fails the batch instead of dropping sentences")
    func shortResponseFailsTheBatchAndRequeuesIt() async {
        let shortAnswer = MockRetranslateEngine { _ in [] }
        let echo = makeEchoEngine()
        let queue = TranslationQueue()
        let sink = RetranslateSink()
        await confirmation("the good run delivers the re-queued sentence") { delivered in
            queue.setHandlers(
                result: { index, translation in
                    sink.receive(index: index, translation: translation)
                    delivered()
                },
                status: { status in sink.receive(status: status) }
            )

            let failing = Task { await queue.run(with: shortAnswer) }
            defer { failing.cancel() }
            queue.enqueue(makeSentence(index: 0, text: sentenceText))
            #expect(
                await pollUntil(timeout: resultTimeout) {
                    if case .unavailable = queue.status {
                        return true
                    }
                    return false
                },
                "a short answer is a failed batch, not a quiet truncation"
            )
            #expect(
                sink.results.isEmpty,
                "nothing is delivered for a batch that did not come back whole"
            )

            let replay = Task { await queue.run(with: echo) }
            defer { replay.cancel() }
            #expect(
                await pollUntil(timeout: resultTimeout) { sink.results.count == 1 },
                "the sentence survives to the next run instead of being lost"
            )
        }

        #expect(sink.results.first?.translation.text == "EN:\(sentenceText)")
    }

    // MARK: - Session boundary

    /// `pending` outlives a *run* on purpose — an engine swap must replay the
    /// backlog, and a retried sentence is sitting in it — but it must not
    /// outlive a *session*. Sentence indexes restart at 0 in every session and
    /// the previous transcript is discarded at the same boundary, so a carried
    /// backlog has no correct destination: it can only deliver one session's
    /// translation onto the next session's row of the same index, and any id
    /// it still held would read as mid-flight and refuse a retry forever.
    ///
    /// This pins both halves on two identically-stranded queues: one replays
    /// across a run boundary, the other crosses a session boundary first.
    @Test("a run replays the stranded backlog but a session boundary drops it")
    func runReplaysBacklogButSessionBoundaryDropsIt() async {
        let replays = await strandedQueue()
        let drops = await strandedQueue()

        let replayWorker = Task { await replays.queue.run(with: makeEchoEngine()) }
        defer { replayWorker.cancel() }
        await confirmation("a run boundary delivers the stranded sentence") { delivered in
            #expect(
                await pollUntil(timeout: resultTimeout) { replays.sink.results.count == 1 },
                "a run boundary replays the stranded backlog"
            )
            delivered()
        }
        #expect(replays.sink.results.map(\.index) == [0])

        // Same stranded backlog, but the session turns over before anything
        // can serve it.
        drops.queue.resetForNewSession()
        let dropWorker = Task { await drops.queue.run(with: makeEchoEngine()) }
        defer { dropWorker.cancel() }
        // Latch the positive first: without it the negative below would also
        // pass for a run that never attached an engine at all.
        #expect(
            await pollUntil(timeout: resultTimeout) { drops.queue.hasWorker },
            "the post-reset run attached an engine — it just has nothing to do"
        )
        // Poll for the failure and require it never to arrive: `pollUntil`
        // returns true the moment its condition *holds*, so the condition is
        // the bad outcome here, and `== false` asserts the whole window passed
        // without it.
        #expect(
            await pollUntil(timeout: settleTimeout) { !drops.sink.results.isEmpty } == false,
            "a session boundary drops the backlog instead of replaying it"
        )
        // The failing run pumped one batch; the post-reset run must pump none.
        #expect(
            drops.sink.statuses.filter { status in status == .translating }.count == 1,
            "only the failing run ever pumped a batch: \(drops.sink.statuses)"
        )
    }

    // MARK: - Helpers

    /// A queue holding one sentence stranded in `pending` by a failed run —
    /// the state both halves of the session-boundary test start from.
    private func strandedQueue() async -> (queue: TranslationQueue, sink: RetranslateSink) {
        let queue = TranslationQueue()
        let sink = RetranslateSink()
        queue.setHandlers(
            result: { index, translation in
                sink.receive(index: index, translation: translation)
            },
            status: { status in sink.receive(status: status) }
        )
        let failing = Task { await queue.run(with: MockRetranslateEngine { _ in
            throw TranslationEngineError.network
        }) }
        defer { failing.cancel() }
        queue.enqueue(makeSentence(index: 0, text: sentenceText))
        #expect(
            await pollUntil(timeout: resultTimeout) {
                if case .unavailable = queue.status {
                    return true
                }
                return false
            },
            "the sentence is stranded in pending by the failure"
        )
        return (queue, sink)
    }
}

/// Engine whose `translate` blocks until the gate opens: lets tests hold a
/// batch mid-flight to exercise retry idempotency. `Mutex` guards the state
/// because `translate` runs off the main actor.
///
/// Waiters are queued in a list behind a one-way `open` flag rather than held
/// in a single slot, so a second `openGate()` has nothing left to resume (a
/// double resume is a continuation-misuse crash) and a second concurrent
/// `translate` cannot orphan the first.
private struct GatedEngineState {
    var open = false
    var entered = false
    var batches: [[String]] = []
    var waiters: [CheckedContinuation<Void, Never>] = []
}

private final class GatedRetranslateEngine: TranslationEngine, @unchecked Sendable {
    let preferredBatchSize: Int
    var onRetry: (@Sendable (RetryProgress) -> Void)?

    private let state = Mutex(GatedEngineState())

    init() {
        preferredBatchSize = 16
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
        return texts.map { text in "EN:\(text)" }
    }
}

/// Closure-backed `TranslationEngine` so the retry tests stay hermetic. The
/// mutex guards the batch recording because `translate` runs off the main actor.
private final class MockRetranslateEngine: TranslationEngine, @unchecked Sendable {
    let preferredBatchSize: Int
    var onRetry: (@Sendable (RetryProgress) -> Void)?

    private let handler: @Sendable ([String]) async throws -> [String]
    private let state = Mutex(MockRetranslateEngineState())

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

private struct MockRetranslateEngineState {
    var batches: [[String]] = []
}

/// Records handler callbacks so the tests assert on real deliveries.
private final class RetranslateSink {
    private(set) var results: [(index: Int, translation: SentenceTranslation)] = []
    private(set) var statuses: [TranslationStatus] = []

    func receive(index: Int, translation: SentenceTranslation) {
        results.append((index, translation))
    }

    func receive(status: TranslationStatus) {
        statuses.append(status)
    }
}
