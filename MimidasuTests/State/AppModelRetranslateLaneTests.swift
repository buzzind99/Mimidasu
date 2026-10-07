import Foundation
@testable import Mimidasu
import Synchronization
import Testing

/// Tests the alternate-engine re-translate lane's runner semantics against
/// mock engines: engine-stamped delivery, unstamped cache seeding,
/// serialization of lane flights, the post-stop phase gate, marker
/// ownership vs the queue's terminal `.unavailable` clear, and the lane
/// toasts.
@MainActor
@Suite("AppModel re-translate lane")
struct AppModelRetranslateLaneTests {

    // MARK: - Fixtures

    private let sentenceText = "テスト"
    private let resultTimeout: TimeInterval = 5

    private func makeSUT() async -> AppModel {
        let model = AppModel(
            translationSettings: isolatedTranslationSettings(suite: "test.AppModelRetranslateLane"),
            asrModelSettings: isolatedASRModelSettings(suite: "test.AppModelRetranslateLane"),
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
    /// session-engine path can serve a retry.
    @discardableResult
    private func attachWorker(_ model: AppModel) async -> Task<Void, Never> {
        let worker = Task { await model.translationQueue.run(with: QueueEchoEngine()) }
        #expect(
            await pollUntil(timeout: resultTimeout) { model.translationQueue.hasWorker },
            "the queue worker must be attached before a retry can be served"
        )
        return worker
    }

    // MARK: - Lane delivery

    @Test("a lane result stamps the engine and seeds the cache unstamped")
    func laneResultStampsEngineAndSeedsCacheUnstamped() async {
        let model = await makeSUT()
        let engine = LaneEchoEngine()
        model.retranslateEngineFactory = { provider in
            #expect(provider == .google)
            return engine
        }
        model.translationSettings.selectRetranslate(.google)
        model.phase = .running
        let sentence = makeSentence(index: 7)
        model.sessionController.onSentence?(sentence)

        model.retranslateSentence(sentence)

        #expect(
            await pollUntil(timeout: resultTimeout) {
                model.entries[0].translations
                    == [SentenceTranslation(lang: "en", text: "JA:テスト", engine: .google)]
            },
            "the lane result lands stamped"
        )
        #expect(model.pendingRetranslations.isEmpty, "the result retires the marker")
        #expect(model.lanePendingRetranslations.isEmpty)
        #expect(engine.recordedBatches == [[sentenceText]], "one lane flight")

        // A later repeat of the sentence (a fresh row) serves through the
        // normal queue path: the retried text, no provenance.
        model.sessionController.onSentence?(makeSentence(index: 9))
        let repeatEntry = model.entries.first(where: { entry in entry.sentence.index == 9 })
        #expect(repeatEntry?.translations == [SentenceTranslation(lang: "en", text: "JA:テスト")])
        #expect(repeatEntry?.translations.first?.engine == nil, "the seed is unstamped")
    }

