import Foundation
@testable import Mimidasu
import Synchronization
import Testing

/// How a lane's external selection resolves to no engine: a test factory
/// that reports no engine, or the live-session build with no stored key.
enum UnavailableLaneEngine: String, CaseIterable, Sendable {
    case factoryWithoutEngine
    case missingKey

    var provider: TranslationProvider {
        switch self {
        case .factoryWithoutEngine: .openrouter
        case .missingKey: .google
        }
    }

    var selection: RetranslateEngine {
        switch self {
        case .factoryWithoutEngine: .openrouter
        case .missingKey: .google
        }
    }

    var usesFactory: Bool {
        switch self {
        case .factoryWithoutEngine: true
        case .missingKey: false
        }
    }

    /// The keyed route reaches the build, so its report names the failed
    /// build; the unkeyed route is refused at the plan with the missing key.
    var expectedToastBody: String {
        switch self {
        case .factoryWithoutEngine:
            "Couldn't build a \(provider.displayName) engine — try again in a moment."
        case .missingKey:
            "No API key stored for \(provider.displayName)."
        }
    }
}

/// Tests the alternate-engine re-translate lane's runner semantics against
/// mock engines: engine-stamped delivery, unstamped cache seeding,
/// serialization of lane flights, the post-stop phase gate, marker
/// ownership vs the queue's terminal `.unavailable` clear, and the lane
/// toasts.
@MainActor
@Suite("AppModel re-translate lane")
struct AppModelRetranslateLaneTests {

    // MARK: - Fixtures

    private let harness = RetranslateHarness(suite: "test.AppModelRetranslateLane")
    private let sentenceText = "テスト"
    private let resultTimeout: TimeInterval = 5

    /// The plan routes externals by the stored key, so a lane-flight fixture
    /// that injects an engine must also store the key the click checks.
    private func saveTestKey(_ provider: TranslationProvider, on model: AppModel) {
        try? model.translationSettings.saveKey("sk-test-\(provider.rawValue)", for: provider)
    }

    // MARK: - Lane delivery

    @Test("a lane result stamps the engine and seeds the cache unstamped")
    func laneResultStampsEngineAndSeedsCacheUnstamped() async {
        let model = await harness.makeModel()
        let engine = LaneEchoEngine()
        model.retranslate.retranslateEngineFactory = { provider, _ in
            #expect(provider == .google)
            return engine
        }
        model.translationSettings.selectRetranslate(.google)
        saveTestKey(.google, on: model)
        model.phase = .running
        let sentence = makeSentence(index: 7)
        model.sessionController.onSentence?(sentence)

        model.retranslate.retranslateSentence(sentence)

        #expect(
            await pollUntil(timeout: resultTimeout) {
                model.pane.entries[0].translations
                    == [SentenceTranslation(lang: "en", text: "JA:テスト", engine: .google)]
            },
            "the lane result lands stamped"
        )
        #expect(model.retranslate.pendingRetranslations.isEmpty, "the result retires the marker")
        #expect(engine.recordedBatches == [[sentenceText]], "one lane flight")

