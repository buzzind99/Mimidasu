import Foundation
@testable import Mimidasu
import Testing

/// Tests the dedicated Apple sessions behind the re-translate lane's
/// on-device selections: the fast (MTL) and Apple Intelligence arrival
/// hooks, arming, engine-stamped delivery through each armed session, and
/// the per-kind still-arming toasts.
@MainActor
@Suite("AppModel re-translate Apple lanes")
struct AppModelRetranslateAppleLaneTests {

    private let resultTimeout: TimeInterval = 5

    private func makeSUT() async -> AppModel {
        let model = AppModel(
            translationSettings: isolatedTranslationSettings(suite: "test.AppModelRetranslateAppleLane"),
            asrModelSettings: isolatedASRModelSettings(suite: "test.AppModelRetranslateAppleLane"),
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

    /// Attaches a queue worker the way `activateTranslation` does, so the
    /// session-engine path can serve the initial translation.
    @discardableResult
    private func attachWorker(_ model: AppModel) async -> Task<Void, Never> {
        let worker = Task { await model.translationQueue.run(with: QueueEchoEngine()) }
        #expect(
            await pollUntil(timeout: resultTimeout) { model.translationQueue.hasWorker },
            "the queue worker must be attached before a retry can be served"
        )
        return worker
    }

    // MARK: - Session plumbing

    @Test("the fast-lane arrival hook stores its engine only while its config is armed")
    func fastArrivalStoresEngine() async {
        let model = await makeSUT()

        // An unarmed config refuses the hand-over: a session for a lane that
        // was never armed must not be stored for the next lane to acquire
        // instantly.
        model.retranslateSessionArrived(LaneEchoEngine())
        #expect(model.retranslateSessionEngine == nil)

        model.armRetranslateSessionIfNeeded(for: .appleFast)
        model.retranslateSessionArrived(LaneEchoEngine())

        #expect(model.retranslateSessionEngine != nil)
        #expect(model.retranslateHifiSessionEngine == nil, "the intelligence lane's slot is untouched")
    }

    @Test("the intelligence-lane arrival hook stores its engine only while its config is armed")
    func hifiArrivalStoresEngine() async {
        let model = await makeSUT()

        // Same gate as the fast lane: no armed config, no stored session.
        model.retranslateHifiSessionArrived(LaneEchoEngine())
        #expect(model.retranslateHifiSessionEngine == nil)

        model.armRetranslateSessionIfNeeded(for: .appleHighFidelity)
        model.retranslateHifiSessionArrived(LaneEchoEngine())

        #expect(model.retranslateHifiSessionEngine != nil)
        #expect(model.retranslateSessionEngine == nil, "the fast lane's slot is untouched")
    }

    @Test("arming an external kind arms no dedicated session")
    func armingExternalKindArmsNothing() async {
        let model = await makeSUT()

        model.armRetranslateSessionIfNeeded(for: .google)

        #expect(model.retranslateConfig == nil)
        #expect(model.retranslateHifiConfig == nil)
    }

    @Test("arming an already-armed kind never reassigns its config")
    func armingArmedKindKeepsConfig() async {
        let model = await makeSUT()
        model.armRetranslateSessionIfNeeded(for: .appleFast)
        let armed = model.retranslateConfig
        #expect(armed != nil)

        model.armRetranslateSessionIfNeeded(for: .appleFast)

        #expect(
            model.retranslateConfig == armed,
            "a reassignment would be a `.translationTask` re-fire gamble — the armed config stays put"
        )
    }

    // MARK: - Fast (MTL) lane

