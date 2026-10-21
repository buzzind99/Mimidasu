import Foundation
@testable import Mimidasu
import Synchronization
import Testing

/// Tests the high-fidelity (Apple Intelligence) probe wiring: a positive
/// probe marks the attached Apple engine for the ENGINES card, a negative
/// one leaves the row unchanged, and an external attach re-probes — the
/// pair's availability is a machine fact, so the marker reflects the pair
/// under any live engine. The probe is the injected seam, so outcomes don't
/// depend on the host's Apple Intelligence state.
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
            favorites: isolatedFavorites(),
            archive: isolatedArchive(),
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
            favorites: isolatedFavorites(),
            archive: isolatedArchive(),
            highFidelityProbe: { _ in true },
            initialModelResolve: { _ in nil }
        )

        model.retryTranslation()
        #expect(await pollUntil { model.appleHighFidelity }, "the probe lands on the Apple engine")

        await stopTranslation(model)
    }

    /// A negative probe keeps the marker off — the Apple row stays
    /// "Apple (NMT)".
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
            favorites: isolatedFavorites(),
            archive: isolatedArchive(),
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

    /// Switching to an external provider re-probes: the sequence token
    /// drops any probe airborne from the Apple attach, and the fresh probe
    /// lands for the pair no matter which engine is live — so the marker
    /// reflects the machine, not the live engine (an external-live session
    /// with a stale "unknown" would let a persisted Apple Intelligence
    /// re-translate selection stamp fast-model output).
    @Test("an external attach re-probes and the marker reflects the pair")
    func externalAttachReprobesAndMarkerReflectsPair() async {
        let probeCalls = Mutex(0)
        let settings = makeSettings(provider: .apple)
        let model = AppModel(
            translationSettings: settings,
            asrModelSettings: isolatedASRModelSettings(suite: "test.AppModelHighFidelity"),
            favorites: isolatedFavorites(),
            archive: isolatedArchive(),
            translationTransport: constantStatusTransport(401),
            highFidelityProbe: { _ in
                probeCalls.withLock { calls in
                    calls += 1
                    return true
                }
            },
            initialModelResolve: { _ in nil }
        )

        model.retryTranslation()
        #expect(await pollUntil { model.appleHighFidelity }, "the Apple attach's probe marks the engine")

        model.phase = .running
        try? settings.saveKey("test-key-1234", for: .google)
        settings.select(.google)
        model.translationProviderDidChange()
        #expect(model.activeTranslationEngine == .external)
        // The attach reset the tuple synchronously (probe re-fires), so a
        // landed marker after the second probe call is the re-probe's
        // landing, not the Apple probe's.
        #expect(
            await pollUntil {
                probeCalls.withLock { calls in calls >= 2 } && model.appleHighFidelity
            },
            "the external attach re-probes and lands the pair's availability"
        )

        await stopTranslation(model)
    }

    /// A probe superseded before it landed must not mark the engine: every
    /// activation resets the tuple and bumps the sequence, so the stale
    /// landing is dropped and the fresh probe's answer stands.
    @Test("a superseded probe landing is dropped by the sequence token")
    func supersededProbeLandingIsDropped() async {
        let (gateStream, gate) = AsyncStream<Void>.makeStream()
        let probeCalls = Mutex(0)
        let model = AppModel(
            translationSettings: makeSettings(provider: .apple),
            asrModelSettings: isolatedASRModelSettings(suite: "test.AppModelHighFidelity"),
            favorites: isolatedFavorites(),
            archive: isolatedArchive(),
            highFidelityProbe: { _ in
                let call = probeCalls.withLock { calls in
                    calls += 1
                    return calls
                }
                guard call == 1 else { return true }
                // The first probe parks until the test releases it, so the
                // second activation supersedes it mid-flight.
                var iterator = gateStream.makeAsyncIterator()
                _ = await iterator.next()
                return false
            },
            initialModelResolve: { _ in nil }
        )

        model.retryTranslation()
        #expect(
            await pollUntil { probeCalls.withLock { calls in calls >= 1 } },
            "the first probe is airborne"
        )

        model.retryTranslation()
        let targetCode = model.translationSettings.targetLanguage.code
        #expect(
            await pollUntil { model.appleHighFidelityProbe == (true, targetCode) },
            "the fresh probe lands and marks the engine"
        )

        // Release the stale probe: its (negative) landing must be dropped.
        // The negative poll gives the stale landing time to (incorrectly)
        // arrive; `(false, targetCode)` cannot legitimately appear.
        gate.yield(())
        let staleOverwrote = await pollUntil(timeout: 0.5) {
            model.appleHighFidelityProbe == (false, targetCode)
        }
        #expect(!staleOverwrote, "the superseded probe's landing must not re-mark the engine")
    }
}
