import Foundation
@testable import Mimidasu
import Synchronization
import Testing

/// Tests the high-fidelity (Apple Intelligence) probe wiring: a positive
/// probe marks the attached Apple engine for the ENGINES card, a negative
/// one leaves the row unchanged, and an external attach clears the marker.
/// The probe is the injected seam, so outcomes don't depend on the host's
/// Apple Intelligence state.
@MainActor
@Suite("AppModel high-fidelity probe")
struct AppModelTranslationHighFidelityTests {

    // MARK: - Fixtures

    private func makeSettings(provider: TranslationProvider) -> TranslationSettings {
        let settings = isolatedTranslationSettings(suite: "test.AppModelHighFidelity")
        if provider != .apple {
            try? settings.saveKey("test-key-1234", for: provider)
            settings.select(provider)
        }
        return settings
    }

    /// Transport that always answers with the given HTTP status (hermetic:
    /// no engine path reaches the real network during the tests).
    private func constantStatusTransport(_ status: Int) -> HTTPTranslationTransport {
        HTTPTranslationTransport(timeout: 5) { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil
            )!
            return (Data(), response)
        }
    }

    /// Tears the model's translation worker down (stop requires a session
    /// phase; the queue worker is what actually needs cancelling).
    private func stopTranslation(_ model: AppModel) async {
        model.phase = .running
        model.stop()
        #expect(await pollUntil(timeout: 5) { model.phase == .idle }, "stop() winds the phase down to idle")
    }

    // MARK: - Probe wiring

    /// The default probe is the real `LanguageAvailability` check — every
    /// other suite injects a probe, so this one deliberately non-hermetic
    /// construction keeps the production closure wired. Any settled answer
    /// counts; the installed/not-installed split is the OS's to make.
    @Test("the default probe drives the real availability check")
    func defaultProbeDrivesRealCheck() async throws {
        guard #available(macOS 26.4, *) else {
            try Test.cancel("the high-fidelity probe requires macOS 26.4")
        }
        let model = AppModel(
            translationSettings: makeSettings(provider: .apple),
            asrModelSettings: isolatedASRModelSettings(suite: "test.AppModelHighFidelity"),
            initialModelResolve: { _ in nil }
        )
        await model.initialModelCheck?.value

        model.retryTranslation()
        #expect(
            model.activeTranslationEngine == .apple,
            "the Apple engine attaches through the default probe"
        )

        await stopTranslation(model)
    }

    /// A positive probe lands on the attached Apple engine: the ENGINES
    /// card's marker reads it.
    @Test("a positive probe marks the attached Apple engine")
    func positiveProbeMarksAppleEngine() async {
        let model = AppModel(
            translationSettings: makeSettings(provider: .apple),
            asrModelSettings: isolatedASRModelSettings(suite: "test.AppModelHighFidelity"),
            highFidelityProbe: { _ in true },
            initialModelResolve: { _ in nil }
        )

        model.retryTranslation()
        #expect(await pollUntil { model.appleHighFidelity }, "the probe lands on the Apple engine")

        await stopTranslation(model)
    }

    /// A negative probe keeps the marker off — the Apple row stays "Apple".
    /// The marker is reset synchronously at activation, so the negative
    /// assertion only pins the wiring once a probe has actually landed: a
    /// call-counting probe answers `true` on the first activation, `false`
    /// on the second, and the test polls for the second call before
    /// asserting.
    @Test("a negative probe leaves the marker off")
    func negativeProbeLeavesMarkerOff() async {
        let probeCalls = Mutex(0)
        let model = AppModel(
            translationSettings: makeSettings(provider: .apple),
            asrModelSettings: isolatedASRModelSettings(suite: "test.AppModelHighFidelity"),
            highFidelityProbe: { _ in
                probeCalls.withLock { calls in
                    calls += 1
                    return calls == 1
                }
            },
            initialModelResolve: { _ in nil }
        )

        model.retryTranslation()
        #expect(await pollUntil { model.appleHighFidelity }, "the first (positive) probe marks the engine")

        model.retryTranslation()
        #expect(
            await pollUntil { probeCalls.withLock { calls in calls >= 2 } },
            "the second (negative) probe fires"
        )
        #expect(!model.appleHighFidelity, "the negative probe leaves the marker off")

        await stopTranslation(model)
    }

    /// Switching to an external provider clears the marker even after a
    /// positive Apple probe, and any probe still airborne from before the
    /// switch is dropped. (A later Apple fallback re-probes and may re-mark
    /// — that's the fallback path working, not a stale probe.)
    @Test("an external attach clears the marker")
    func externalAttachClearsMarker() async {
        let settings = makeSettings(provider: .apple)
        let model = AppModel(
            translationSettings: settings,
            asrModelSettings: isolatedASRModelSettings(suite: "test.AppModelHighFidelity"),
            translationTransport: constantStatusTransport(401),
            highFidelityProbe: { _ in true },
            initialModelResolve: { _ in nil }
        )

        model.retryTranslation()
        #expect(await pollUntil { model.appleHighFidelity })

        model.phase = .running
        try? settings.saveKey("test-key-1234", for: .google)
        settings.select(.google)
        model.translationProviderDidChange()
        #expect(model.activeTranslationEngine == .external)
        #expect(!model.appleHighFidelity, "the external attach clears the marker")

        await stopTranslation(model)
    }
}
