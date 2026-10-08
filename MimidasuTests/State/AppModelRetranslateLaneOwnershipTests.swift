import Foundation
@testable import Mimidasu
import Synchronization
import Testing

/// Tests the re-translate lane's marker ownership across generations,
/// split out of the lane runner suite at the file-length gate: a stale
/// straggler's retirement must not clobber a new session's marker for a
/// recycled index, and a lane-retried backlog row must survive a later
/// reconnect replay.
@MainActor
@Suite("AppModel re-translate lane ownership")
struct AppModelRetranslateLaneOwnershipTests {

    // MARK: - Fixtures

    private let sentenceText = "テスト"
    private let resultTimeout: TimeInterval = 5

    private func makeSUT() async -> AppModel {
        let model = AppModel(
            translationSettings: isolatedTranslationSettings(suite: "test.AppModelRetranslateLaneOwnership"),
            asrModelSettings: isolatedASRModelSettings(suite: "test.AppModelRetranslateLaneOwnership"),
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

    /// Attaches a queue worker the way `activateTranslation` does, keeping a
    /// stop's translation-tail drain instant.
    @discardableResult
    private func attachWorker(_ model: AppModel) async -> Task<Void, Never> {
        let worker = Task { await model.translationQueue.run(with: LaneEchoEngine()) }
        #expect(
            await pollUntil(timeout: resultTimeout) { model.translationQueue.hasWorker },
            "the queue worker must be attached"
        )
        return worker
    }

    /// `#expect(await pollUntil(...))` with the message first, so the
    /// suite's many bounded waits read one line apiece.
    private func expectPoll(
        _ message: Comment,
        _ condition: @escaping () -> Bool
    ) async {
        #expect(
            await pollUntil(timeout: resultTimeout, condition),
            message
        )
    }

    // MARK: - Marker ownership across generations

    @Test("a stale straggler's retirement cannot clobber a new session's marker")
    func staleStragglerRetireCannotClearNewEpochMarker() async {
        let model = await makeSUT()
        // A fresh gate per factory call: the first session's flight parks in
        // its own engine, the new session's retry in another — so the
        // straggler can be released while the new flight stays parked
        // mid-air, which is the only way to observe the marker DURING the
        // race.
        let stragglerEngine = LaneGatedEngine()
        let liveEngine = LaneGatedEngine()
        let factoryCalls = Mutex(0)
        model.retranslateEngineFactory = { _ in
            let call = factoryCalls.withLock { counter -> Int in
                defer { counter += 1 }
                return counter
            }
            return call == 0 ? stragglerEngine : liveEngine
        }
        model.translationSettings.selectRetranslate(.google)
        model.phase = .running
        let worker = await attachWorker(model)
        let first = makeSentence(index: 7)
        model.sessionController.onSentence?(first)
        // Settle the worker's initial delivery: a queued or airborne
        // sentence refuses a lane click (`isAwaitingTranslation`).
        #expect(
            await pollUntil(timeout: resultTimeout) {
                model.entries[0].translations == [SentenceTranslation(lang: "en", text: "JA:テスト")]
            },
            "the initial delivery landed before the retry"
        )

        // The first session's flight parks mid-air.
        model.retranslateSentence(first)
        await expectPoll("the first session's flight parks in the engine") {
            stragglerEngine.recordedBatches.count == 1
        }
        // The straggler's own task: captured before the stop (the teardown
        // nils the stored task and the new session's retry replaces it), so
        // the marker assertion below can wait on the flight's full
        // resolution instead of racing its post-flight retire.
        let stragglerTask = model.retranslateLaneTask

        // The session dies and a new one begins — indexes restart, so 7
        // names a different row now. The worker is released first: a live
        // worker would pump the new session's sentence onto the row and
        // race the delivery assertion below.
        await model.performStop()
        worker.cancel()
        await expectPoll("the replay worker released the queue") {
            !model.translationQueue.hasWorker
        }
        model.phase = .running
        model.sessionController.onSessionBegin?()
        let next = makeSentence(index: 7)
        model.sessionController.onSentence?(next)

        // The user re-translates the SAME index in the new session: a live
        // marker for the new epoch, whose flight parks in the second gate.
        model.retranslateSentence(next)
        #expect(model.pendingRetranslations == [7], "the new retry marked the row")
        await expectPoll("the new flight is parked mid-air") {
            liveEngine.recordedBatches.count == 1
        }

