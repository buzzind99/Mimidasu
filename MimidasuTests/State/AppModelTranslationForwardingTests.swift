@testable import Mimidasu
import Testing

/// Tests the observation paths the translation surfaces depend on: the
/// `translationRuntime` snapshot the status surfaces read, the
/// provider-intent token the disclosure sheet tracks, the lane's armed
/// session config its `.translationTask` hosts observe, and the row plan's
/// in-flight marker. Engine identity (`activeTranslationEngine` /
/// `activeExternalProvider`) is stamped through the session accessors into
/// the runtime snapshot — no coordinator→view observation test for it (the
/// value-level reads live in `AppModelTranslationEngineTests`).
@MainActor
@Suite("AppModel translation forwarding")
struct AppModelTranslationForwardingTests {

    private func makeModel() async -> AppModel {
        let model = makeIdleModel(suite: "test.AppModelTranslationForwarding")
        await model.initialModelCheck?.value
        return model
    }

    @Test("each provider-row click advances the intent token")
    func providerIntentTokensAdvance() async {
        let model = await makeModel()

        let firstIntent = model.noteTranslationProviderIntent()
        let secondIntent = model.noteTranslationProviderIntent()
        #expect(secondIntent > firstIntent, "each row click gets a new token")
    }

    @Test("a coordinator-side status change propagates through the AppModel forwarder")
    func statusForwarderPropagates() async {
        let model = await makeModel()
        let observed = ObservedValuesRecorder(read: { model.translationRuntime.status })

        model.translationSession.translationStatus = .translating

        #expect(
            await pollUntil { observed.values == [.translating] },
            "the status forwarder fires observation"
        )
    }

    @Test("a status landing through handleTranslationStatus propagates")
    func statusHandlerPropagates() async {
        let model = await makeModel()
        let observed = ObservedValuesRecorder(read: { model.translationRuntime.status })

        model.handleTranslationStatus(.retrying("External translation failed, 1 retries left"))

        #expect(
            await pollUntil {
                observed.values == [.retrying("External translation failed, 1 retries left")]
            },
            "the queue-status path lands through the coordinator and notifies"
        )
    }

    @Test("engine identity stamped through the session accessors lands in the runtime")
    func engineAccessorsStampRuntime() async {
        let model = await makeModel()

        model.translationSession.activeTranslationEngine = .external
        model.translationSession.activeExternalProvider = .google

        #expect(model.translationSession.runtime.engine == .external)
        #expect(model.translationSession.runtime.externalProvider == .google)
    }

    @Test("the row plan observes a lane retry's in-flight marker")
    func rowPlanObservesInFlightMarker() async {
        let model = await makeModel()
        let gate = LaneGatedEngine()
        model.phase = .running
        try? model.translationSettings.saveKey("sk-test-google", for: .google)
        model.translationSettings.selectRetranslate(.google)
        model.retranslate.retranslateEngineFactory = { _, _ in gate }
        let sentence = makeSentence(index: 7)
        model.sessionController.onSentence?(sentence)
        let target = model.translationSettings.targetLanguage
        let entry = model.pane.entries[0]
        let observed = ObservedValuesRecorder(read: {
            model.retranslateRowPlan(for: entry, surface: .live, target: target).isRetranslating
        })

        model.retranslate.retranslateSentence(sentence)

        #expect(
            await pollUntil { observed.values == [true] },
            "the row plan observes the pending marker"
        )
        gate.openGate()
        _ = await model.retranslate.waitForLaneChainIdle()
    }

    @Test("an armed lane session config is observable")
    func laneConfigObservesArming() async {
        let model = await makeModel()
        let observed = ObservedValuesRecorder(read: { model.retranslate.fastSessionConfig != nil })

        model.retranslate.appleSessions.arm(kind: .appleFast, target: model.translationSettings.targetLanguage.code)

        #expect(
            await pollUntil { observed.values == [true] },
            "arming fires observation for the host's config read"
        )
    }

    @Test("the lane tuning knobs live on the coordinator")
    func laneTuningKnobs() async {
        let model = await makeModel()

        #expect(model.retranslate.laneArmTimeout == .seconds(5))
        #expect(model.retranslate.probeSettleTimeout == .seconds(3))

        model.retranslate.laneArmTimeout = .milliseconds(25)
        model.retranslate.probeSettleTimeout = .milliseconds(25)

        #expect(model.retranslate.laneArmTimeout == .milliseconds(25))
        #expect(model.retranslate.probeSettleTimeout == .milliseconds(25))
    }

    @Test("the live plan's run facts carry the live engine identity")
    func livePlanCarriesLiveEngineIdentity() async {
        let model = await makeModel()
        let target = model.translationSettings.targetLanguage

        let unlanded = model.retranslatePlan(surface: .live, target: target).context.live
        #expect(
            unlanded.runsFast == !AppleTierAvailability.supportsStrategySelection,
            "above the strategy API an unlanded probe leaves the live identity unprovable"
        )
        #expect(!unlanded.runsHighFidelity, "no probe landed — no provable high fidelity")

        model.translationSession.activeTranslationEngine = .external
        model.translationSession.activeExternalProvider = .google

        let external = model.retranslatePlan(surface: .live, target: target).context.live
        #expect(!external.runsFast, "an external live session runs no Apple kind")
        #expect(!external.runsHighFidelity, "an external live session runs no Apple kind")

        // A landed not-installed probe for the current target resolves the
        // live Apple session to the fast model — the one provable `true`
        // (below 26.4 Apple is always fast).
        model.translationSession.activeTranslationEngine = .apple
        model.translationSession.activeExternalProvider = nil
        let targetCode = model.translationSettings.targetLanguage.code
        model.appleHighFidelityProbe = (false, targetCode)

        let appleFast = model.retranslatePlan(surface: .live, target: target).context.live
        #expect(appleFast.runsFast, "a landed fast identity is provable")
        #expect(!appleFast.runsHighFidelity, "the fast identity is not the high-fidelity engine")
    }
}
