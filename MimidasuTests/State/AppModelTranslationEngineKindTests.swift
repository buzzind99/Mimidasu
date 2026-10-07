import Foundation
@testable import Mimidasu
import Testing
@preconcurrency import Translation

/// Tests `AppModel.activeEngineKind` — the row marker's comparison target.
/// An attached external provider maps through its kind; the Apple branch
/// reads `.appleFast` provisionally until the high-fidelity probe lands, and
/// only for the pair the probe actually measured.
@MainActor
@Suite("AppModel engine kind identity")
struct AppModelTranslationEngineKindTests {

    // MARK: - Fixtures

    private func makeSettings(provider: TranslationProvider) -> TranslationSettings {
        let settings = isolatedTranslationSettings(suite: "test.AppModelEngineKind")
        if provider != .apple {
            // A configured external provider is selected (the Settings key
            // card does this once the post-save connection test succeeds and
            // the cloud disclosure is confirmed).
            try? settings.saveKey("test-key-1234", for: provider)
            settings.select(provider)
        }
        return settings
    }

    /// Transport that always answers with the given HTTP status.
    private func constantStatusTransport(_ status: Int) -> HTTPTranslationTransport {
        HTTPTranslationTransport(timeout: 5) { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil
            )!
            return (Data(), response)
        }
    }

    /// Builds an `AppModel` over the given settings with the model resolve
    /// and the high-fidelity probe stubbed hermetically.
    private func makeModel(
        settings: TranslationSettings,
        transport: HTTPTranslationTransport? = nil
    ) -> AppModel {
        AppModel(
            translationSettings: settings,
            asrModelSettings: isolatedASRModelSettings(suite: "test.AppModelEngineKind"),
            favorites: isolatedFavorites(),
            translationTransport: transport,
            highFidelityProbe: { _ in false },
            initialModelResolve: { _ in nil }
        )
    }

    // MARK: - Kind identity

    @Test("an attached external provider maps to its kind")
    func attachedExternalProviderMapsToKind() async {
        // OpenRouter, whose 401 is permanent — the ladder stops, `stop` winds
        // down. (Google's 401 is a transient `.serverError` and would retry.)
        let model = makeModel(
            settings: makeSettings(provider: .openrouter),
            transport: constantStatusTransport(401)
        )
        // Let the launch check land while detached: a late `resolved` would
        // otherwise flip the freshly stopped `.idle` to `.needsModel`.
        await model.initialModelCheck?.value
        model.phase = .running
        model.translationProviderDidChange()
        #expect(model.activeTranslationEngine == .external)

        #expect(model.activeEngineKind == .openrouter)

        model.stop()
        #expect(
            await pollUntil(timeout: 5) { model.phase == .idle },
            "stop() winds the phase down to idle"
        )
    }

    @Test("an unprobed Apple activation reads fast provisionally")
    func unprobedAppleReadsFastProvisionally() {
        let model = makeModel(settings: makeSettings(provider: .apple))

        #expect(model.activeEngineKind == .appleFast)
    }

    @Test("an installed high-fidelity probe for the current pair reads high fidelity")
    func installedProbeForCurrentPairReadsHighFidelity() {
        let model = makeModel(settings: makeSettings(provider: .apple))
        model.appleHighFidelityProbe = (true, "en")

        #expect(model.activeEngineKind == .appleHighFidelity)
    }

    @Test("a probe for a different pair does not label the current target")
    func probeForDifferentPairDoesNotLabelCurrentTarget() {
        let model = makeModel(settings: makeSettings(provider: .apple))
        model.appleHighFidelityProbe = (true, "zh-Hans")

        #expect(model.activeEngineKind == .appleFast)
    }
}