        // The straggler resolves now. Its delivery guard fails (stale
        // epoch), and its retirement must SKIP: the marker it would remove
        // by index belongs to the new epoch's parked flight.
        stragglerEngine.openGate()
        await stragglerTask?.value
        await expectPoll("the straggler's flight finished") { stragglerEngine.completions == 1 }
        #expect(
            model.pendingRetranslations == [7],
            "the straggler's retire must not clear the new epoch's marker"
        )
        #expect(model.lanePendingRetranslations == [7])

        // The new flight delivers normally once released.
        liveEngine.openGate()
        await expectPoll("the new epoch's retry lands stamped") {
            model.entries[0].translations
                == [SentenceTranslation(lang: "en", text: "JA:テスト", engine: .google)]
        }
        #expect(model.pendingRetranslations.isEmpty, "the landing retires the marker")
        #expect(stragglerEngine.recordedBatches == [[sentenceText]], "the straggler flew once")
        #expect(liveEngine.recordedBatches == [[sentenceText]], "the new flight flew once")
    }

    // MARK: - Backlog ownership

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
        #expect(
            await pollUntil(timeout: resultTimeout) { engine.recordedBatches.count == 1 },
            "the flight parks in the engine"
        )

        model.handleTranslationStatus(.unavailable("Apple failed", .permanent))
        #expect(
            model.pendingRetranslations == [7],
            "the lane translation still has a deliverer"
        )
        #expect(model.lanePendingRetranslations == [7])

        model.retranslateSentence(sentence)
        #expect(engine.recordedBatches.count == 1, "the surviving marker refuses a duplicate")

        engine.openGate()
        #expect(
            await pollUntil(timeout: resultTimeout) { model.pendingRetranslations.isEmpty },
            "the landing result retires the marker"
        )
    }

    @Test("a lane-retried backlog row is not overwritten by a later reconnect replay")
    func laneRetriedBacklogRowSurvivesReconnectReplay() async {
        let model = await makeSUT()
        let engine = LaneEchoEngine()
        model.retranslateEngineFactory = { _ in engine }
        model.translationSettings.selectRetranslate(.google)
        model.phase = .running
        // No worker attached: both sentences pile up in the queue's
        // backlog — the state a failed-out engine leaves behind (pending
        // survives a run by design, so the backlog is what Reconnect
        // replays).
        let retried = makeSentence(index: 7, text: "一")
        let leftover = makeSentence(index: 8, text: "二")
        model.sessionController.onSentence?(retried)
        model.sessionController.onSentence?(leftover)

        // The lane serves the backlog row directly and evicts its queued
        // copy; the other sentence stays in the backlog.
        model.retranslateSentence(retried)
        #expect(
            await pollUntil(timeout: resultTimeout) {
                model.entries[0].translations
                    == [SentenceTranslation(lang: "en", text: "JA:一", engine: .google)]
            },
            "the lane result lands stamped on the backlog row"
        )

        // Reconnect: a worker attaches and replays the backlog. The replay
        // must serve the leftover only — a replayed copy of the retried
        // sentence would re-translate it and overwrite the stamped result
        // unstamped.
        let replay = LaneEchoEngine()
        let worker = Task { await model.translationQueue.run(with: replay) }
        defer { worker.cancel() }
        #expect(
            await pollUntil(timeout: resultTimeout) {
                model.entries[1].translations == [SentenceTranslation(lang: "en", text: "JA:二")]
            },
            "the replay served the remaining backlog"
        )
        #expect(
            model.entries[0].translations
                == [SentenceTranslation(lang: "en", text: "JA:一", engine: .google)],
            "the replay never overwrote the lane-stamped row"
        )
        #expect(replay.recordedBatches == [["二"]], "the retried sentence was never re-flown")
    }

    // MARK: - Cache ownership

    @Test("a lane result whose row vanished never seeds the cache")
    func laneResultForVanishedRowSkipsCacheSeed() async {
        let model = await makeSUT()
        let engine = LaneGatedEngine()
        model.retranslateEngineFactory = { _ in engine }
        model.translationSettings.selectRetranslate(.google)
        model.phase = .running
        let worker = Task { await model.translationQueue.run(with: QueueEchoEngine()) }
        defer { worker.cancel() }
        await expectPoll("the queue worker must be attached") { model.translationQueue.hasWorker }
        let sentence = makeSentence(index: 7)
        model.sessionController.onSentence?(sentence)
        await expectPoll("the initial delivery landed and seeded the queue cache") {
            model.entries[0].translations == [SentenceTranslation(lang: "en", text: "EN:\(sentenceText)")]
        }

        // The retry parks mid-air; the transcript clears the row underneath
        // it (the position map is what `applyTranslation` resolves through).
        model.retranslateSentence(sentence)
        await expectPoll("the flight parks in the engine") { engine.recordedBatches.count == 1 }
        let laneTask = model.retranslateLaneTask
        model.entryPositionBySentence.removeValue(forKey: 7)

        engine.openGate()
        await laneTask?.value

        #expect(model.pendingRetranslations.isEmpty, "a vanished row still retires its marker")
        #expect(model.lanePendingRetranslations.isEmpty)
        #expect(
            model.entries[0].translations == [SentenceTranslation(lang: "en", text: "EN:\(sentenceText)")],
            "the vanished row never took the retried text"
        )

        // The repeat serves the ORIGINAL cached translation — a seeded
        // retried text would surface here instead.
        model.sessionController.onSentence?(makeSentence(index: 9))
        await expectPoll("the repeat served the original cache entry") {
            model.entries[1].translations == [SentenceTranslation(lang: "en", text: "EN:\(sentenceText)")]
        }
        #expect(model.entries[1].translations.first?.engine == nil)
    }
}

/// Session-engine fixture: prefixes with "EN:", keeping the moved cache test's
/// initial deliveries distinct from the lane fixture's "JA:" prefix.
private final class QueueEchoEngine: TranslationEngine, @unchecked Sendable {
    let preferredBatchSize = 16
    var onRetry: (@Sendable (RetryProgress) -> Void)?

    func translate(_ texts: [String]) async throws -> [String] {
        texts.map { text in "EN:\(text)" }
    }
}

/// Lane fixture whose `translate` parks until the gate opens. Completed
/// flights are counted so an assertion can wait on the flight it concerns
/// instead of sleeping past it.
private final class LaneGatedEngine: TranslationEngine, @unchecked Sendable {
    let preferredBatchSize = 4
    var onRetry: (@Sendable (RetryProgress) -> Void)?

    private let state = Mutex(LaneGateState())

    var recordedBatches: [[String]] {
        state.withLock { gateState in gateState.batches }
    }

    /// Flights that entered, parked, and returned — the deterministic
    /// "this flight finished" observable.
    var completions: Int {
        state.withLock { gateState in gateState.completions }
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
        state.withLock { gateState in gateState.completions += 1 }
        return texts.map { text in "JA:\(text)" }
    }
}

private struct LaneGateState {
    var open = false
    var batches: [[String]] = []
    var waiters: [CheckedContinuation<Void, Never>] = []
    var completions = 0
}