    @Test("an unavailable lane engine posts a toast and skips the row")
    func unavailableLaneEnginePostsToastAndSkips() async {
        let model = await makeSUT()
        let calls = Mutex(0)
        model.retranslateEngineFactory = { provider in
            calls.withLock { counter in counter += 1 }
            #expect(provider == .openrouter)
            return nil
        }
        model.translationSettings.selectRetranslate(.openrouter)
        model.phase = .running
        let sentence = makeSentence(index: 7)
        model.sessionController.onSentence?(sentence)
        model.applyTranslation(index: 7, translation: SentenceTranslation(lang: "en", text: "Original"))

        model.retranslateSentence(sentence)

        #expect(model.pendingRetranslations.isEmpty, "nothing is in flight — no marker")
        #expect(model.lanePendingRetranslations.isEmpty)
        #expect(
            model.entries[0].translations == [SentenceTranslation(lang: "en", text: "Original")],
            "the row keeps its previous translation"
        )
        let toast = model.toasts.toasts.first(where: { candidate in candidate.key == ToastKey.retranslate })
        #expect(toast?.title == "Re-translate unavailable")
        #expect(toast?.body == "No API key stored for OpenRouter.")
    }

    // MARK: - Serialization

    @Test("lane translations serialize — the second click chains, never races")
    func laneTranslationsSerialize() async {
        let model = await makeSUT()
        let engine = LaneGatedEngine()
        model.retranslateEngineFactory = { _ in engine }
        model.translationSettings.selectRetranslate(.google)
        model.phase = .running
        let first = makeSentence(index: 1, text: "一")
        let second = makeSentence(index: 2, text: "二")
        model.sessionController.onSentence?(first)
        model.sessionController.onSentence?(second)

        model.retranslateSentence(first)
        #expect(
            await pollUntil(timeout: resultTimeout) { engine.recordedBatches.count == 1 },
            "the first flight enters the parked engine"
        )
        model.retranslateSentence(second)
        #expect(engine.recordedBatches.count == 1, "the second click chains behind the first")

        engine.openGate()
        #expect(
            await pollUntil(timeout: resultTimeout) { engine.recordedBatches.count == 2 },
            "the chained flight runs once the gate opens"
        )
        #expect(engine.recordedBatches == [["一"], ["二"]], "strict one-at-a-time order")
        #expect(model.pendingRetranslations.isEmpty)
        #expect(model.lanePendingRetranslations.isEmpty)
    }

    @Test("a duplicate lane click while the row already retranslates is a no-op")
    func duplicateLaneClickIsRefused() async {
        let model = await makeSUT()
        let engine = LaneGatedEngine()
        model.retranslateEngineFactory = { _ in engine }
        model.translationSettings.selectRetranslate(.google)
        model.phase = .running
        let sentence = makeSentence(index: 7, text: "一")
        model.sessionController.onSentence?(sentence)

        model.retranslateSentence(sentence)
        #expect(await pollUntil(timeout: resultTimeout) { engine.recordedBatches.count == 1 })

        model.retranslateSentence(sentence)
        #expect(engine.recordedBatches.count == 1, "the marker refuses the duplicate")
        #expect(model.pendingRetranslations == [7])

        engine.openGate()
        #expect(await pollUntil(timeout: resultTimeout) { model.pendingRetranslations.isEmpty })
    }

    // MARK: - Phase gates

    @Test("a chained lane task that resumes after a stop retires its own marker")
    func chainedLaneTaskResumingAfterStopRetiresMarker() async {
        let model = await makeSUT()
        let engine = LaneGatedEngine()
        model.retranslateEngineFactory = { _ in engine }
        model.translationSettings.selectRetranslate(.google)
        model.phase = .running
        let first = makeSentence(index: 1, text: "一")
        let second = makeSentence(index: 2, text: "二")
        model.sessionController.onSentence?(first)
        model.sessionController.onSentence?(second)

        // The first flight parks; the second chains behind it on
        // `await previous?.value`, so it is still suspended when the stop
        // lands — its own entry guard is what has to retire its marker.
        model.retranslateSentence(first)
        #expect(await pollUntil(timeout: resultTimeout) { engine.recordedBatches.count == 1 })
        model.retranslateSentence(second)
        #expect(model.pendingRetranslations == [1, 2], "both rows are marked")

        await model.performStop()
        engine.openGate()
        try? await Task.sleep(for: .milliseconds(150))

        #expect(model.pendingRetranslations.isEmpty, "no marker outlives the stop")
        #expect(model.lanePendingRetranslations.isEmpty)
        #expect(
            engine.recordedBatches == [["一"]],
            "the chained task never issues an engine call once the session is gone"
        )
    }

    @Test("an arming lane session that resolves after the session went away is not flown")
    func armedLaneSessionArrivingAfterPhaseLossIsNotFlown() async {
        let model = await makeSUT()
        model.translationSettings.selectRetranslate(.appleFast)
        // An external live session, so the fast selection is a genuine
        // alternate and the lane arms its dedicated session on the click.
        model.activeTranslationEngine = .external
        model.activeExternalProvider = .google
        model.phase = .running
        let sentence = makeSentence(index: 5)
        model.sessionController.onSentence?(sentence)
        model.applyTranslation(index: 5, translation: SentenceTranslation(lang: "en", text: "Original"))

        // A long bound keeps the lane parked in its bounded wait for a
        // session that never arrives on its own.
        model.laneArmTimeout = .seconds(30)
        model.retranslateSentence(sentence)
        #expect(model.retranslateConfig != nil, "the fast lane arms on the click")
        #expect(model.pendingRetranslations.contains(5), "the click marked the row")
        // Let the lane task clear its entry guard and settle into the bounded
        // wait (one 50 ms poll interval), so the arrival below resolves the
        // wait rather than being caught by the entry guard instead.
        try? await Task.sleep(for: .milliseconds(150))

        // The session arrives as the session goes away — the ordering a
        // capture restart produces (the phase parks in `.starting`, no stop
        // involved). The wait resolves `.ready`, and the post-wait guard is
        // what has to refuse the flight and retire the marker.
        model.retranslateSessionArrived(LaneEchoEngine())
        model.phase = .starting
        try? await Task.sleep(for: .milliseconds(150))

        #expect(
            model.pendingRetranslations.isEmpty,
            "a flight the lane cannot deliver retires its marker"
        )
        #expect(model.lanePendingRetranslations.isEmpty)
        #expect(
            model.entries[0].translations == [SentenceTranslation(lang: "en", text: "Original")],
            "the row keeps its previous translation"
        )
    }

    @Test("a lane result landing after a stop is dropped")
    func laneResultAfterStopIsDropped() async {
        let model = await makeSUT()
        let engine = LaneGatedEngine()
        model.retranslateEngineFactory = { _ in engine }
        model.translationSettings.selectRetranslate(.google)
        model.phase = .running
        let sentence = makeSentence(index: 7)
        model.sessionController.onSentence?(sentence)
        model.applyTranslation(index: 7, translation: SentenceTranslation(lang: "en", text: "Original"))

        model.retranslateSentence(sentence)
        #expect(await pollUntil(timeout: resultTimeout) { engine.recordedBatches.count == 1 })

        await model.performStop()
        #expect(model.pendingRetranslations.isEmpty, "stop cleared the marker")
        #expect(model.phase == .idle)

        engine.openGate()
        // Give the late flight a beat to land before asserting it was dropped.
        try? await Task.sleep(for: .milliseconds(100))
        #expect(
            model.entries[0].translations == [SentenceTranslation(lang: "en", text: "Original")],
            "the late landing must not swap the row"
        )
        #expect(
            !model.toasts.toasts.contains(where: { toast in toast.key == ToastKey.retranslate }),
            "no failure toast after the stop cleared the stack"
        )
    }

    @Test("a queue unavailable mid-lane keeps the lane marker")
    func queueUnavailableKeepsLaneMarker() async {
        let model = await makeSUT()
        let engine = LaneGatedEngine()
        model.retranslateEngineFactory = { _ in engine }
        model.translationSettings.selectRetranslate(.google)
        model.phase = .running
        model.activeTranslationEngine = .apple
        let sentence = makeSentence(index: 7)
        model.sessionController.onSentence?(sentence)

        model.retranslateSentence(sentence)
        #expect(await pollUntil(timeout: resultTimeout) { engine.recordedBatches.count == 1 })

        model.handleTranslationStatus(.unavailable("Apple failed", .permanent))
        #expect(
            model.pendingRetranslations == [7],
            "the lane translation still has a deliverer"
        )
        #expect(model.lanePendingRetranslations == [7])

        model.retranslateSentence(sentence)
        #expect(engine.recordedBatches.count == 1, "the surviving marker refuses a duplicate")

        engine.openGate()
        #expect(await pollUntil(timeout: resultTimeout) { model.pendingRetranslations.isEmpty })
    }

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

    @Test("a lane flight held across a session boundary never swaps the next session's row")
    func laneFlightAcrossSessionBoundaryIsDropped() async {
        let model = await makeSUT()
        let engine = LaneGatedEngine()
        model.retranslateEngineFactory = { _ in engine }
        model.translationSettings.selectRetranslate(.google)
        model.phase = .running
        let sentence = makeSentence(index: 7)
        model.sessionController.onSentence?(sentence)
        model.applyTranslation(index: 7, translation: SentenceTranslation(lang: "en", text: "Original"))

        // The flight is parked mid-air when the session ends.
        model.retranslateSentence(sentence)
        #expect(await pollUntil(timeout: resultTimeout) { engine.recordedBatches.count == 1 })

        // Stop clears the markers and cancels the newest link, then a new
        // session begins — sentence indexes restart at 0, so the straggler's
        // index now names a DIFFERENT row. The epoch has to retire it.
        await model.performStop()
        model.phase = .running
        model.sessionController.onSessionBegin?()
        let next = makeSentence(index: 7, text: "次の文")
        model.sessionController.onSentence?(next)
        model.applyTranslation(index: 7, translation: SentenceTranslation(lang: "en", text: "Next session"))
        engine.openGate()

        #expect(
            await pollUntil(timeout: resultTimeout) { engine.recordedBatches.count == 1 },
            "the parked flight resumes after the gate opens"
        )
        try? await Task.sleep(for: .milliseconds(150))
        #expect(
            model.entries[0].translations == [SentenceTranslation(lang: "en", text: "Next session")],
            "the previous session's translation must not land on this session's row"
        )
        #expect(model.pendingRetranslations.isEmpty, "the straggler retires its marker")
        #expect(model.lanePendingRetranslations.isEmpty)
    }

    @Test("a lane flight dropped by a capture restart retires its marker")
    func laneFlightDuringCaptureRestartRetiresMarker() async {
        let model = await makeSUT()
        let engine = LaneGatedEngine()
        model.retranslateEngineFactory = { _ in engine }
        model.translationSettings.selectRetranslate(.google)
        model.phase = .sourceLost
        let sentence = makeSentence(index: 4)
        model.sessionController.onSentence?(sentence)
        model.applyTranslation(index: 4, translation: SentenceTranslation(lang: "en", text: "Original"))

        model.retranslateSentence(sentence)
        #expect(await pollUntil(timeout: resultTimeout) { engine.recordedBatches.count == 1 })
        #expect(model.pendingRetranslations.contains(4))

        // `restartCapture` parks the phase in `.starting` while the device
        // reopens. Neither it nor `onSessionBegin` clears the markers, so the
        // lane's own drop path has to — otherwise the row stays dimmed with a
        // dead retry button until session stop.
        model.phase = .starting
        engine.openGate()
        try? await Task.sleep(for: .milliseconds(150))

        #expect(
            !model.pendingRetranslations.contains(4),
            "a result the lane cannot deliver must retire its marker"
        )
        #expect(!model.lanePendingRetranslations.contains(4))
        #expect(
            model.entries[0].translations == [SentenceTranslation(lang: "en", text: "Original")],
            "the row keeps its previous translation"
        )
    }
}

