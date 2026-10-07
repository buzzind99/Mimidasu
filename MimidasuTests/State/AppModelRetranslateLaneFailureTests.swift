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
                TranslationEngineError.badResponse("Expected 1 translation, got 0")
            )
        )
        #expect(
            model.entries[0].translations == [SentenceTranslation(lang: "en", text: "Original")],
            "the row keeps its previous translation"
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
        #expect(await pollUntil(timeout: resultTimeout) { engine.recordedBatches.count == 1 })
        // Direct cancellation (production reaches this only via stop, which
        // clears the markers and the toast stack itself).
        model.retranslateLaneTask?.cancel()
        try? await Task.sleep(for: .milliseconds(100))

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