        // A later repeat of the sentence (a fresh row) serves through the
        // normal queue path: the retried text, no provenance.
        model.sessionController.onSentence?(makeSentence(index: 9))
        let repeatEntry = model.pane.entries.first(where: { entry in entry.sentence.index == 9 })
        #expect(repeatEntry?.translations == [SentenceTranslation(lang: "en", text: "JA:テスト")])
        #expect(repeatEntry?.translations.first?.engine == nil, "the seed is unstamped")
    }

    @Test(
        "an unavailable lane engine posts a toast and skips the row",
        arguments: UnavailableLaneEngine.allCases
    )
    func unavailableLaneEnginePostsToastAndSkips(testCase: UnavailableLaneEngine) async {
        let model = await harness.makeModel()
        let factoryCalled = Mutex(false)
        if testCase.usesFactory {
            // The plan admits the route on the stored key; the factory's
            // nil is then the build failure this case reports.
            saveTestKey(testCase.provider, on: model)
            model.retranslate.retranslateEngineFactory = { provider, _ in
                #expect(provider == testCase.provider)
                factoryCalled.withLock { called in called = true }
                return nil
            }
        }
        model.translationSettings.selectRetranslate(testCase.selection)
        model.phase = .running
        let sentence = makeSentence(index: 7)
        model.sessionController.onSentence?(sentence)
        model.applyTranslation(index: 7, translation: SentenceTranslation(lang: "en", text: "Original"))

        model.retranslate.retranslateSentence(sentence)

        #expect(model.retranslate.pendingRetranslations.isEmpty, "nothing is in flight — no marker")
        #expect(
            model.pane.entries[0].translations == [SentenceTranslation(lang: "en", text: "Original")],
            "the row keeps its previous translation"
        )
        let toast = model.toasts.toasts.first(where: { candidate in candidate.key == ToastKey.retranslate })
        #expect(toast?.title == "Re-translate unavailable")
        #expect(toast?.body == testCase.expectedToastBody)
        if testCase.usesFactory {
            #expect(
                factoryCalled.withLock { called in called },
                "the keyed route reached the build, rather than refusing at the plan"
            )
        }
    }

    // MARK: - Serialization

    @Test("lane translations serialize — the second click chains, never races")
    func laneTranslationsSerialize() async {
        let model = await harness.makeModel()
        let engine = LaneGatedEngine()
        model.retranslate.retranslateEngineFactory = { _, _ in engine }
        model.translationSettings.selectRetranslate(.google)
        saveTestKey(.google, on: model)
        model.phase = .running
        let first = makeSentence(index: 1, text: "一")
        let second = makeSentence(index: 2, text: "二")
        model.sessionController.onSentence?(first)
        model.sessionController.onSentence?(second)

        model.retranslate.retranslateSentence(first)
        #expect(
            await pollUntil(timeout: resultTimeout) { engine.recordedBatches.count == 1 },
            "the first flight enters the parked engine"
        )
        model.retranslate.retranslateSentence(second)
        #expect(engine.recordedBatches.count == 1, "the second click chains behind the first")

        engine.openGate()
        #expect(
            await pollUntil(timeout: resultTimeout) { engine.recordedBatches.count == 2 },
            "the chained flight runs once the gate opens"
        )
        #expect(engine.recordedBatches == [["一"], ["二"]], "strict one-at-a-time order")
        #expect(model.retranslate.pendingRetranslations.isEmpty)
    }

    @Test("a duplicate lane click while the row already retranslates is a no-op")
    func duplicateLaneClickIsRefused() async {
        let model = await harness.makeModel()
        let engine = LaneGatedEngine()
        model.retranslate.retranslateEngineFactory = { _, _ in engine }
        model.translationSettings.selectRetranslate(.google)
        saveTestKey(.google, on: model)
        model.phase = .running
        let sentence = makeSentence(index: 7, text: "一")
        model.sessionController.onSentence?(sentence)

        model.retranslate.retranslateSentence(sentence)
        #expect(
            await pollUntil(timeout: resultTimeout) { engine.recordedBatches.count == 1 },
            "the first flight parks in the engine"
        )

        model.retranslate.retranslateSentence(sentence)
        #expect(engine.recordedBatches.count == 1, "the marker refuses the duplicate")
        #expect(model.retranslate.pendingRetranslations == [7])

        engine.openGate()
        #expect(
            await pollUntil(timeout: resultTimeout) { model.retranslate.pendingRetranslations.isEmpty },
            "the landing result retires the marker"
        )
    }

    // MARK: - Phase gates

    @Test("a chained lane task that resumes after a stop retires its own marker")
    func chainedLaneTaskResumingAfterStopRetiresMarker() async {
        let model = await harness.makeModel()
        let engine = LaneGatedEngine()
        model.retranslate.retranslateEngineFactory = { _, _ in engine }
        model.translationSettings.selectRetranslate(.google)
        saveTestKey(.google, on: model)
        model.phase = .running
        let worker = await harness.attachWorker(model)
        defer { worker.cancel() }
        let first = makeSentence(index: 1, text: "一")
        let second = makeSentence(index: 2, text: "二")
        model.sessionController.onSentence?(first)
        model.sessionController.onSentence?(second)
        // Settle the worker's initial deliveries: a queued or airborne
        // sentence refuses a lane click (`isAwaitingTranslation`), and the
        // emptied backlog is what keeps the stop's drain instant.
        #expect(
            await pollUntil(timeout: resultTimeout) {
                model.pane.entries[0].translations == [SentenceTranslation(lang: "en", text: "EN:一")]
                    && model.pane.entries[1].translations == [SentenceTranslation(lang: "en", text: "EN:二")]
            },
            "the initial translations are delivered before the retries"
        )

        // The first flight parks; the second chains behind it on
        // `await previous?.value`, so it is still suspended when the stop
        // lands — its own entry guard is what has to retire its marker.
        model.retranslate.retranslateSentence(first)
        #expect(
            await pollUntil(timeout: resultTimeout) { engine.recordedBatches.count == 1 },
            "the first flight parks in the engine"
        )
        model.retranslate.retranslateSentence(second)
        #expect(model.retranslate.pendingRetranslations == [1, 2], "both rows are marked")

        await model.performStop()
        engine.openGate()
        // The idle chain covers the chained task: its `previous?.value`
        // unblocks only once the parked flight has fully finished, and the
        // task ends right after its entry guard — so the wait proves the
        // guard ran before the negative assertions below.
        _ = await model.retranslate.waitForLaneChainIdle()

        #expect(model.retranslate.pendingRetranslations.isEmpty, "no marker outlives the stop")
        #expect(
            engine.recordedBatches == [["一"]],
            "the chained task never issues an engine call once the session is gone"
        )
        #expect(engine.completions == 1, "only the parked flight ever flew")
    }

    @Test("an arming lane session that resolves after the session went away is not flown")
    func armedLaneSessionArrivingAfterPhaseLossIsNotFlown() async {
        let model = await harness.makeModel()
        model.translationSettings.selectRetranslate(.appleFast)
        // An external live session, so the fast selection is a genuine
        // alternate and the lane arms its dedicated session on the click.
        model.translationSession.activeTranslationEngine = .external
        model.translationSession.activeExternalProvider = .google
        model.phase = .running
        let sentence = makeSentence(index: 5)
        model.sessionController.onSentence?(sentence)
        model.applyTranslation(index: 5, translation: SentenceTranslation(lang: "en", text: "Original"))

        // A long bound keeps the lane parked in its bounded wait for a
        // session that never arrives on its own.
        model.retranslate.laneArmTimeout = .seconds(30)
        model.retranslate.retranslateSentence(sentence)
        #expect(model.retranslate.fastSessionConfig != nil, "the fast lane arms on the click")
        #expect(model.retranslate.pendingRetranslations.contains(5), "the click marked the row")
        // Let the lane task clear its entry guard and settle into the bounded
        // wait (one 50 ms poll interval), so the arrival below resolves the
        // wait rather than being caught by the entry guard instead. The
        // interleaving is load-precision only: if the task were slower, the
        // entry guard would catch the arrival instead and reach the same
        // final state, so the assertions stay valid either way.
        try? await Task.sleep(for: .milliseconds(150))

        // The session arrives as the session goes away — the ordering a
        // capture restart produces (the phase parks in `.starting`, no stop
        // involved). The wait resolves `.ready`, and the post-wait guard is
        // what has to refuse the flight and retire the marker. The markers
        // are retired by the lane task itself, so poll for them instead of
        // sleeping past it.
        model.retranslate.retranslateSessionArrived(.appleFast, engine: LaneEchoEngine())
        model.phase = .starting

        #expect(
            await pollUntil(timeout: resultTimeout) {
                model.retranslate.pendingRetranslations.isEmpty
            },
            "a flight the lane cannot deliver retires its marker"
        )
        #expect(
            model.pane.entries[0].translations == [SentenceTranslation(lang: "en", text: "Original")],
            "the row keeps its previous translation"
        )
    }

    @Test("a lane result landing after a stop is dropped")
    func laneResultAfterStopIsDropped() async {
        let model = await harness.makeModel()
        let engine = LaneGatedEngine()
        model.retranslate.retranslateEngineFactory = { _, _ in engine }
        model.translationSettings.selectRetranslate(.google)
        saveTestKey(.google, on: model)
        model.phase = .running
        let worker = await harness.attachWorker(model)
        defer { worker.cancel() }
        let sentence = makeSentence(index: 7)
        model.sessionController.onSentence?(sentence)
        // Settle the worker's own delivery first, then overwrite the row:
        // a delivery landing after "Original" would be indistinguishable
        // from the late lane landing this test hunts.
        #expect(
            await pollUntil(timeout: resultTimeout) {
                model.pane.entries[0].translations == [SentenceTranslation(lang: "en", text: "EN:テスト")]
            },
            "the worker's initial delivery landed"
        )
        model.applyTranslation(index: 7, translation: SentenceTranslation(lang: "en", text: "Original"))

        model.retranslate.retranslateSentence(sentence)
        #expect(
            await pollUntil(timeout: resultTimeout) { engine.recordedBatches.count == 1 },
            "the flight parks in the engine"
        )
        await model.performStop()
        #expect(model.retranslate.pendingRetranslations.isEmpty, "stop cleared the marker")
        #expect(model.phase == .idle)

        engine.openGate()
        _ = await model.retranslate.waitForLaneChainIdle()
        #expect(
            model.pane.entries[0].translations == [SentenceTranslation(lang: "en", text: "Original")],
            "the late landing must not swap the row"
        )
        #expect(
            !model.toasts.toasts.contains(where: { toast in toast.key == ToastKey.retranslate }),
            "no failure toast after the stop cleared the stack"
        )
    }

    @Test("a lane flight held across a session boundary never swaps the next session's row")
    func laneFlightAcrossSessionBoundaryIsDropped() async {
        let model = await harness.makeModel()
        let engine = LaneGatedEngine()
        model.retranslate.retranslateEngineFactory = { _, _ in engine }
        model.translationSettings.selectRetranslate(.google)
        saveTestKey(.google, on: model)
        model.phase = .running
        let worker = await harness.attachWorker(model)
        let sentence = makeSentence(index: 7)
        model.sessionController.onSentence?(sentence)
        // Settle the worker's initial delivery: a queued or airborne
        // sentence refuses a lane click (`isAwaitingTranslation`), and the
        // "Original" overwrite below must not race the worker's landing.
        #expect(
            await pollUntil(timeout: resultTimeout) {
                model.pane.entries[0].translations == [SentenceTranslation(lang: "en", text: "EN:テスト")]
            },
            "the initial delivery landed before the retry"
        )
        model.applyTranslation(index: 7, translation: SentenceTranslation(lang: "en", text: "Original"))

        // The flight is parked mid-air when the session ends.
        model.retranslate.retranslateSentence(sentence)
        #expect(
            await pollUntil(timeout: resultTimeout) { engine.recordedBatches.count == 1 },
            "the flight parks in the engine"
        )
        // Stop clears the markers and cancels the newest link, then a new
        // session begins — sentence indexes restart at 0, so the straggler's
        // index now names a DIFFERENT row. The epoch has to retire it. The
        // worker is released first: a live worker would pump the new
        // session's sentence and race the row write below.
        await model.performStop()
        worker.cancel()
        #expect(
            await pollUntil(timeout: resultTimeout) { !model.translationQueue.hasWorker },
            "the replay worker released the queue"
        )
        model.phase = .running
        model.sessionController.onSessionBegin?()
        let next = makeSentence(index: 7, text: "次の文")
        model.sessionController.onSentence?(next)
        model.applyTranslation(index: 7, translation: SentenceTranslation(lang: "en", text: "Next session"))
        engine.openGate()

        _ = await model.retranslate.waitForLaneChainIdle()
        #expect(
            model.pane.entries[0].translations == [SentenceTranslation(lang: "en", text: "Next session")],
            "the previous session's translation must not land on this session's row"
        )
        #expect(model.retranslate.pendingRetranslations.isEmpty, "no stale marker survives the boundary")
    }

    @Test("a lane flight dropped by a capture restart retires its marker")
    func laneFlightDuringCaptureRestartRetiresMarker() async {
        let model = await harness.makeModel()
        let engine = LaneGatedEngine()
        model.retranslate.retranslateEngineFactory = { _, _ in engine }
        model.translationSettings.selectRetranslate(.google)
        saveTestKey(.google, on: model)
        model.phase = .sourceLost
        let sentence = makeSentence(index: 4)
        model.sessionController.onSentence?(sentence)
        model.applyTranslation(index: 4, translation: SentenceTranslation(lang: "en", text: "Original"))

        model.retranslate.retranslateSentence(sentence)
        #expect(
            await pollUntil(timeout: resultTimeout) { engine.recordedBatches.count == 1 },
            "the flight parks in the engine"
        )
        #expect(model.retranslate.pendingRetranslations.contains(4))

        // `restartCapture` parks the phase in `.starting` while the device
        // reopens. Neither it nor `onSessionBegin` clears the markers, so the
        // lane's own drop path has to — otherwise the row stays dimmed with a
        // dead retry button until session stop. The capture restart leaves
        // the epoch alone, so the resumed flight's retirement is exactly
        // what clears the marker — poll for it instead of sleeping past it.
        model.phase = .starting
        engine.openGate()

        #expect(
            await pollUntil(timeout: resultTimeout) { !model.retranslate.pendingRetranslations.contains(4) },
            "a result the lane cannot deliver must retire its marker"
        )
        #expect(
            model.pane.entries[0].translations == [SentenceTranslation(lang: "en", text: "Original")],
            "the row keeps its previous translation"
        )
    }

    @Test("a mid-session teardown refuses an in-flight lane delivery silently")
    func midSessionTeardownRefusesInFlightLaneDelivery() async {
        let model = await harness.makeModel()
        let engine = LaneGatedEngine()
        model.retranslate.retranslateEngineFactory = { _, _ in engine }
        model.translationSettings.selectRetranslate(.google)
        saveTestKey(.google, on: model)
        model.phase = .running
        let sentence = makeSentence(index: 7)
        model.sessionController.onSentence?(sentence)
        model.applyTranslation(index: 7, translation: SentenceTranslation(lang: "en", text: "Original"))

        model.retranslate.retranslateSentence(sentence)
        #expect(
            await pollUntil(timeout: resultTimeout) { engine.recordedBatches.count == 1 },
            "the flight parks in the engine"
        )

        // A provider switch to Apple tears the armed re-translate sessions
        // down mid-session — while a lane flight is parked mid-air. The
        // teardown is a lane-generation change (task cancelled, epoch
        // bumped): the bump makes every lane-owned marker undeliverable, so
        // the teardown retires them synchronously, and the resumed flight
        // must stay silent instead of delivering over — or toasting over —
        // the activation the user just made. The gate is opened before the
        // chain-idle wait, so the negative assertions below run only once
        // the flight has fully resolved — a dropped epoch guard in the
        // delivery path would land after them and fail here.
        model.cancelArchiveTranslation()
        model.retranslate.teardown()
        engine.openGate()
        _ = await model.retranslate.waitForLaneChainIdle()

        #expect(
            await pollUntil(timeout: resultTimeout) {
                model.retranslate.pendingRetranslations.isEmpty
            },
            "the refused flight leaves no marker behind"
        )
        #expect(
            model.pane.entries[0].translations == [SentenceTranslation(lang: "en", text: "Original")],
            "the torn-down lane's result never lands"
        )
        #expect(
            !model.toasts.toasts.contains(where: { toast in toast.key == ToastKey.retranslate }),
            "the refusal posts nothing — the user caused the teardown"
        )
    }
}

