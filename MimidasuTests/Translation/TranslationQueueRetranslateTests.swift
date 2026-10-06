import Foundation
@testable import Mimidasu
import Synchronization
import Testing

/// Tests `TranslationQueue.retranslate(_:)` — the transcript row's manual
/// retry: a delivered sentence re-runs through the engine (cache evicted),
/// and a sentence a failed batch left in `pending` flies exactly once.
/// Self-contained doubles, mirroring `TranslationQueueTests`' hermetic style.
@MainActor
@Suite("TranslationQueue retranslate")
struct TranslationQueueRetranslateTests {

    // MARK: - Fixtures

    private let sentenceText = "テスト"
    private let otherSentenceText = "こんにちは"
    private let resultTimeout: TimeInterval = 5

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
    func retranslateBypassesCacheAndRerunsEngine() async throws {
        let engine = makeEchoEngine()
        let queue = TranslationQueue()
        let sink = RetranslateSink()
        try await confirmation("results delivered", expectedCount: 2) { delivered in
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
    func retranslateDeduplicatesPendingCopy() async throws {
        let failing = MockRetranslateEngine { _ in throw TranslationEngineError.network }
        let echo = makeEchoEngine()
        let queue = TranslationQueue()
        let sink = RetranslateSink()
        try await confirmation("unavailable status") { failed in
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
            worker.cancel()

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
            #expect(
                await pollUntil(timeout: resultTimeout) { engine.recordedBatches.count == 1 },
                "the retry must not start a second flight"
            )

            engine.openGate()
            #expect(
                await pollUntil(timeout: resultTimeout) { sink.results.count == 1 },
                "the original flight delivers exactly one result"
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
}

/// Engine whose `translate` blocks on a gate: lets tests hold a batch
/// mid-flight to exercise retry idempotency. `Mutex` guards the state
/// because `translate` runs off the main actor.
private struct GatedEngineState {
    var armed = true
    var entered = false
    var batches: [[String]] = []
    var continuation: CheckedContinuation<Void, Never>?
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

    /// Releases a suspended `translate` (no-op if the gate already opened).
    func openGate() {
        let continuation = state.withLock { gateState -> CheckedContinuation<Void, Never>? in
            gateState.armed = false
            return gateState.continuation
        }
        continuation?.resume()
    }

    func translate(_ texts: [String]) async throws -> [String] {
        state.withLock { gateState in
            gateState.batches.append(texts)
            gateState.entered = true
        }
        await withCheckedContinuation { continuation in
            let immediate = state.withLock { gateState -> CheckedContinuation<Void, Never>? in
                if gateState.armed {
                    gateState.continuation = continuation
                    return nil
                }
                return continuation
            }
            immediate?.resume()
        }
        return texts.map { text in "EN:\(text)" }
    }
}

/// Closure-backed `TranslationEngine` so the retry tests stay hermetic. Lock
/// guards the batch recording because `translate` runs off the main actor.
private final class MockRetranslateEngine: TranslationEngine, @unchecked Sendable {
    let preferredBatchSize: Int
    var onRetry: (@Sendable (RetryProgress) -> Void)?

    private let handler: @Sendable ([String]) async throws -> [String]
    private let lock = NSLock()
    private var batches: [[String]] = []

    init(handler: @escaping @Sendable ([String]) async throws -> [String]) {
        preferredBatchSize = 16
        self.handler = handler
    }

    var recordedBatches: [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return batches
    }

    func translate(_ texts: [String]) async throws -> [String] {
        lock.withLock { batches.append(texts) }
        return try await handler(texts)
    }
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
