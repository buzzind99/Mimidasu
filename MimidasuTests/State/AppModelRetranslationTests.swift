import Foundation
@testable import Mimidasu
import Synchronization
import Testing

/// Tests `AppModel`'s manual per-row re-translation surface end to end: a
/// real queue worker serves the retry, so the marker, the dim, and the
/// replace-in-place routing are all exercised through the same path the app
/// uses rather than by hand-delivering into `applyTranslation`.
///
/// The gating and clearing tests poke the marker directly — they are about
/// when it is inserted and cleared, and a worker would only make them wait.
@MainActor
@Suite("AppModel manual re-translation")
struct AppModelRetranslationTests {

    // MARK: - Fixtures

    private let sentenceText = "テスト"
    private let translationText = "Test"
    private let resultTimeout: TimeInterval = 5

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

    /// Attaches a queue worker the way `activateTranslation` does for an
    /// external provider, and waits for the run to take the engine — the
    /// retry gate refuses without one.
    @discardableResult
    private func attachWorker(_ model: AppModel, engine: any TranslationEngine) async -> Task<Void, Never> {
        let worker = Task { await model.translationQueue.run(with: engine) }
        #expect(
            await pollUntil(timeout: resultTimeout) { model.translationQueue.hasWorker },
            "the queue worker must be attached before a retry can be served"
        )
        return worker
    }

    /// Waits for the row to carry a translation, i.e. for the queue's `result`
    /// handler to have run `applyTranslation`.
    private func waitForTranslation(_ model: AppModel) async -> Bool {
        await pollUntil(timeout: resultTimeout) { model.entries.first?.joinedTranslations != nil }
    }

    // MARK: - Replace-on-arrival routing

    /// The whole shipped path: sentence emitted → translated by the engine →
    /// retry clicked → engine runs again → the row's translation is replaced,
    /// not appended. The row keeps exactly one translation throughout, so the
    /// retry never piles up an `" / "`-joined second copy.
    @Test("a manual re-translation replaces the row's translation in place")
    func retranslateReplacesInPlace() async {
        let model = await makeSUT()
        let engine = EchoRetranslateEngine()
        let worker = await attachWorker(model, engine: engine)
        defer { worker.cancel() }
        model.phase = .running

        let sentence = makeSentence(index: 7)
        model.sessionController.onSentence?(sentence)
        #expect(await waitForTranslation(model), "the first pass translates the row")
        #expect(model.entries[0].joinedTranslations == "EN:\(sentenceText)")

        model.retranslateSentence(sentence)
        #expect(model.pendingRetranslations == [7], "the row dims while the retry is in flight")
        #expect(
            await pollUntil(timeout: resultTimeout) { model.pendingRetranslations.isEmpty },
            "the landing result clears the in-flight marker"
        )

        #expect(model.entries[0].translations.count == 1, "replaced, not appended")
        #expect(model.entries[0].joinedTranslations == "EN:\(sentenceText)")
    }

    /// A second click while the first retry is still outstanding must not queue
    /// a second flight: the engine would run twice and the row would take two
    /// results for one sentence.
    @Test("a second retry click while the row already retranslates is a no-op")
    func retranslateTwiceIsIdempotent() async {
        let model = await makeSUT()
        let engine = GatedRetranslateEngine()
        let worker = await attachWorker(model, engine: engine)
        defer {
            engine.openGate()
            worker.cancel()
        }
        model.phase = .running

        let sentence = makeSentence(index: 7)
        model.sessionController.onSentence?(sentence)
        #expect(
            await pollUntil(timeout: resultTimeout) { engine.recordedBatches.count == 1 },
            "the first pass is airborne"
        )
        engine.openGate()
        #expect(await waitForTranslation(model), "the first pass translates the row")
        // Closed again so the *retry's* flight is the one parked below: the
        // second click must be refused with the retry genuinely outstanding.
        engine.closeGate()

        model.retranslateSentence(sentence)
        #expect(model.pendingRetranslations == [7], "the first click marks the row")
        #expect(
            await pollUntil(timeout: resultTimeout) { engine.recordedBatches.count == 2 },
            "the retry's batch is airborne"
        )

        model.retranslateSentence(sentence)
        #expect(model.pendingRetranslations == [7], "the second click must not churn the marker")
        #expect(
            engine.recordedBatches.count == 2,
            "the second click must not start another flight"
        )

        engine.openGate()
        #expect(
            await pollUntil(timeout: resultTimeout) { model.pendingRetranslations.isEmpty },
            "the single retry result lands and clears the marker"
        )
        #expect(
            model.entries[0].translations.count == 1,
            "exactly one retry result lands, replaced in place"
        )
        #expect(engine.recordedBatches.map(\.count) == [1, 1], "one flight per pass, no more")
    }

    /// The marker is only the first of two guards. This is the second: a row
    /// whose sentence is already in flight or queued has no marker yet, and a
    /// click on it must be refused by the queue's own check rather than
    /// queueing a competing copy.
    @Test("a retry click on a sentence already being translated is a no-op")
    func retranslateGatedOnAlreadyTranslating() async {
        let model = await makeSUT()
        let engine = GatedRetranslateEngine()
        let worker = await attachWorker(model, engine: engine)
        defer {
            engine.openGate()
            worker.cancel()
        }
        model.phase = .running

        let sentence = makeSentence(index: 7)
        model.sessionController.onSentence?(sentence)
        #expect(
            await pollUntil(timeout: resultTimeout) { engine.recordedBatches.count == 1 },
            "the first pass is airborne and parked on the gate"
        )

        model.retranslateSentence(sentence)

        #expect(
            model.pendingRetranslations.isEmpty,
            "a no-op must not dim the row it refused to serve"
        )
        #expect(engine.recordedBatches.count == 1, "no competing flight was queued")

        engine.openGate()
        #expect(await waitForTranslation(model), "the original flight still delivers")
        #expect(model.entries[0].translations.count == 1)
    }

    // MARK: - Gating

    /// Outside a live session there is nothing to serve the request, so the
    /// marker must not be inserted — a no-op can never dim the row.
    @Test("a manual re-translation outside a running session is a no-op")
    func retranslateGatedOnRunningPhase() async {
        let model = await makeSUT()
        model.phase = .idle

        model.retranslateSentence(makeSentence(index: 7))

        #expect(model.pendingRetranslations.isEmpty)
        let drained = await model.translationQueue.drain(timeout: 0.05)
        #expect(drained, "the gated retry must not enter the queue without a live session")
    }

    /// `.sourceLost` is a live session — capture died, but the translation
    /// worker is still attached and still draining — so a bad line stays
    /// retryable without restarting capture.
    @Test("a manual re-translation stays available after the capture source is lost")
    func retranslateAllowedInSourceLost() async {
        let model = await makeSUT()
        let engine = EchoRetranslateEngine()
        let worker = await attachWorker(model, engine: engine)
        defer { worker.cancel() }
        model.phase = .sourceLost

        let sentence = makeSentence(index: 7)
        model.sessionController.onSentence?(sentence)
        #expect(await waitForTranslation(model))

        model.retranslateSentence(sentence)
        #expect(
            await pollUntil(timeout: resultTimeout) { model.pendingRetranslations.isEmpty },
            "the retry is served while the source is lost"
        )
        #expect(engine.recordedBatches.count == 2)
        #expect(model.entries[0].translations.count == 1)
    }

    /// A session with no attached worker (the language pack was never
    /// installed, so `.translationTask` never fires) has nowhere to put the
    /// request. Inserting the marker anyway would dim the row permanently and
    /// lock out further clicks, since its own guard is what refuses them.
    @Test("a manual re-translation without an attached worker is a no-op")
    func retranslateGatedOnAttachedWorker() async {
        let model = await makeSUT()
        model.phase = .running

        model.retranslateSentence(makeSentence(index: 7))

        #expect(!model.translationQueue.hasWorker, "the fixture attaches no worker")
        #expect(
            model.pendingRetranslations.isEmpty,
            "no worker means no result, so the row must not dim"
        )
        let drained = await model.translationQueue.drain(timeout: 0.05)
        #expect(drained, "the gated retry must not enter the queue without a worker")
    }

    // MARK: - Marker clearing

    /// The one `.unavailable` that is followed by a fresh engine: latching the
    /// Apple fallback replays the very backlog the retry is sitting in, so the
    /// marker must survive to keep the row dimmed until that result lands.
    @Test("an unavailable external engine keeps the marker through the fallback")
    func unavailableExternalEngineKeepsPendingRetranslations() async {
        let model = await makeSUT()
        // Gated: the retry's flight parks, so nothing can retire the marker
        // but the code under test.
        let engine = GatedRetranslateEngine()
        let worker = await attachWorker(model, engine: engine)
        defer {
            engine.openGate()
            worker.cancel()
        }
        model.phase = .running
        model.activeTranslationEngine = .external

        model.retranslateSentence(makeSentence(index: 7))
        #expect(model.pendingRetranslations == [7], "the retry is marked pending")

        model.handleTranslationStatus(.unavailable("engine failed", .permanent))

        #expect(model.pendingRetranslations == [7], "the fallback will replay the sentence")
        #expect(model.translationFallbackActive, "the fallback latched onto Apple")
    }

    /// Every *other* `.unavailable` is terminal for the backlog: Apple itself
    /// failed (a language pack that is absent, a framework error), or this is
    /// the fallback's own Apple replay failing. Nothing will service the
    /// sentence, so a surviving marker would leave the row dimmed for the rest
    /// of the session *and* have its own guard refuse the click that fixes it.
    @Test("an unavailable Apple engine clears the marker so the row stays retryable")
    func unavailableAppleEngineClearsPendingRetranslations() async {
        let model = await makeSUT()
        let engine = GatedRetranslateEngine()
        let worker = await attachWorker(model, engine: engine)
        defer {
            engine.openGate()
            worker.cancel()
        }
        model.phase = .running
        model.activeTranslationEngine = .apple

        model.retranslateSentence(makeSentence(index: 7))
        #expect(model.pendingRetranslations == [7], "the retry is marked pending")

        model.handleTranslationStatus(.unavailable("Apple failed", .permanent))

        #expect(
            model.pendingRetranslations.isEmpty,
            "no engine swap follows, so the dim must not outlive the session"
        )
    }

    /// The fallback's own replay failing is the same dead end: the latch is
    /// already set, so no second swap is coming and the marker must go too.
    @Test("an unavailable status after the fallback latched clears the marker")
    func unavailableAfterFallbackClearsPendingRetranslations() async {
        let model = await makeSUT()
        model.phase = .running
        model.pendingRetranslations = [7]
        model.translationFallbackActive = true
        model.activeTranslationEngine = .apple

        model.handleTranslationStatus(.unavailable("Apple replay failed", .permanent))

        #expect(model.pendingRetranslations.isEmpty)
    }

    /// The transcript stays on screen after a stop, so a row waiting on a retry
    /// would sit dimmed with its (now hidden) button as the only cue.
    @Test("stopping clears pending re-translations so rows cannot stay dimmed")
    func stopClearsPendingRetranslations() async {
        let model = await makeSUT()
        model.phase = .running
        model.pendingRetranslations = [7]

        await model.performStop()

        #expect(model.pendingRetranslations.isEmpty)
        #expect(model.phase == .idle)
    }

    /// Sentence indexes restart at 0 every session, so a marker left over from
    /// the last one would alias an unrelated row: it would render dimmed from
    /// its first frame and its own guard would refuse the retry that fixes it.
    @Test("a new session clears pending re-translations so indexes cannot alias")
    func sessionBeginClearsPendingRetranslations() async {
        let model = await makeSUT()
        model.pendingRetranslations = [7]

        model.sessionController.onSessionBegin?()

        #expect(model.pendingRetranslations.isEmpty)
    }

    /// A result whose row is gone — the transcript cleared underneath it —
    /// must still retire its marker, or the index stays locked as dimmed.
    @Test("a result for an unknown row still clears its marker")
    func applyTranslationClearsMarkerForUnknownIndex() async {
        let model = await makeSUT()
        model.pendingRetranslations = [7]

        model.applyTranslation(index: 7, translation: SentenceTranslation(lang: "en", text: translationText))

        #expect(
            model.pendingRetranslations.isEmpty,
            "the marker must not outlive the row it was dimming"
        )
    }

    // MARK: - Arrival routing

    /// Routing is the entry's decision, not a flag the caller carries, so the
    /// ordinary queue path is covered by the same rule as a retry: a second
    /// result for a language the row already has replaces it.
    @Test("a repeat delivery for a language the row already has replaces it")
    func applyTranslationReplacesOnRepeatDelivery() async {
        let model = await makeSUT()
        let sentence = makeSentence(index: 7)
        model.sessionController.onSentence?(sentence)

        model.applyTranslation(index: 7, translation: SentenceTranslation(lang: "en", text: "First."))
        model.applyTranslation(index: 7, translation: SentenceTranslation(lang: "en", text: "Second."))

        #expect(model.entries[0].translations.count == 1, "replaced, not appended")
        #expect(model.entries[0].joinedTranslations == "Second.")
    }

    /// The converse: a genuinely new target language still joins the row,
    /// which is what makes the replace rule safe for the multi-target future.
    @Test("a delivery for a new language joins the row")
    func applyTranslationAppendsNewLanguage() async {
        let model = await makeSUT()
        model.sessionController.onSentence?(makeSentence(index: 7))

        model.applyTranslation(index: 7, translation: SentenceTranslation(lang: "en", text: "First."))
        model.applyTranslation(index: 7, translation: SentenceTranslation(lang: "ko", text: "두번째."))

        #expect(model.entries[0].translations.count == 2)
        #expect(model.entries[0].joinedTranslations == "First. / 두번째.")
    }
}