    @Test("apple fast stamps via the armed session and seeds the cache unstamped")
    func appleFastStampsViaArmedSession() async throws {
        // The probe-installed Apple identity only exists on 26.4+; below it
        // the fast selection degrades to the session path instead.
        guard #available(macOS 26.4, *) else {
            try Test.cancel("the armed fast lane requires macOS 26.4")
        }
        let model = await makeSUT()
        // A high-fidelity live session makes the fast model a real alternate.
        model.appleHighFidelityProbe = (true, "en")
        model.translationSettings.selectRetranslate(.appleFast)
        model.phase = .running
        let worker = await attachWorker(model)
        defer { worker.cancel() }
        let sentence = makeSentence(index: 7)
        model.sessionController.onSentence?(sentence)
        #expect(
            await pollUntil(timeout: resultTimeout) { model.entries[0].joinedTranslations == "EN:テスト" },
            "the initial session translation is delivered before the retry"
        )

        // No session engine yet: the lane arms the config and waits (bounded)
        // while the `.translationTask` host hands one over.
        model.retranslateSentence(sentence)
        model.retranslateSessionArrived(LaneEchoEngine())

        #expect(
            await pollUntil(timeout: resultTimeout) {
                model.entries[0].translations
                    == [SentenceTranslation(lang: "en", text: "JA:テスト", engine: .appleFast)]
            },
            "the fast-model result lands stamped"
        )
        #expect(model.pendingRetranslations.isEmpty)
        #expect(model.lanePendingRetranslations.isEmpty)
        #expect(model.retranslateConfig != nil, "the armed config survives a successful run")

        // A later repeat of the sentence (a fresh row) serves unstamped.
        model.sessionController.onSentence?(makeSentence(index: 9))
        let repeatEntry = model.entries.first(where: { entry in entry.sentence.index == 9 })
        #expect(repeatEntry?.translations == [SentenceTranslation(lang: "en", text: "JA:テスト")])
        #expect(repeatEntry?.translations.first?.engine == nil, "the seed is unstamped")
    }

    @Test("a still-arming fast session posts the starting toast and keeps the config armed")
    func stillArmingFastSessionPostsStartingToast() async throws {
        guard #available(macOS 26.4, *) else {
            try Test.cancel("the armed fast lane requires macOS 26.4")
        }
        let model = await makeSUT()
        model.appleHighFidelityProbe = (true, "en")
        model.translationSettings.selectRetranslate(.appleFast)
        model.phase = .running
        let sentence = makeSentence(index: 7)
        model.sessionController.onSentence?(sentence)
        model.applyTranslation(index: 7, translation: SentenceTranslation(lang: "en", text: "Original"))

        // No engine ever arrives; the bounded wait runs out on its own (a
        // short injected bound, so the timeout is exercised for real — task
        // cancellation is the separate `.cancelled` outcome, covered below).
        model.laneArmTimeout = .milliseconds(50)
        model.retranslateSentence(sentence)

        #expect(
            await pollUntil(timeout: resultTimeout) {
                model.pendingRetranslations.isEmpty && model.lanePendingRetranslations.isEmpty
            },
            "the timed-out wait retires the markers"
        )
        let toast = model.toasts.toasts.first(where: { candidate in candidate.key == ToastKey.retranslate })
        #expect(toast?.title == "Re-translate unavailable")
        #expect(toast?.body == "Apple (MTL) session is still starting — try again in a moment.")
        #expect(
            model.entries[0].translations == [SentenceTranslation(lang: "en", text: "Original")],
            "the row keeps its previous translation"
        )
        #expect(
            model.retranslateConfig != nil,
            "the config stays armed — the next click is instant once the session lands"
        )
    }

    // MARK: - Apple Intelligence lane

    @Test("apple intelligence stamps via its armed session and arms only the hifi config")
    func appleIntelligenceStampsViaArmedSession() async throws {
        guard #available(macOS 26.4, *) else {
            try Test.cancel("the armed hifi lane requires macOS 26.4")
        }
        let model = await makeSUT()
        // An EXTERNAL live session, so a high-fidelity retry is a genuine
        // alternate at every stage of the probe — a live Apple session would
        // take the session path once a landed-installed probe reveals it
        // already runs the Intelligence model. (A probe that landed
        // not-installed would degrade the selection to `.appleFast` instead
        // — see `unavailableHighFidelityDegradesToFast`.)
        model.activeTranslationEngine = .external
        model.activeExternalProvider = .google
        model.translationSettings.selectRetranslate(.appleHighFidelity)
        model.phase = .running
        let worker = await attachWorker(model)
        defer { worker.cancel() }
        let sentence = makeSentence(index: 7)
        model.sessionController.onSentence?(sentence)
        #expect(
            await pollUntil(timeout: resultTimeout) { model.entries[0].joinedTranslations == "EN:テスト" },
            "the initial session translation is delivered before the retry"
        )

        model.retranslateSentence(sentence)
        // The probe lands installed mid-lane: the pair genuinely serves the
        // Intelligence model, so the deferred lane flies as armed.
        model.appleHighFidelityProbe = (true, "en")
        model.retranslateHifiSessionArrived(LaneEchoEngine())

        #expect(
            await pollUntil(timeout: resultTimeout) {
                model.entries[0].translations
                    == [SentenceTranslation(lang: "en", text: "JA:テスト", engine: .appleHighFidelity)]
            },
            "the Apple Intelligence result lands stamped"
        )
        #expect(model.pendingRetranslations.isEmpty)
        #expect(model.lanePendingRetranslations.isEmpty)
        #expect(model.retranslateHifiConfig != nil, "the armed hifi config survives a successful run")
        #expect(model.retranslateConfig == nil, "the fast lane's session is never armed")
    }

    @Test("a still-arming intelligence session posts its own starting toast")
    func stillArmingHifiSessionPostsStartingToast() async throws {
        guard #available(macOS 26.4, *) else {
            try Test.cancel("the armed hifi lane requires macOS 26.4")
        }
        let model = await makeSUT()
        // The probe landed installed for an EXTERNAL live session: the
        // Intelligence selection is a genuine alternate and the probe
        // deferral passes straight through — what stalls is the arm wait
        // itself. (A live Apple session would take the session path; a
        // pending probe would defer first instead of arming-waiting.)
        model.activeTranslationEngine = .external
        model.activeExternalProvider = .google
        model.appleHighFidelityProbe = (true, "en")
        model.translationSettings.selectRetranslate(.appleHighFidelity)
        model.phase = .running
        let sentence = makeSentence(index: 7)
        model.sessionController.onSentence?(sentence)
        model.applyTranslation(index: 7, translation: SentenceTranslation(lang: "en", text: "Original"))

        // No engine ever arrives; the bounded wait runs out on its own.
        model.laneArmTimeout = .milliseconds(50)
        model.retranslateSentence(sentence)

        #expect(
            await pollUntil(timeout: resultTimeout) {
                model.pendingRetranslations.isEmpty && model.lanePendingRetranslations.isEmpty
            },
            "the timed-out wait retires the markers"
        )
        let toast = model.toasts.toasts.first(where: { candidate in candidate.key == ToastKey.retranslate })
        #expect(toast?.title == "Re-translate unavailable")
        #expect(toast?.body == "Apple Intelligence session is still starting — try again in a moment.")
        #expect(
            model.entries[0].translations == [SentenceTranslation(lang: "en", text: "Original")],
            "the row keeps its previous translation"
        )
        #expect(
            model.retranslateHifiConfig != nil,
            "the config stays armed — the next click is instant once the session lands"
        )
        #expect(model.retranslateConfig == nil, "the fast lane's session is never armed")
    }

    @Test("a cancelled wait retires the markers without reporting a starting session")
    func cancelledWaitRetiresMarkersSilently() async throws {
        // Below 26.4 the fast selection resolves to the session path (or
        // no-ops outright), never to an armed lane — the whole scenario
        // would be vacuous.
        guard #available(macOS 26.4, *) else {
            try Test.cancel("the armed fast lane requires macOS 26.4")
        }
        let model = await makeSUT()
        model.appleHighFidelityProbe = (true, "en")
        model.translationSettings.selectRetranslate(.appleFast)
        model.phase = .running
        let sentence = makeSentence(index: 7)
        model.sessionController.onSentence?(sentence)
        model.applyTranslation(index: 7, translation: SentenceTranslation(lang: "en", text: "Original"))

        // A long bound, so the wait is still sleeping when the cancellation
        // lands — the interleaved-stop shape.
        model.laneArmTimeout = .seconds(30)
        model.retranslateSentence(sentence)
        model.retranslateLaneTask?.cancel()

        #expect(
            await pollUntil(timeout: resultTimeout) {
                model.pendingRetranslations.isEmpty && model.lanePendingRetranslations.isEmpty
            },
            "a cancelled wait still retires the markers"
        )
        #expect(
            model.toasts.toasts.allSatisfy { candidate in candidate.key != ToastKey.retranslate },
            "a cancellation is not a timeout — the stop already cleared the toasts"
        )
    }

    @Test("a timed-out wait that outlives the session posts nothing")
    func timedOutWaitOutlivingStopPostsNothing() async throws {
        guard #available(macOS 26.4, *) else {
            try Test.cancel("the armed fast lane requires macOS 26.4")
        }
        let model = await makeSUT()
        model.appleHighFidelityProbe = (true, "en")
        model.translationSettings.selectRetranslate(.appleFast)
        model.phase = .running
        let worker = await attachWorker(model)
        defer { worker.cancel() }
        let first = makeSentence(index: 1, text: "一")
        let second = makeSentence(index: 2, text: "二")
        model.sessionController.onSentence?(first)
        model.sessionController.onSentence?(second)
        // Settle the initial deliveries: they keep a stop's translation-tail
        // drain instant. An unserved backlog would spin the drain's whole
        // bounded timeout, and the lane's expiry would then land DURING the
        // stop (phase still live) — the toast would be removed by the
        // stop's clearAll, not refused by the delivery guard under test.
        #expect(
            await pollUntil(timeout: resultTimeout) {
                model.entries[0].translations == [SentenceTranslation(lang: "en", text: "EN:一")]
                    && model.entries[1].translations == [SentenceTranslation(lang: "en", text: "EN:二")]
            },
            "the initial translations are delivered before the retries"
        )

        // Two chained waits: the stop cancels only the newest link, so the
        // first task is still parked in its bounded wait when the session
        // dies. Its expiry is the `.timedOut` outcome most likely to cross a
        // stop — it must pass the delivery guard instead of reposting a
        // "still starting" toast over the cleared stack.
        model.laneArmTimeout = .milliseconds(500)
        model.retranslateSentence(first)
        let firstTask = model.retranslateLaneTask
        model.retranslateSentence(second)
        let secondTask = model.retranslateLaneTask
        await model.performStop()

        // Await both tasks instead of sleeping past the deadline: the stop
        // returns in milliseconds now, so the first task's expiry genuinely
        // lands after it — in `.idle`, stale epoch — where refusing the
        // toast is the delivery guard's doing. The second was cancelled with
        // the stop and must stay silent as well.
        await firstTask?.value
        await secondTask?.value
        #expect(
            !model.toasts.toasts.contains(where: { toast in toast.key == ToastKey.retranslate }),
            "a timed-out wait whose session is gone posts nothing"
        )
        #expect(model.pendingRetranslations.isEmpty)
        #expect(model.lanePendingRetranslations.isEmpty)
        #expect(
            model.entries[0].translations == [SentenceTranslation(lang: "en", text: "EN:一")],
            "the expired wait never touched its row"
        )
    }

    // MARK: - Unavailable high fidelity

    @Test("an intelligence selection the OS cannot serve degrades to the fast model")
    func unavailableHighFidelityDegradesToFast() async {
        let model = await makeSUT()
        model.translationSettings.selectRetranslate(.appleHighFidelity)
        // The probe landed not-installed for this pair: requesting high
        // fidelity anyway would silently return the fast model's text while
        // stamping the row "Apple Intelligence".
        model.appleHighFidelityProbe = (false, "en")
        // An external live session, so the degraded fast selection is a
        // genuine alternate (a live fast Apple session would be served by the
        // session engine instead).
        model.activeTranslationEngine = .external
        model.activeExternalProvider = .google
        model.phase = .running
        let worker = await attachWorker(model)
        defer { worker.cancel() }
        let sentence = makeSentence(index: 3)
        model.sessionController.onSentence?(sentence)
        #expect(
            await pollUntil(timeout: resultTimeout) { model.entries[0].joinedTranslations == "EN:テスト" },
            "the initial session translation is delivered before the retry"
        )

        #expect(model.effectiveRetranslateSelection == .appleFast)

        model.retranslateSentence(sentence)
        model.retranslateSessionArrived(LaneEchoEngine())

        #expect(
            await pollUntil(timeout: resultTimeout) {
                model.entries[0].translations
                    == [SentenceTranslation(lang: "en", text: "JA:テスト", engine: .appleFast)]
            },
            "the row lands stamped with the model that actually ran"
        )
        #expect(model.retranslateConfig != nil, "the fast lane is the one armed")
        #expect(model.retranslateHifiConfig == nil, "the high-fidelity session is never armed")
        #expect(
            model.translationSettings.retranslateEngine == .appleHighFidelity,
            "the persisted selection is not rewritten — only its resolution degrades"
        )
    }
}

/// Session-engine fixture: prefixes with "EN:".
private final class QueueEchoEngine: TranslationEngine, @unchecked Sendable {
    let preferredBatchSize = 16
    var onRetry: (@Sendable (RetryProgress) -> Void)?

    func translate(_ texts: [String]) async throws -> [String] {
        texts.map { text in "EN:\(text)" }
    }
}
