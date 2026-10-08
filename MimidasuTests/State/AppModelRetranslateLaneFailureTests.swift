import Foundation
@testable import Mimidasu
import Synchronization
import Testing

/// Tests the re-translate lane's failure surfaces, split out of the lane
/// runner suite at the type-body-length gate: the failure toast with the
/// queue's shared copy, and the silent drop of a cancelled flight.
@MainActor
@Suite("AppModel re-translate lane failures")
struct AppModelRetranslateLaneFailureTests {

    // MARK: - Fixtures

    private let resultTimeout: TimeInterval = 5

    private func makeSUT() async -> AppModel {
        let model = AppModel(
            translationSettings: isolatedTranslationSettings(suite: "test.AppModelRetranslateLaneFailure"),
            asrModelSettings: isolatedASRModelSettings(suite: "test.AppModelRetranslateLaneFailure"),
            favorites: isolatedFavorites(),
            highFidelityProbe: { _ in false },
            initialModelResolve: { _ in nil }
        )
        await model.initialModelCheck?.value
        return model
    }

    private func makeSentence(
        index: Int, text: String = "テスト"
    ) -> Sentence {
        Sentence(index: index, startS: 0, endS: 1, lang: "ja", text: text)
    }

    // MARK: - Failure surfaces

    @Test("a failed lane run posts the failure toast and clears the marker")
    func failedLaneRunPostsFailureToastAndClearsMarker() async {
        let model = await makeSUT()
        model.retranslateEngineFactory = { _ in LaneEmptyEngine() }
        model.translationSettings.selectRetranslate(.google)
        model.phase = .running
        let sentence = makeSentence(index: 7)
        model.sessionController.onSentence?(sentence)
        model.applyTranslation(index: 7, translation: SentenceTranslation(lang: "en", text: "Original"))

        model.retranslateSentence(sentence)

        #expect(
            await pollUntil(timeout: resultTimeout) {
                model.pendingRetranslations.isEmpty && model.lanePendingRetranslations.isEmpty
            },
            "the failed run has no deliverer — the marker clears"
        )
        let toast = model.toasts.toasts.first(where: { candidate in candidate.key == ToastKey.retranslate })
        #expect(toast?.title == "Re-translate failed")
        #expect(
            toast?.body == TranslationQueue.describe(
                TranslationEngineError.badResponse("Expected 1 non-empty translation, got 0")
            )
        )
        #expect(
            model.entries[0].translations == [SentenceTranslation(lang: "en", text: "Original")],
            "the row keeps its previous translation"
        )
    }

    @Test("a lane failure crossing a stop posts nothing — the stop already cleared the toasts")
    func laneFailureCrossingStopPostsNoToast() async {
        let model = await makeSUT()
        let engine = LaneGatedFailingEngine()
        model.retranslateEngineFactory = { _ in engine }
        model.translationSettings.selectRetranslate(.google)
        model.phase = .running
        // A served backlog keeps a stop's translation-tail drain instant.
        let worker = Task { await model.translationQueue.run(with: QueueEchoEngine()) }
        defer { worker.cancel() }
        #expect(
            await pollUntil(timeout: resultTimeout) { model.translationQueue.hasWorker },
            "the queue worker must be attached"
        )
        let sentence = makeSentence(index: 7)
        model.sessionController.onSentence?(sentence)
        // Settle the worker's initial delivery, then overwrite the row: the
        // "Original" text is what the failed flight must not replace.
        #expect(
            await pollUntil(timeout: resultTimeout) {
                model.entries[0].translations == [SentenceTranslation(lang: "en", text: "EN:テスト")]
            },
            "the worker's initial delivery landed"
        )
        model.applyTranslation(index: 7, translation: SentenceTranslation(lang: "en", text: "Original"))

        // The flight parks mid-air; the stop's cancellation spins the
        // bounded wait out and the failure surfaces once the stop has
        // landed — the fixture's `try?` keeps it a real failure, not a
        // `CancellationError`.
        model.retranslateSentence(sentence)
        #expect(
            await pollUntil(timeout: resultTimeout) { engine.recordedBatches.count == 1 },
            "the flight parks in the engine"
        )
        let laneTask = model.retranslateLaneTask

        await model.performStop()
        engine.openGate()
        await laneTask?.value

        #expect(
            !model.toasts.toasts.contains(where: { toast in toast.key == ToastKey.retranslate }),
            "a failure whose catch runs after the stop must not repost over the cleared stack"
        )
        #expect(model.pendingRetranslations.isEmpty, "no marker outlives the stop")
        #expect(model.lanePendingRetranslations.isEmpty)
        #expect(
            model.entries[0].translations == [SentenceTranslation(lang: "en", text: "Original")],
            "the failed flight must not swap the row"
        )
    }

    @Test("a cancelled lane flight is dropped silently")
    func cancelledLaneFlightIsDroppedSilently() async {
        let model = await makeSUT()
        let engine = LaneCancellableEngine()
        model.retranslateEngineFactory = { _ in engine }
        model.translationSettings.selectRetranslate(.google)
        model.phase = .running
        let sentence = makeSentence(index: 7)
        model.sessionController.onSentence?(sentence)
        model.applyTranslation(index: 7, translation: SentenceTranslation(lang: "en", text: "Original"))

        model.retranslateSentence(sentence)
        #expect(
            await pollUntil(timeout: resultTimeout) { engine.recordedBatches.count == 1 },
            "the flight entered the engine"
        )
        // Direct cancellation (production reaches this only via stop, which
        // clears the markers and the toast stack itself).
        model.retranslateLaneTask?.cancel()
        // The cancellation surfaces as CancellationError out of the parked
        // engine call; its catch path is what retires the markers — poll for
        // it rather than sleeping past it.
        #expect(
            await pollUntil(timeout: resultTimeout) {
                model.pendingRetranslations.isEmpty && model.lanePendingRetranslations.isEmpty
            },
            "the cancelled flight retired its markers"
        )

        #expect(
            !model.toasts.toasts.contains(where: { toast in toast.key == ToastKey.retranslate }),
            "a cancelled flight posts nothing"
        )
        #expect(
            model.entries[0].translations == [SentenceTranslation(lang: "en", text: "Original")],
            "the cancelled flight must not swap the row"
        )
    }
}

