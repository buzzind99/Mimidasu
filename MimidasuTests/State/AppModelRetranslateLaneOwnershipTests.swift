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

    private let harness = RetranslateHarness(suite: "test.AppModelRetranslateLaneOwnership")
    private let sentenceText = "テスト"
    private let resultTimeout: TimeInterval = 5

    /// The plan routes externals by the stored key, so a lane-flight fixture
    /// that injects an engine must also store the key the click checks.
    private func saveTestKey(_ provider: TranslationProvider, on model: AppModel) {
        try? model.translationSettings.saveKey("sk-test-\(provider.rawValue)", for: provider)
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
        let model = await harness.makeModel()
        // A fresh gate per factory call: the first session's flight parks in
        // its own engine, the new session's retry in another — so the
        // straggler can be released while the new flight stays parked
        // mid-air, which is the only way to observe the marker DURING the
        // race.
        let stragglerEngine = LaneGatedEngine()
        let liveEngine = LaneGatedEngine()
        let factoryCalls = Mutex(0)
        model.retranslate.retranslateEngineFactory = { _, _ in
            let call = factoryCalls.withLock { counter -> Int in
                defer { counter += 1 }
                return counter
            }
            return call == 0 ? stragglerEngine : liveEngine
        }
        model.translationSettings.selectRetranslate(.google)
        saveTestKey(.google, on: model)
        model.phase = .running
        let worker = await harness.attachWorker(model, engine: LaneEchoEngine())
        let first = makeSentence(index: 7)
        model.sessionController.onSentence?(first)
        // Settle the worker's initial delivery: a queued or airborne
        // sentence refuses a lane click (`isAwaitingTranslation`).
        #expect(
            await pollUntil(timeout: resultTimeout) {
                model.pane.entries[0].translations == [SentenceTranslation(lang: "en", text: "JA:テスト")]
            },
            "the initial delivery landed before the retry"
        )

        // The first session's flight parks mid-air.
        model.retranslate.retranslateSentence(first)
        await expectPoll("the first session's flight parks in the engine") {
            stragglerEngine.recordedBatches.count == 1
        }
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
        model.retranslate.retranslateSentence(next)
        #expect(model.retranslate.pendingRetranslations == [7], "the new retry marked the row")
        await expectPoll("the new flight is parked mid-air") {
            liveEngine.recordedBatches.count == 1
        }

        // The straggler resolves now. Its delivery guard fails (stale
        // epoch), and its retirement must SKIP: the marker it would remove
        // by index belongs to the new epoch's parked flight.
        stragglerEngine.openGate()
        await expectPoll("the straggler's flight finished") { stragglerEngine.completions == 1 }
        #expect(
            model.retranslate.pendingRetranslations == [7],
            "the straggler's retire must not clear the new epoch's marker"
        )

        // The new flight delivers normally once released.
        liveEngine.openGate()
        await expectPoll("the new epoch's retry lands stamped") {
            model.pane.entries[0].translations
                == [SentenceTranslation(lang: "en", text: "JA:テスト", engine: .google)]
        }
        #expect(model.retranslate.pendingRetranslations.isEmpty, "the landing retires the marker")
        #expect(stragglerEngine.recordedBatches == [[sentenceText]], "the straggler flew once")
        #expect(liveEngine.recordedBatches == [[sentenceText]], "the new flight flew once")
    }

    @Test("a stopped lane does not fly an engine handed over during the arm wait")
    func stoppedLaneDropsLateHandover() async {
        let model = await harness.makeModel()
        let engine = LaneEchoEngine()
        model.translationSettings.selectRetranslate(.appleFast)
        model.appleHighFidelityProbe = (false, model.translationSettings.targetLanguage.code)
        // An external live session makes Apple-fast a genuine lane; the
        // dedicated fast session starts unarmed, so the flight parks in the
        // engine wait.
        model.translationSession.activeTranslationEngine = .external
        model.translationSession.activeExternalProvider = .google
        model.phase = .running
        let sentence = makeSentence(index: 7)
        model.sessionController.onSentence?(sentence)

        model.retranslate.retranslateSentence(sentence)
        #expect(model.retranslate.pendingRetranslations == [7], "the click parks in the arm wait")

        // Let the flight enter the wait before the boundary lands.
        try? await Task.sleep(for: .milliseconds(100))
        model.phase = .idle
        model.retranslate.retranslateSessionArrived(.appleFast, engine: engine)

        #expect(
            await pollUntil(timeout: resultTimeout) {
                model.retranslate.pendingRetranslations.isEmpty
            },
            "the late hand-over is retired, not flown"
        )
        #expect(engine.recordedBatches.isEmpty, "a stopped lane never calls the engine")
        #expect(
            !model.toasts.toasts.contains { toast in toast.key == ToastKey.retranslate },
            "the stop reports nothing"
        )
    }

    // MARK: - Backlog ownership

    @Test("a queue unavailable mid-lane keeps the lane marker")
    func queueUnavailableKeepsLaneMarker() async {
        let model = await harness.makeModel()
        let engine = LaneGatedEngine()
        model.retranslate.retranslateEngineFactory = { _, _ in engine }
        model.translationSettings.selectRetranslate(.google)
        saveTestKey(.google, on: model)
        model.phase = .running
        model.translationSession.activeTranslationEngine = .apple
        let sentence = makeSentence(index: 7)
        model.sessionController.onSentence?(sentence)

        model.retranslate.retranslateSentence(sentence)
        #expect(
            await pollUntil(timeout: resultTimeout) { engine.recordedBatches.count == 1 },
            "the flight parks in the engine"
        )

        model.handleTranslationStatus(.unavailable("Apple failed", .permanent))
        #expect(
            model.retranslate.pendingRetranslations == [7],
            "the lane translation still has a deliverer"
        )

        model.retranslate.retranslateSentence(sentence)
        #expect(engine.recordedBatches.count == 1, "the surviving marker refuses a duplicate")

        engine.openGate()
        #expect(
            await pollUntil(timeout: resultTimeout) { model.retranslate.pendingRetranslations.isEmpty },
            "the landing result retires the marker"
        )
    }

    @Test("a lane-retried backlog row is not overwritten by a later reconnect replay")
    func laneRetriedBacklogRowSurvivesReconnectReplay() async {
        let model = await harness.makeModel()
        let engine = LaneEchoEngine()
        model.retranslate.retranslateEngineFactory = { _, _ in engine }
        model.translationSettings.selectRetranslate(.google)
        saveTestKey(.google, on: model)
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
        model.retranslate.retranslateSentence(retried)
        #expect(
            await pollUntil(timeout: resultTimeout) {
                model.pane.entries[0].translations
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
                model.pane.entries[1].translations == [SentenceTranslation(lang: "en", text: "JA:二")]
            },
            "the replay served the remaining backlog"
        )
        #expect(
            model.pane.entries[0].translations
                == [SentenceTranslation(lang: "en", text: "JA:一", engine: .google)],
            "the replay never overwrote the lane-stamped row"
        )
        #expect(replay.recordedBatches == [["二"]], "the retried sentence was never re-flown")
    }

    // MARK: - Cache ownership

    @Test("a lane result whose row vanished never seeds the cache")
    func laneResultForVanishedRowSkipsCacheSeed() async {
        let model = await harness.makeModel()
        let engine = LaneGatedEngine()
        model.retranslate.retranslateEngineFactory = { _, _ in engine }
        model.translationSettings.selectRetranslate(.google)
        saveTestKey(.google, on: model)
        model.phase = .running
        let worker = Task { await model.translationQueue.run(with: QueueEchoEngine()) }
        defer { worker.cancel() }
        await expectPoll("the queue worker must be attached") { model.translationQueue.hasWorker }
        let sentence = makeSentence(index: 7)
        model.sessionController.onSentence?(sentence)
        await expectPoll("the initial delivery landed and seeded the queue cache") {
            model.pane.entries[0].translations == [SentenceTranslation(lang: "en", text: "EN:\(sentenceText)")]
        }

        // The retry parks mid-air; the transcript clears underneath it — the
        // production recipe for a row that vanishes while its result is in
        // flight.
        model.retranslate.retranslateSentence(sentence)
        await expectPoll("the flight parks in the engine") { engine.recordedBatches.count == 1 }
        model.pane.beginLiveSession()

        engine.openGate()
        _ = await model.retranslate.waitForLaneChainIdle()

        #expect(model.pane.entries.isEmpty, "the cleared transcript took the row with it")
        #expect(model.retranslate.pendingRetranslations.isEmpty, "a cleared pane still retires its marker")

        // The repeat serves the ORIGINAL cached translation — a seeded
        // retried text would surface here instead.
        model.sessionController.onSentence?(makeSentence(index: 9))
        await expectPoll("the repeat served the original cache entry") {
            model.pane.entries.count == 1
                && model.pane.entries[0].translations
                == [SentenceTranslation(lang: "en", text: "EN:\(sentenceText)")]
        }
        #expect(model.pane.entries[0].translations.first?.engine == nil)
    }
}
