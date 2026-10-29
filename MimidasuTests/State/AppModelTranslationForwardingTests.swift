@testable import Mimidasu
import Testing

/// Tests the app-model façade over the translation coordinators: writes
/// route into the coordinator, and coordinator-side changes propagate
/// through the read-only forwarders — chiefly the `translationRuntime`
/// snapshot — as observation events, the mechanism SwiftUI's view
/// invalidation depends on for the `.translationTask` configs, the status
/// pill, and the row markers. Engine identity
/// (`activeTranslationEngine` / `activeExternalProvider`) is stamped
/// through the session accessors into the runtime snapshot — no
/// coordinator→facade observation test for it (the value-level reads live
/// in `AppModelTranslationEngineTests`).
@MainActor
@Suite("AppModel translation forwarding")
struct AppModelTranslationForwardingTests {

    private func makeModel() async -> AppModel {
        let model = makeIdleModel(suite: "test.AppModelTranslationForwarding")
        await model.initialModelCheck?.value
        return model
    }

    @Test("provider intent and lane-factory forwarders write through")
    func providerIntentAndFactoryForward() async {
        let model = await makeModel()

        let firstIntent = model.noteTranslationProviderIntent()
        let secondIntent = model.noteTranslationProviderIntent()
        #expect(secondIntent > firstIntent, "each row click gets a new token")

        model.retranslateEngineFactory = { _, _ in nil }
        #expect(
            model.retranslate.retranslateEngineFactory != nil,
            "the AppModel setter reaches the coordinator"
        )
        #expect(
            model.retranslateEngineFactory?(.openai, .english) == nil,
            "the AppModel getter returns the coordinator's factory"
        )
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

    @Test("a coordinator-side marker mutation propagates through the AppModel forwarder")
    func markerForwarderPropagates() async {
        let model = await makeModel()
        let observed = ObservedValuesRecorder(read: { model.pendingRetranslations })

        model.retranslate.pendingRetranslations.insert(7)

        #expect(
            await pollUntil { observed.values == [[7]] },
            "the marker-set forwarder fires observation"
        )
    }

    @Test("a lane-config change propagates through the AppModel forwarder")
    func laneConfigForwarderPropagates() async {
        let model = await makeModel()
        let observed = ObservedValuesRecorder(read: { model.retranslateConfig != nil })

        model.armRetranslateSessionIfNeeded(for: .appleFast)

        #expect(
            await pollUntil { observed.values == [true] },
            "the lane-config forwarder fires observation"
        )
    }

    @Test("the lane tuning getters read the coordinator's knobs")
    func laneTuningForwarders() async {
        let model = await makeModel()

        #expect(model.laneArmTimeout == .seconds(5))
        #expect(model.probeSettleTimeout == .seconds(3))

        model.laneArmTimeout = .milliseconds(25)
        model.probeSettleTimeout = .milliseconds(25)

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
