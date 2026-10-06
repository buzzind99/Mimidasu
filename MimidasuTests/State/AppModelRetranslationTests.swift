import Foundation
@testable import Mimidasu
import Testing

/// Tests `AppModel`'s manual per-row re-translation surface: the pending
/// marker dims the row and routes the landing result to replace-in-place,
/// the phase gate keeps idle sessions untouched, and a failed-out backlog
/// clears the markers so rows cannot stay dimmed.
@MainActor
@Suite("AppModel manual re-translation")
struct AppModelRetranslationTests {

    // MARK: - Fixtures

    private let sentenceText = "テスト"
    private let translationText = "Test"

    // MARK: - Helpers

    private func makeSUT() async -> AppModel {
        let model = AppModel(
            translationSettings: isolatedTranslationSettings(suite: "test.AppModelRetranslation"),
            asrModelSettings: isolatedASRModelSettings(suite: "test.AppModelRetranslation"),
            favorites: isolatedFavorites(),
            highFidelityProbe: { _ in false },
            initialModelResolve: { _ in nil }
        )
        await model.initialModelCheck?.value
        return model
    }

    private func makeSentence(index: Int) -> Sentence {
        Sentence(index: index, startS: 0, endS: 1, lang: "ja", text: sentenceText)
    }

    // MARK: - Replace-on-arrival routing

    @Test("a manual re-translation replaces the row's translation in place")
    func retranslateReplacesInPlace() async {
        let model = await makeSUT()
        model.phase = .running
        let sentence = makeSentence(index: 7)
        model.sessionController.onSentence?(sentence)
        model.applyTranslation(index: 7, translation: SentenceTranslation(lang: "en", text: translationText))

        model.retranslateSentence(sentence)
        #expect(model.pendingRetranslations == [7], "the row dims while the retry is in flight")

        model.applyTranslation(index: 7, translation: SentenceTranslation(lang: "en", text: "Fresh"))

        #expect(model.entries[0].translations == [SentenceTranslation(lang: "en", text: "Fresh")])
        #expect(model.entries[0].joinedTranslations == "Fresh")
        #expect(model.pendingRetranslations.isEmpty, "the landing result clears the in-flight marker")
    }

    @Test("a second retry click while the row already retranslates is a no-op")
    func retranslateTwiceIsIdempotent() async {
        let model = await makeSUT()
        model.phase = .running
        let sentence = makeSentence(index: 7)
        model.sessionController.onSentence?(sentence)
        model.applyTranslation(index: 7, translation: SentenceTranslation(lang: "en", text: translationText))

        model.retranslateSentence(sentence)
        model.retranslateSentence(sentence)

        #expect(model.pendingRetranslations == [7], "the second click must not churn the marker")

        model.applyTranslation(index: 7, translation: SentenceTranslation(lang: "en", text: "Fresh"))

        #expect(
            model.entries[0].translations == [SentenceTranslation(lang: "en", text: "Fresh")],
            "exactly one retry result lands, replaced in place"
        )
        #expect(model.entries[0].joinedTranslations == "Fresh")
        #expect(model.pendingRetranslations.isEmpty)
    }

    // MARK: - Phase gate

    @Test("a manual re-translation outside a running session is a no-op")
    func retranslateGatedOnRunningPhase() async {
        let model = await makeSUT()
        model.phase = .idle

        model.retranslateSentence(makeSentence(index: 7))

        #expect(model.pendingRetranslations.isEmpty)
        let drained = await model.translationQueue.drain(timeout: 0.05)
        #expect(drained, "the gated retry must not enter the queue without a live worker")
    }

    // MARK: - Failed-out backlog

    @Test("an unavailable status clears pending re-translations so rows cannot stay dimmed")
    func unavailableStatusClearsPendingRetranslations() async {
        let model = await makeSUT()
        model.phase = .running
        model.sessionController.onSentence?(makeSentence(index: 7))

        model.retranslateSentence(makeSentence(index: 7))
        #expect(!model.pendingRetranslations.isEmpty)

        model.handleTranslationStatus(.unavailable("engine failed", .permanent))

        #expect(model.pendingRetranslations.isEmpty)
    }
}
