import Foundation
@testable import Mimidasu
import Testing

/// Tests the app-model façade over the translation coordinators: writes
/// route into the coordinator, and coordinator-side changes propagate
/// through the forwarded properties as observation events — the mechanism
/// SwiftUI's view invalidation depends on for the `.translationTask`
/// configs, the status pill, and the row markers. Engine identity
/// (`activeTranslationEngine` / `activeExternalProvider`) is write-through
/// only — no coordinator→facade observation test for it (the value-level
/// reads live in `AppModelTranslationEngineTests`).
@MainActor
@Suite("AppModel translation forwarding")
struct AppModelTranslationForwardingTests {

    private func makeModel() async -> AppModel {
        let model = AppModel(
            translationSettings: isolatedTranslationSettings(suite: "test.AppModelTranslationForwarding"),
            asrModelSettings: isolatedASRModelSettings(suite: "test.AppModelTranslationForwarding"),
            favorites: isolatedFavorites(),
            archive: isolatedArchive(),
            highFidelityProbe: { _ in false },
            initialModelResolve: { _ in nil }
        )
        await model.initialModelCheck?.value
        return model
    }

    @Test("a coordinator-side status change propagates through the AppModel forwarder")
    func statusForwarderPropagates() async {
        let model = await makeModel()
        let observed = ObservedValuesRecorder(read: { model.translationStatus })

        model.translationSession.translationStatus = .translating

        #expect(
            await pollUntil { observed.values == [.translating] },
            "the status forwarder fires observation"
        )
    }

    @Test("a status landing through handleTranslationStatus propagates")
    func statusHandlerPropagates() async {
        let model = await makeModel()
        let observed = ObservedValuesRecorder(read: { model.translationStatus })

        model.handleTranslationStatus(.retrying("External translation failed, 1 retries left"))

        #expect(
            await pollUntil {
                observed.values == [.retrying("External translation failed, 1 retries left")]
            },
            "the queue-status path lands through the coordinator and notifies"
        )
    }

    @Test("engine identity written through the AppModel forwarders reaches the coordinator")
    func engineForwarderWritesThrough() async {
        let model = await makeModel()

        model.activeTranslationEngine = .external
        model.activeExternalProvider = .google

        #expect(model.translationSession.activeTranslationEngine == .external)
        #expect(model.translationSession.activeExternalProvider == .google)
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

        #expect(model.retranslate.retranslateEngineFactory == nil)
        #expect(model.laneArmTimeout == .seconds(5))
        #expect(model.probeSettleTimeout == .seconds(3))

        model.laneArmTimeout = .milliseconds(25)
        model.probeSettleTimeout = .milliseconds(25)
        model.retranslateEngineFactory = { _, _ -> (any TranslationEngine)? in nil }

        #expect(model.retranslate.laneArmTimeout == .milliseconds(25))
        #expect(model.retranslate.probeSettleTimeout == .milliseconds(25))
        #expect(model.retranslate.retranslateEngineFactory != nil)
    }

    @Test("liveSessionRunsKind forwards the live engine identity")
    func liveSessionRunsKindForwards() async {
        let model = await makeModel()

        #expect(!model.liveSessionRunsKind(.appleFast), "no probe landed — no provable identity")

        model.activeTranslationEngine = .external
        model.activeExternalProvider = .google

        #expect(
            !model.liveSessionRunsKind(.appleFast),
            "an external live session runs no Apple kind"
        )

        // A landed not-installed probe for the current target resolves the
        // live Apple session to the fast model — the one provable `true`
        // (below 26.4 Apple is always fast).
        model.activeTranslationEngine = .apple
        model.activeExternalProvider = nil
        let targetCode = model.translationSettings.targetLanguage.code
        model.appleHighFidelityProbe = (false, targetCode)

        #expect(model.liveSessionRunsKind(.appleFast), "a landed fast identity is provable")
    }
}
