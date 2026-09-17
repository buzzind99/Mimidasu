import Foundation
@testable import Mimidasu
import Testing

/// Tests the cloud disclosure gate on external provider activation: a
/// key-verified probe that switches to a cloud provider holds the selection
/// in `providerAwaitingDisclosure` until the user confirms (which completes the
/// selection) or declines (which keeps the current provider and re-arms the
/// gate). The gate is per-switch, not a persisted one-time acknowledgment:
/// switching to an external provider raises it every time.
@MainActor
@Suite("AppModel cloud disclosure gate")
struct AppModelCloudDisclosureTests {

    // MARK: - Fixtures

    private func makeSettings(provider: TranslationProvider) -> TranslationSettings {
        let settings = isolatedTranslationSettings(suite: "test.AppModelCloudDisclosure")
        if provider != .apple {
            // A configured external provider is selected (the Settings key
            // card does this once the post-save connection test succeeds).
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

    /// Transport that answers 200 with a valid Google v2 translate body, so a
    /// Google probe succeeds (`translateProbe` rejects an empty translation).
    /// The OpenRouter key probe ignores the body.
    private func translatedBodyTransport() -> HTTPTranslationTransport {
        HTTPTranslationTransport(timeout: 5) { request in
            let body = Data(#"{"data":{"translations":[{"translatedText":"Hello"}]}}"#.utf8)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (body, response)
        }
    }

    /// Tears the model's translation worker down (stop requires a session
    /// phase; the queue worker is what actually needs cancelling).
    private func stopTranslation(_ model: AppModel) async {
        model.phase = .running
        model.stop()
        #expect(await pollUntil(timeout: 5) { model.phase == .idle }, "stop() winds the phase down to idle")
    }

    // MARK: - Disclosure gate

    /// The first activation of a cloud provider is held: the probe verifies
    /// (`.success` recorded, `true` returned) but the selection stays put
    /// until the disclosure is confirmed.
    @Test("the first external activation is held behind the cloud disclosure")
    func firstExternalProbeHoldsForDisclosure() async {
        let settings = makeSettings(provider: .apple)
        try? settings.saveKey("test-key-1234", for: .openrouter)
        let model = AppModel(
            translationSettings: settings,
            asrModelSettings: isolatedASRModelSettings(suite: "test.AppModelCloudDisclosure"),
            translationTransport: constantStatusTransport(200),
            initialModelResolve: { _ in nil }
        )

        let verified = await model.verifyAndSelectTranslationProvider(.openrouter)

        #expect(verified)
        #expect(settings.testResult(for: .openrouter) == .success)
        #expect(settings.selectedProvider == .apple, "the selection is held")
        #expect(model.providerAwaitingDisclosure == .openrouter)
        #expect(model.activeExternalProvider == nil, "activation waits for the selection")

        await stopTranslation(model)
    }

    /// Confirming the disclosure completes the held selection.
    @Test("confirming the disclosure selects the held provider")
    func confirmingDisclosureSelectsHeldProvider() async {
        let settings = makeSettings(provider: .apple)
        try? settings.saveKey("test-key-1234", for: .openrouter)
        let model = AppModel(
            translationSettings: settings,
            asrModelSettings: isolatedASRModelSettings(suite: "test.AppModelCloudDisclosure"),
            translationTransport: constantStatusTransport(200),
            initialModelResolve: { _ in nil }
        )

        _ = await model.verifyAndSelectTranslationProvider(.openrouter)
        model.confirmCloudDisclosure()

        #expect(model.providerAwaitingDisclosure == nil)
        #expect(settings.selectedProvider == .openrouter)

        await stopTranslation(model)
    }

    /// Declining leaves the selection untouched; the next switch to that
    /// provider raises the disclosure again.
    @Test("declining the disclosure keeps the current provider and re-arms the gate")
    func decliningDisclosureKeepsSelection() async {
        let settings = makeSettings(provider: .apple)
        try? settings.saveKey("test-key-1234", for: .openrouter)
        let model = AppModel(
            translationSettings: settings,
            asrModelSettings: isolatedASRModelSettings(suite: "test.AppModelCloudDisclosure"),
            translationTransport: constantStatusTransport(200),
            initialModelResolve: { _ in nil }
        )

        _ = await model.verifyAndSelectTranslationProvider(.openrouter)
        model.declineCloudDisclosure()

        #expect(model.providerAwaitingDisclosure == nil)
        #expect(settings.selectedProvider == .apple)

        let verified = await model.verifyAndSelectTranslationProvider(.openrouter)

        #expect(verified)
        #expect(model.providerAwaitingDisclosure == .openrouter, "the disclosure re-arms")
        #expect(settings.selectedProvider == .apple)

        await stopTranslation(model)
    }

    /// The gate is per-switch, not a persisted one-time acknowledgment:
    /// switching from one external provider to another raises it again.
    @Test("switching between external providers raises the disclosure every time")
    func switchingExternalProvidersRepeatsDisclosure() async {
        let settings = makeSettings(provider: .apple)
        try? settings.saveKey("test-key-1234", for: .openrouter)
        try? settings.saveKey("test-key-1234", for: .google)
        let model = AppModel(
            translationSettings: settings,
            asrModelSettings: isolatedASRModelSettings(suite: "test.AppModelCloudDisclosure"),
            translationTransport: translatedBodyTransport(),
            initialModelResolve: { _ in nil }
        )

        _ = await model.verifyAndSelectTranslationProvider(.openrouter)
        model.confirmCloudDisclosure()
        #expect(settings.selectedProvider == .openrouter)

        _ = await model.verifyAndSelectTranslationProvider(.google)

        #expect(model.providerAwaitingDisclosure == .google, "the switch re-raises the disclosure")
        #expect(settings.selectedProvider == .openrouter, "the selection waits for confirmation")

        await stopTranslation(model)
    }
}