/// Lane fixture that answers an empty batch — a count mismatch the queue
/// treats as a failed batch, here surfaced as the lane's failure toast.
private final class LaneEmptyEngine: TranslationEngine, @unchecked Sendable {
    let preferredBatchSize = 4
    var onRetry: (@Sendable (RetryProgress) -> Void)?

    func translate(_ texts: [String]) async throws -> [String] {
        []
    }
}

/// Lane fixture whose `translate` parks cancellably — cancelling the lane
/// task surfaces as `CancellationError` out of the engine call itself.
private final class LaneCancellableEngine: TranslationEngine, @unchecked Sendable {
    let preferredBatchSize = 4
    var onRetry: (@Sendable (RetryProgress) -> Void)?

    private let state = Mutex([[String]]())

    var recordedBatches: [[String]] {
        state.withLock { batches in batches }
    }

    func translate(_ texts: [String]) async throws -> [String] {
        state.withLock { batches in batches.append(texts) }
        try Task.checkCancellation()
        try await Task.sleep(for: .seconds(30))
        return texts.map { text in "JA:\(text)" }
    }
}

/// Queue fixture: prefixes with "EN:", serving the backlog so a stop's
/// translation-tail drain stays instant.
private final class QueueEchoEngine: TranslationEngine, @unchecked Sendable {
    let preferredBatchSize = 16
    var onRetry: (@Sendable (RetryProgress) -> Void)?

    func translate(_ texts: [String]) async throws -> [String] {
        texts.map { text in "EN:\(text)" }
    }
}

/// Lane fixture whose `translate` waits, then THROWS. Deliberately
/// cancellation-blind: a stop cancels the lane task, and in a cancelled task
/// the bounded wait's sleeps throw instantly and are swallowed by `try?` —
/// the loop spins out and the `Failed()` error surfaces right after the
/// stop, classified as a real failure rather than a `CancellationError`
/// (the point: a failure whose catch runs after the stop). The gate is the
/// non-cancelled path's release and stays as belt-and-braces here.
private final class LaneGatedFailingEngine: TranslationEngine, @unchecked Sendable {
    let preferredBatchSize = 4
    var onRetry: (@Sendable (RetryProgress) -> Void)?

    private let state = Mutex(LaneFailureGateState())

    var recordedBatches: [[String]] {
        state.withLock { gateState in gateState.batches }
    }

    func openGate() {
        state.withLock { gateState in gateState.open = true }
    }

    func translate(_ texts: [String]) async throws -> [String] {
        state.withLock { gateState in gateState.batches.append(texts) }
        // Bounded so a gate that never opens cannot hang the suite.
        for _ in 0 ..< 500 {
            if state.withLock({ gateState in gateState.open }) {
                break
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        struct Failed: Error {}
        throw Failed()
    }
}

private struct LaneFailureGateState {
    var open = false
    var batches: [[String]] = []
}
