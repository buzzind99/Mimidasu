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
    /// a second flight: the engine would run twice and the second result would
    /// append, producing exactly the pileup a retry exists to avoid.
    @Test("a second retry click while the row already retranslates is a no-op")
    func retranslateTwiceIsIdempotent() async {
        let model = await makeSUT()
        let engine = GatedRetranslateEngine()
        let worker = await attachWorker(model, engine: engine)
        defer { worker.cancel() }
        model.phase = .running

        let sentence = makeSentence(index: 7)
        model.sessionController.onSentence?(sentence)
        engine.openGate()
        #expect(await waitForTranslation(model), "the first pass translates the row")

        model.retranslateSentence(sentence)
        let batchesAfterFirstClick = engine.recordedBatches.count
        model.retranslateSentence(sentence)
        #expect(model.pendingRetranslations == [7], "the second click must not churn the marker")
        #expect(
            engine.recordedBatches.count == batchesAfterFirstClick,
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
        #expect(engine.recordedBatches.map(\.count) == [1, 1], "one flight per click, no more")
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

    /// A `.unavailable` status latches the Apple fallback, which replays the
    /// very backlog the retry is sitting in. Dropping the marker here would
    /// route that replay through `appendTranslation` and re-create the
    /// `"old / new"` pileup the retry exists to prevent, so it must survive.
    @Test("an unavailable status keeps the marker so the replay replaces in place")
    func unavailableStatusKeepsPendingRetranslations() async {
        let model = await makeSUT()
        // Gated: the retry's flight parks, so nothing can retire the marker
        // but the code under test.
        let worker = await attachWorker(model, engine: GatedRetranslateEngine())
        defer { worker.cancel() }
        model.phase = .running

        model.retranslateSentence(makeSentence(index: 7))
        #expect(model.pendingRetranslations == [7], "the retry is marked pending")

        model.handleTranslationStatus(.unavailable("engine failed", .permanent))

        #expect(
            model.pendingRetranslations == [7],
            "the fallback replays the same sentence, so its marker must survive"
        )
    }

    /// The transcript stays on screen after a stop, so a row waiting on a retry
    /// would sit dimmed with its (now disabled) button as the only cue.
    @Test("stopping clears pending re-translations so rows cannot stay dimmed")
    func stopClearsPendingRetranslations() async {
        let model = await makeSUT()
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

    /// Releases every parked `translate`, and any that arrives later. Repeat
    /// calls are no-ops — the waiters are drained, so there is nothing left to
    /// resume twice.
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
        return texts.map { text in "EN:\(text)" }
    }
}
