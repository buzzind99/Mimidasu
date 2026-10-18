import Foundation
@testable import Mimidasu
import Testing

/// Store-backed bulk-run behavior of `AppModelArchiveTranslation`: lost
/// store writes, the complete-language re-run, and the send-count and
/// completeness reads the engine picker leans on. Scripted engine doubles
/// make every run deterministic; a permit gate parks runs mid-sentence.
@MainActor
@Suite("AppModelArchiveTranslation store-backed runs")
struct AppModelArchiveTranslationStoreTests {

    private let resultTimeout: TimeInterval = 5

    /// The three rows a full `fr` run of the default fixture lands, in
    /// sentence order.
    private var expectedFRLandings: [[SentenceTranslation]] {
        [
            [SentenceTranslation(lang: "fr", text: "T:こんにちは", engine: .google)],
            [SentenceTranslation(lang: "fr", text: "T:さようなら", engine: .google)],
            [SentenceTranslation(lang: "fr", text: "T:おはよう", engine: .google)]
        ]
    }

    // MARK: - Lost store writes

    @Test("lost store writes count as failed sentences and warn once per run")
    func lostStoreWritesFailSentencesAndWarnOnce() async {
        let sut = await makeSUT()
        let gate = PermitGate()
        let engine = ScriptedArchiveEngine(gate: gate)
        install(engine, for: .google, on: sut.model)

        sut.model.beginArchiveTranslation(engine: .google, lang: "fr")
        #expect(
            await pollUntil(timeout: resultTimeout) {
                sut.model.archiveTranslationRunning && engine.recordedBatches.count == 1
            },
            "the run parks on its first sentence"
        )

        // The session row vanishes under the run (a delete, or a store
        // fault): every upsert for it now fails on the session foreign key.
        #expect(sut.store.delete(id: sut.id))

        gate.release()
        gate.release()
        gate.release()
        #expect(
            await pollUntil(timeout: resultTimeout) { !sut.model.archiveTranslationRunning },
            "the run winds down"
        )
        #expect(sut.model.archiveTranslationJob.translatedCount == 0, "no lost write is counted as a success")
        #expect(
            sut.model.archiveTranslationJob.failureIndexes == [0, 1, 2],
            "every lost write is a retryable failure"
        )
        let warnings = sut.model.toasts.toasts.filter { toast in toast.key == ToastKey.archiveUnavailable }
        #expect(warnings.count == 1, "one warning card covers the run, not one per sentence")
        #expect(warnings.first?.isClosable == true, "the archive-mode warning is dismissible")
        #expect(
            sut.model.entries.allSatisfy { entry in entry.translation(for: "fr") == nil },
            "a lost write leaves the pane row on its previous placeholder"
        )
        #expect(
            archiveToast(sut.model)?.body == "0/3 translated to Français · 3 failed",
            "the summary reports the lost writes honestly"
        )

        // The store still lacks every translation while the pane shows none
        // either, so the next run's scope agrees with the summary: missing,
        // and every sentence is sent.
        gate.release()
        gate.release()
        gate.release()
        sut.model.beginArchiveTranslation(engine: .google, lang: "fr")
        #expect(
            await pollUntil(timeout: resultTimeout) {
                engine.recordedBatches.count == 6 && !sut.model.archiveTranslationRunning
            },
            "the fresh run sends every sentence"
        )
        #expect(
            sut.model.archiveTranslationJob.lastRun?.request.scope == .missing,
            "the scope stays missing — no phantom rows narrow or widen it"
        )
    }

    // MARK: - Complete-language rerun

    @Test("a complete language reruns the whole session and overwrites the stored texts")
    func completeLanguageRerunsWholeSession() async {
        let sut = await makeSUT(translations: [0: "Seed 0", 1: "Seed 1", 2: "Seed 2"])
        let engine = ScriptedArchiveEngine()
        install(engine, for: .google, on: sut.model)

        sut.model.beginArchiveTranslation(engine: .google, lang: "fr")

        #expect(
            await pollUntil(timeout: resultTimeout) { runFinished(sut.model, translated: 3) },
            "the complete language re-runs every sentence"
        )
        #expect(
            engine.recordedBatches == [["こんにちは"], ["さようなら"], ["おはよう"]],
            "the whole session is sent, not the (empty) missing set"
        )
        #expect(
            sut.store.load(id: sut.id)?.entries.map { entry in entry.translations } == expectedFRLandings,
            "every stored seed is overwritten by the fresh pass"
        )
    }

    // MARK: - Send count and completeness

    @Test("the send count reports the missing sentences while the language is partial")
    func sendCountReportsMissingWhilePartial() async {
        let sut = await makeSUT(translations: [0: "Seed"])

        let sendCount = sut.model.archiveTranslationSendCount(lang: "fr")
        let complete = sut.model.archiveLanguageIsComplete("fr")

        #expect(sendCount == 2)
        #expect(!complete)
    }

    @Test("a complete language reports the full count and reads complete")
    func sendCountReportsFullWhenComplete() async {
        let sut = await makeSUT(translations: [0: "Seed 0", 1: "Seed 1", 2: "Seed 2"])

        let sendCount = sut.model.archiveTranslationSendCount(lang: "fr")
        let complete = sut.model.archiveLanguageIsComplete("fr")

        #expect(sendCount == 3, "a complete language re-sends every sentence when re-run")
        #expect(complete)
    }
}