/// Lane fixture whose `translate` parks until the gate opens, so a test can
/// hold a flight mid-air and prove a second click does not start a competing
/// one and that a late landing is dropped.
private final class LaneGatedEngine: TranslationEngine, @unchecked Sendable {
    let preferredBatchSize = 4
    var onRetry: (@Sendable (RetryProgress) -> Void)?

    private let state = Mutex(LaneGateState())

    var recordedBatches: [[String]] {
        state.withLock { gateState in gateState.batches }
    }

    /// Releases every parked `translate`, and lets any that arrives later
    /// through.
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
        state.withLock { gateState in gateState.batches.append(texts) }
        await withCheckedContinuation { continuation in
            let immediate = state.withLock { gateState -> CheckedContinuation<Void, Never>? in
                guard !gateState.open else { return continuation }
                gateState.waiters.append(continuation)
                return nil
            }
            immediate?.resume()
        }
        return texts.map { text in "JA:\(text)" }
    }
}

private struct LaneGateState {
    var open = false
    var batches: [[String]] = []
    var waiters: [CheckedContinuation<Void, Never>] = []
}

/// Session-engine fixture: prefixes with "EN:".
private final class QueueEchoEngine: TranslationEngine, @unchecked Sendable {
    let preferredBatchSize = 16
    var onRetry: (@Sendable (RetryProgress) -> Void)?

    func translate(_ texts: [String]) async throws -> [String] {
        texts.map { text in "EN:\(text)" }
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