/// Echo engine: `"EN:<text>"` for every input, counting each batch so tests can
/// assert how many flights actually happened.
private final class EchoRetranslateEngine: TranslationEngine, @unchecked Sendable {
    let preferredBatchSize = 16
    var onRetry: (@Sendable (RetryProgress) -> Void)?

    private let state = Mutex(EchoEngineState())

    var recordedBatches: [[String]] {
        state.withLock { echoState in echoState.batches }
    }

    func translate(_ texts: [String]) async throws -> [String] {
        state.withLock { echoState in echoState.batches.append(texts) }
        return texts.map { text in "EN:\(text)" }
    }
}

private struct EchoEngineState {
    var batches: [[String]] = []
}

/// Engine whose `translate` parks until the gate opens, so a test can hold a
/// flight mid-air and prove a second click does not start a competing one.
/// `Mutex` guards the state because `translate` runs off the main actor.
private struct GatedRetranslateEngineState {
    var open = false
    var batches: [[String]] = []
    var waiters: [CheckedContinuation<Void, Never>] = []
}

private final class GatedRetranslateEngine: TranslationEngine, @unchecked Sendable {
    let preferredBatchSize = 16
    var onRetry: (@Sendable (RetryProgress) -> Void)?

    private let state = Mutex(GatedRetranslateEngineState())

    var recordedBatches: [[String]] {
        state.withLock { gateState in gateState.batches }
    }

    /// Releases every parked `translate`, and lets any that arrives later
    /// through. Repeat calls are safe — the waiters are drained, so there is
    /// nothing left to resume twice.
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

    /// Re-arms the gate so the *next* `translate` parks again — lets a test
    /// release one flight and then hold the next one, which a one-way flag
    /// cannot express. Parked waiters are unaffected (there are none between a
    /// drain and the next call).
    func closeGate() {
        state.withLock { gateState in gateState.open = false }
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
        return texts.map { text in "EN:\(text)" }
    }
}