/// Tests the awaited lane-chain idle member the bulk run's resolution uses.
@MainActor
@Suite("AppModel re-translate chain wait")
struct AppModelRetranslateChainWaitTests {

    private let harness = RetranslateHarness(suite: "test.AppModelRetranslateChainWait")
    private let resultTimeout: TimeInterval = 5

    @Test("a cancelled chain-idle wait reports an abandoned wait")
    func cancelledChainIdleWaitReportsAbandoned() async {
        let model = await harness.makeModel()
        let engine = LaneGatedEngine()
        model.retranslate.retranslateEngineFactory = { _, _ in engine }
        model.translationSettings.selectRetranslate(.google)
        try? model.translationSettings.saveKey("sk-test-google", for: .google)
        model.phase = .running
        let sentence = makeSentence(index: 7)
        model.sessionController.onSentence?(sentence)
        model.retranslate.retranslateSentence(sentence)
        #expect(
            await pollUntil(timeout: resultTimeout) { engine.recordedBatches.count == 1 },
            "the flight parks in the engine"
        )

        let wait = Task { await model.retranslate.waitForLaneChainIdle() }
        try? await Task.sleep(for: .milliseconds(50))
        wait.cancel()

        #expect(await wait.value == false, "a cancelled wait must not claim the chain is idle")
        engine.openGate()
        _ = await model.retranslate.waitForLaneChainIdle()
    }

    @Test("an already-cancelled task reports an abandoned chain wait")
    func cancelledTaskReportsAbandoned() async {
        let model = await harness.makeModel()

        let idle = await Task {
            withUnsafeCurrentTask { current in current?.cancel() }
            return await model.retranslate.waitForLaneChainIdle()
        }.value

        #expect(idle == false, "a cancelled task must not claim the chain is idle")
    }
}
