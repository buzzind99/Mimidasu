import Foundation
@testable import Mimidasu
import Synchronization
import Testing
@preconcurrency import Translation

/// Tests `AppModel`'s engine selection: an external provider spawns a
/// worker task (config stays nil), an exhausted external engine latches the
/// one-way Apple fallback per session, a manual retry resets the latch (the
/// next failure re-latches instead of parking on `.unavailable`), an
/// unconfigured selected provider degrades to Apple with a note, and a model
/// Save probes the draft before the caller persists it.
@MainActor
@Suite("AppModel engine selection + fallback")
struct AppModelTranslationEngineTests {

    // MARK: - Fixtures

    private let resultTimeout: TimeInterval = 5

    private func makeSentence(index: Int, text: String) -> Sentence {
        Sentence(index: index, startS: 0, endS: 1, lang: "ja", text: text)
    }

    private func makeSettings(provider: TranslationProvider) -> TranslationSettings {
        let settings = isolatedTranslationSettings(suite: "test.AppModelEngine")
        if provider != .apple {
            // A configured external provider is selected (the Settings key
            // card does this once the post-save connection test succeeds and
            // the cloud disclosure is confirmed).
            try? settings.saveKey("test-key-1234", for: provider)
            settings.select(provider)
        }
        return settings
    }

    /// Transport that always answers with the given HTTP status (a failing
    /// engine without retry-inducing latency: 401 is non-transient).
    private func constantStatusTransport(_ status: Int) -> HTTPTranslationTransport {
        HTTPTranslationTransport(timeout: 5) { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil
            )!
            return (Data(), response)
        }
    }

    /// Transport that answers every request with a valid chat-completions
    /// reply, so an LLM provider's translation probe succeeds.
    private func successfulTranslationTransport() -> HTTPTranslationTransport {
        HTTPTranslationTransport(timeout: 5) { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (chatCompletionReplyBody, response)
        }
    }

    /// Transport that answers the first chat-completions request with 401 (a
    /// dead key fails the live translation) and every later one with a valid
    /// reply (the re-test probe succeeds).
    private func failThenSucceedTransport() -> HTTPTranslationTransport {
        let attempts = Mutex(0)
        return HTTPTranslationTransport(timeout: 5) { request in
            let attempt = attempts.withLock { state -> Int in
                state += 1
                return state
            }
            let status = attempt == 1 ? 401 : 200
            let body = attempt == 1 ? Data() : chatCompletionReplyBody
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil
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

    /// Builds an `AppModel` over the given settings with the model resolve
    /// and the high-fidelity probe stubbed hermetically — Apple activations
    /// never reach the real `LanguageAvailability`.
    private func makeModel(
        settings: TranslationSettings,
        transport: HTTPTranslationTransport? = nil
    ) -> AppModel {
        AppModel(
            translationSettings: settings,
            asrModelSettings: isolatedASRModelSettings(suite: "test.AppModelEngine"),
            favorites: isolatedFavorites(),
            archive: isolatedArchive(),
            translationTransport: transport,
            highFidelityProbe: { _ in false },
            initialModelResolve: { _ in nil }
        )
    }

    // MARK: - Engine selection

    @Test("an external provider spawns a worker and parks the Apple host")
    func externalProviderSpawnsWorkerWithoutConfig() async {
        let model = makeModel(
            settings: makeSettings(provider: .openrouter),
            transport: constantStatusTransport(500)
        )

        model.retryTranslation()
        #expect(await pollUntil { model.translationStatus == .ready }, "retryTranslation publishes .ready")

        #expect(model.activeTranslationEngine == .external)
        #expect(model.translationConfig == nil)

        await stopTranslation(model)
    }

    @Test("an unconfigured selected provider degrades to Apple")
    func unconfiguredProviderFallsBackToApple() {
        let settings = isolatedTranslationSettings(suite: "test.AppModelEngine")
        settings.select(.openrouter)
        let model = makeModel(settings: settings)

        model.retryTranslation()

        #expect(model.activeTranslationEngine == .apple)
        #expect(model.translationConfig != nil)
    }

    @Test("each external provider builds its engine and spawns the worker")
    func eachExternalProviderBuildsItsEngine() async {
        for provider in [TranslationProvider.google, .deepl, .openai] {
            let model = makeModel(
                settings: makeSettings(provider: provider),
                transport: constantStatusTransport(401)
            )

            model.retryTranslation()
            #expect(
                await pollUntil { model.translationStatus == .ready },
                "retryTranslation publishes .ready (\(provider))"
            )

            #expect(model.activeTranslationEngine == .external, "\(provider)")
            #expect(model.translationConfig == nil, "\(provider)")

            await stopTranslation(model)
        }
    }

    // MARK: - Latched auto-fallback

    @Test("an exhausted external engine latches Apple fallback with a degraded status")
    func externalFailureLatchesAppleFallback() async {
        let model = makeModel(
            settings: makeSettings(provider: .openrouter),
            transport: constantStatusTransport(401)
        )

        model.retryTranslation()
        #expect(model.activeTranslationEngine == .external)
        model.translationQueue.enqueue(makeSentence(index: 0, text: "テスト"))

        #expect(await pollUntil { model.translationFallbackActive }, "the exhausted engine latches the Apple fallback")

        #expect(model.translationFallbackActive)
        #expect(model.activeTranslationEngine == .apple)
        #expect(model.translationConfig != nil, "the Apple host must be re-activated")
        #expect(
            model.translationStatus
                == .degraded(
                    "External translation failed — using Apple on-device. "
                        + "Invalid API key. Check the key in Settings, then reconnect.",
                    .permanent
                )
        )
        // The degraded card carries the Reconnect affordance; it must survive
        // the fresh Apple run's `.ready` while the latch is active.
        let fallbackToast = model.toasts.toasts.first { toast in toast.key == ToastKey.translationFallback }
        #expect(fallbackToast?.style == .yellowPersistent)
        #expect(fallbackToast?.action?.label == "Reconnect")

        await stopTranslation(model)
    }

    /// Every manual retry resets `translationFallbackActive`, so a
    /// failure after a retry re-latches onto Apple instead of parking on
    /// `.unavailable` forever.
    @Test("a manual retry re-arms the one-way fallback latch")
    func manualRetryRearmsFallbackLatch() async {
        let model = makeModel(
            settings: makeSettings(provider: .openrouter),
            transport: constantStatusTransport(401)
        )

        // First failure: latches onto Apple.
        model.retryTranslation()
        model.translationQueue.enqueue(makeSentence(index: 0, text: "テスト"))
        #expect(await pollUntil { model.translationFallbackActive }, "the first failure latches the Apple fallback")

        // Manual retry resets the latch and re-attempts the external engine
        // (the key may have been fixed).
        model.retryTranslation()
        #expect(!model.translationFallbackActive, "the retry re-arms the fallback")
        #expect(model.activeTranslationEngine == .external)

        // A second failure re-latches instead of parking on .unavailable.
        model.translationQueue.enqueue(makeSentence(index: 1, text: "こんにちは"))
        #expect(
            await pollUntil { model.translationFallbackActive },
            "the retried failure re-latches the Apple fallback"
        )
        #expect(model.activeTranslationEngine == .apple, "no parking on .unavailable")
        #expect(model.translationConfig != nil, "the Apple host is re-activated again")

        await stopTranslation(model)
    }

    // MARK: - Retry progress wiring

    /// The engine's `onRetry` is wired to `queue.noteRetry`: a transient
    /// failure surfaces `.retrying` with the footer copy and resolves back
    /// to `.ready` when the retried attempt succeeds.
    @Test("engine retry progress surfaces as .retrying and resolves to ready")
    func engineRetryProgressSurfacesAsRetrying() async {
        // First round-trip 429 (transient → one retry), then a valid
        // chat-completions response.
        let attempts = Mutex(0)
        let transport = HTTPTranslationTransport(timeout: 5) { request in
            let attempt = attempts.withLock { state -> Int in
                state += 1
                return state
            }
            let status = attempt == 1 ? 429 : 200
            let body = attempt == 1
                ? Data()
                : Data(#"{"choices":[{"message":{"content":"hello"}}]}"#.utf8)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil
            )!
            return (body, response)
        }
        let model = makeModel(
            settings: makeSettings(provider: .openrouter),
            transport: transport
        )
        let recorder = TextRecorder()
        var statuses: [TranslationStatus] = []
        // Replace AppModel's wiring with an observation tap: results land in
        // a local recorder (no transcript entries exist in this test) and
        // statuses keep flowing through the model.
        model.translationQueue.setHandlers(
            result: { _, translation in recorder.record(translation.text) },
            status: { [weak model] status in
                statuses.append(status)
                model?.handleTranslationStatus(status)
            }
        )

        model.retryTranslation()
        model.translationQueue.enqueue(makeSentence(index: 0, text: "テスト"))

        // The queue publishes .ready after the result; poll on the status so
        // the assertions below observe the settled sequence.
        #expect(await pollUntil { statuses.last == .ready }, "the retried attempt resolves back to ready")

        #expect(recorder.texts == ["hello"])
        #expect(
            statuses.contains(.retrying("External translation failed, 2 retries left")),
            "statuses were \(statuses)"
        )
        #expect(statuses.last == .ready)

        await stopTranslation(model)
    }
}

extension AppModelTranslationEngineTests {

    // MARK: - Mid-session provider change

    /// A selection change while a session runs re-attaches the engine
    /// immediately: Apple swaps the queue onto the on-device host (nil
    /// external provider), a later external switch rebuilds that engine and
    /// records it. While idle the change is deferred to session start.
    @Test("a mid-session provider change re-attaches the engine; idle defers")
    func providerChangeReattachesEngineMidSession() async {
        let settings = makeSettings(provider: .openrouter)
        let model = makeModel(
            settings: settings,
            transport: constantStatusTransport(401)
        )

        // Attach the external engine (as session start would).
        model.retryTranslation()
        #expect(await pollUntil { model.translationStatus == .ready })
        #expect(model.activeTranslationEngine == .external)
        #expect(model.activeExternalProvider == .openrouter)

        // Idle: a selection change defers — nothing activates.
        settings.select(.apple)
        model.phase = .idle
        model.translationProviderDidChange()
        #expect(model.activeTranslationEngine == .external, "no activation while idle")
        #expect(model.activeExternalProvider == .openrouter)

        // Running: the change re-attaches Apple right away.
        model.phase = .running
        model.translationProviderDidChange()
        #expect(model.activeTranslationEngine == .apple)
        #expect(model.activeExternalProvider == nil)
        #expect(model.translationConfig != nil, "the Apple host must be re-activated")

        // Back to an external provider (configured + selected, as the key
        // card's verified-key path does): the new engine is built and
        // recorded.
        try? settings.saveKey("test-key-1234", for: .google)
        settings.select(.google)
        model.translationProviderDidChange()
        #expect(model.activeTranslationEngine == .external)
        #expect(model.activeExternalProvider == .google)

        await stopTranslation(model)
    }

    /// An explicit provider change clears the latched Apple fallback — user
    /// intent to re-engage, same as a manual retry — and dismisses the
    /// fallback card.
    @Test("a mid-session provider change resets the fallback latch")
    func providerChangeResetsFallbackLatch() async {
        let settings = makeSettings(provider: .openrouter)
        let model = makeModel(
            settings: settings,
            transport: constantStatusTransport(401)
        )

        model.retryTranslation()
        model.translationQueue.enqueue(makeSentence(index: 0, text: "テスト"))
        #expect(await pollUntil { model.translationFallbackActive }, "the failure latches the Apple fallback")

        // A verified Google key selects it (the key card's success path);
        // the explicit change then rebuilds the queue onto the Google engine.
        try? settings.saveKey("test-key-1234", for: .google)
        settings.select(.google)
        model.phase = .running
        model.translationProviderDidChange()

        #expect(!model.translationFallbackActive, "an explicit change re-arms the fallback")
        #expect(model.activeTranslationEngine == .external)
        #expect(model.activeExternalProvider == .google)
        #expect(
            !model.toasts.toasts.contains { toast in toast.key == ToastKey.translationFallback },
            "the fallback card is dismissed"
        )

        await stopTranslation(model)
    }

    /// Selecting an unconfigured external provider mid-session keeps the
    /// currently attached engine instead of degrading to Apple — it's a
    /// settings edit; the key save's connection test activates the new
    /// provider once it verifies.
    @Test("selecting an unconfigured provider keeps the active engine")
    func unconfiguredProviderChangeKeepsActiveEngine() async {
        let settings = makeSettings(provider: .openrouter)
        let model = makeModel(
            settings: settings,
            transport: constantStatusTransport(401)
        )

        model.retryTranslation()
        #expect(await pollUntil { model.translationStatus == .ready })
        #expect(model.activeExternalProvider == .openrouter)

        // Selecting DeepL with no key: the OpenRouter engine stays attached.
        model.phase = .running
        settings.select(.deepl)
        model.translationProviderDidChange()

        #expect(model.activeTranslationEngine == .external)
        #expect(model.activeExternalProvider == .openrouter, "the unconfigured selection doesn't evict the active engine")

        // A verified DeepL key selects it (the key card's success path) and
        // then activates it.
        try? settings.saveKey("test-key-1234", for: .deepl)
        settings.select(.deepl)
        model.translationProviderDidChange()
        #expect(model.activeTranslationEngine == .external)
        #expect(model.activeExternalProvider == .deepl)

        await stopTranslation(model)
    }

    // MARK: - Connection-verified provider switch

    /// A verified probe to a different external provider holds the selection
    /// behind the disclosure; confirming moves it, and the engine attaches
    /// only when the settings change is applied (the SettingsView `.onChange`
    /// contract).
    @Test("a verified probe holds for disclosure; confirming attaches its engine")
    func verifiedProbeSelectsProvider() async {
        let settings = makeSettings(provider: .google)
        try? settings.saveKey("test-key-1234", for: .openrouter)
        let model = makeModel(
            settings: settings,
            transport: successfulTranslationTransport()
        )
        await model.initialModelCheck?.value
        model.retryTranslation()
        #expect(await pollUntil { model.translationStatus == .ready })
        model.phase = .running

        let verified = await model.verifyAndSelectTranslationProvider(.openrouter)

        #expect(verified.didVerify)
        #expect(settings.testResult(for: .openrouter) == .success)
        #expect(settings.selectedProvider == .google, "the switch waits for the disclosure")
        #expect(model.providerAwaitingDisclosure == .providerSwitch(.openrouter))

        model.confirmCloudDisclosure(.providerSwitch(.openrouter))
        #expect(settings.selectedProvider == .openrouter, "confirming moves the selection")
        #expect(model.activeExternalProvider == .google, "activation waits for the settings-change observer")

        // SettingsView's onChange applies the selection change.
        model.translationProviderDidChange()
        #expect(model.activeTranslationEngine == .external)
        #expect(model.activeExternalProvider == .openrouter)

        await stopTranslation(model)
    }

    /// A verified probe for Apple itself selects it directly: Apple needs no
    /// key verification round-trip (the connection tester answers
    /// immediately) and no disclosure, so the held-selection machinery
    /// never engages.
    @Test("a verified Apple probe selects Apple directly")
    func verifiedAppleProbeSelectsAppleDirectly() async {
        let settings = makeSettings(provider: .google)
        // A stored Apple "key" satisfies `verifyKey`'s has-key read; the
        // tester's `.apple` case returns without touching the network.
        try? settings.saveKey("test-key-1234", for: .apple)
        let model = makeModel(
            settings: settings,
            transport: constantStatusTransport(200)
        )
        // The launch check resolves nil (stubbed) and would otherwise land
        // mid-test, flipping the freshly stopped `.idle` to `.needsModel`.
        await model.initialModelCheck?.value
        model.phase = .running

        let verified = await model.verifyAndSelectTranslationProvider(.apple)

        #expect(verified.didVerify)
        #expect(settings.selectedProvider == .apple, "the selection applies immediately")
        #expect(model.providerAwaitingDisclosure == nil, "on-device needs no disclosure")

        await stopTranslation(model)
    }

    /// A probe that fails (403 → invalid key, Google's taxonomy) records the
    /// failure result and leaves both the selection and the attached engine
    /// untouched.
    @Test("a failed probe records the failure and leaves the active engine untouched")
    func failedProbeKeepsActiveEngine() async {
        let settings = makeSettings(provider: .openrouter)
        try? settings.saveKey("test-key-1234", for: .google)
        let model = makeModel(
            settings: settings,
            transport: constantStatusTransport(403)
        )
        model.retryTranslation()
        #expect(await pollUntil { model.translationStatus == .ready })
        model.phase = .running

        let verified = await model.verifyAndSelectTranslationProvider(.google)

        #expect(verified == .failed)
        #expect(settings.selectedProvider == .openrouter, "the selection stays put")
        #expect(settings.testResult(for: .google) == .failure("Invalid API key"))
        #expect(model.activeExternalProvider == .openrouter, "the active engine is untouched")

        await stopTranslation(model)
    }

    @Test("verifying a provider without a key records a failure and returns false")
    func verifyingWithoutKeyFails() async {
        let settings = isolatedTranslationSettings(suite: "test.AppModelEngine")
        let model = makeModel(settings: settings)

        let verified = await model.verifyAndSelectTranslationProvider(.deepl)

        #expect(verified == .failed)
        #expect(settings.testResult(for: .deepl) == .failure("Connection failed"))
        #expect(settings.selectedProvider == .apple, "the selection never moved")
    }

    /// Verifying the already-selected provider re-attaches its engine
    /// directly (the key card's re-test path): a latched Apple fallback is
    /// reset and the external engine comes back.
    @Test("verifying the already-selected provider re-attaches its engine and resets the latch")
    func verifyingSelectedProviderReattaches() async {
        let settings = makeSettings(provider: .openrouter)
        let model = makeModel(
            settings: settings,
            transport: failThenSucceedTransport()
        )
        await model.initialModelCheck?.value
        model.retryTranslation()
        #expect(await pollUntil { model.translationStatus == .ready })

        // A failed translation latches the Apple fallback…
        model.translationQueue.enqueue(makeSentence(index: 0, text: "テスト"))
        #expect(await pollUntil { model.translationFallbackActive })
        #expect(model.activeTranslationEngine == .apple)

        // …then a successful probe of the selected provider re-engages it.
        model.phase = .running
        let verified = await model.verifyAndSelectTranslationProvider(.openrouter)

        #expect(verified.didVerify)
        #expect(settings.testResult(for: .openrouter) == .success)
        #expect(!model.translationFallbackActive, "re-engagement re-arms the latch")
        #expect(model.activeTranslationEngine == .external)
        #expect(model.activeExternalProvider == .openrouter)

        await stopTranslation(model)
    }

    // MARK: - Model Save

    /// The key card's Save order is probe → `setModel` → re-attach. The probe
    /// itself must never write the draft, move the selection, or rebuild the
    /// attached engine.
    @Test("a successful model probe records success without persisting or re-attaching")
    func successfulModelProbeDoesNotPersist() async {
        let settings = makeSettings(provider: .google)
        try? settings.saveKey("test-key-1234", for: .openai)
        let model = makeModel(
            settings: settings,
            transport: successfulTranslationTransport()
        )
        await model.initialModelCheck?.value
        model.retryTranslation()
        #expect(await pollUntil { model.translationStatus == .ready })
        model.phase = .running

        let verified = await model.verifyModel("gpt-6-luna", for: .openai)

        #expect(verified)
        #expect(settings.testResult(for: .openai) == .success)
        #expect(settings.model(for: .openai).isEmpty, "the draft is not persisted")
        #expect(settings.selectedProvider == .google, "the selection is unchanged")
        #expect(model.activeTranslationEngine == .external, "the active engine is untouched")
        #expect(model.activeExternalProvider == .google)

        await stopTranslation(model)
    }

    @Test("a failed model probe records the fixed copy and leaves the stored model and engine alone")
    func failedModelProbeLeavesStoredModel() async {
        let settings = makeSettings(provider: .google)
        try? settings.saveKey("test-key-1234", for: .openai)
        let attempts = Mutex(0)
        let transport = HTTPTranslationTransport(timeout: 5) { request in
            attempts.withLock { state in state += 1 }
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil
            )!
            return (Data(), response)
        }
        let model = makeModel(settings: settings, transport: transport)
        await model.initialModelCheck?.value
        model.retryTranslation()
        #expect(await pollUntil { model.translationStatus == .ready })
        model.phase = .running

        let verified = await model.verifyModel("gpt-6-luna", for: .openai)

        #expect(!verified)
        #expect(
            settings.testResult(for: .openai)
                == .failure("The provider rejected the model or its fast-mode settings.")
        )
        #expect(settings.model(for: .openai).isEmpty, "the stored model is unchanged")
        #expect(settings.selectedProvider == .google, "the selection is unchanged")
        #expect(model.activeTranslationEngine == .external, "the active engine is untouched")
        #expect(model.activeExternalProvider == .google)
        #expect(attempts.withLock { count in count } == 2, "the probe tries the compatible fallback once")

        await stopTranslation(model)
    }

    /// A compatible-mode rejection is still a verified model: the downgrade is
    /// cached for the resolved draft, and the caller's commit + re-attach
    /// seeds the new engine with that cache.
    @Test("a compatible-mode model probe caches the downgrade and the UI commit re-attaches")
    func compatibleModelProbeCachesAndReattaches() async throws {
        let settings = makeSettings(provider: .google)
        try? settings.saveKey("test-key-1234", for: .openai)
        let attempts = Mutex(0)
        let bodies = Mutex([Data]())
        let transport = HTTPTranslationTransport(timeout: 5) { request in
            bodies.withLock { log in log.append(request.httpBody ?? Data()) }
            let attempt = attempts.withLock { state -> Int in
                state += 1
                return state
            }
            let status = attempt == 1 ? 400 : 200
            let body = attempt == 1 ? Data() : chatCompletionReplyBody
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil
            )!
            return (body, response)
        }
        let model = makeModel(settings: settings, transport: transport)
        await model.initialModelCheck?.value
        model.retryTranslation()
        #expect(await pollUntil { model.translationStatus == .ready })
        model.phase = .running

        let verified = await model.verifyModel("gpt-6-sol", for: .openai)

        #expect(verified)
        #expect(settings.model(for: .openai).isEmpty, "the probe does not persist the draft")
        #expect(
            settings.compatibleModes[.openai] == "gpt-6-sol",
            "the downgrade is cached under the resolved draft, not the provider default"
        )
        #expect(settings.selectedProvider == .google, "the selection waits for the caller")
        #expect(model.activeExternalProvider == .google, "the probe does not re-attach")
        #expect(attempts.withLock { count in count } == 2)

        // The key card commits the verified draft, then the settings observer
        // re-attaches. The cached downgrade makes the new engine skip the
        // rejected fast-mode fields on its first request.
        settings.setModel("gpt-6-sol", for: .openai)
        settings.select(.openai)
        model.translationProviderDidChange()

        #expect(settings.model(for: .openai) == "gpt-6-sol")
        #expect(model.activeTranslationEngine == .external)
        #expect(model.activeExternalProvider == .openai)

        model.translationQueue.enqueue(makeSentence(index: 0, text: "テスト"))
        #expect(await pollUntil { bodies.withLock { log in log.count == 3 } })

        let body = try #require(bodies.withLock { log in log.last })
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        let object = try #require(json)
        #expect(object["model"] as? String == "gpt-6-sol", "the re-attached engine issued the request")
        #expect(object["reasoning_effort"] == nil, "the cached compatible mode seeds the re-attached engine")

        await stopTranslation(model)
    }

    @Test("verifyModel without a configured key records a failure")
    func verifyModelWithoutKeyFails() async {
        let settings = isolatedTranslationSettings(suite: "test.AppModelEngine")
        let model = makeModel(settings: settings)

        let verified = await model.verifyModel("gpt-6-luna", for: .openai)

        #expect(!verified)
        #expect(settings.testResult(for: .openai) == .failure("Connection failed"))
        #expect(settings.selectedProvider == .apple)
    }

    @Test("verifying a configured LLM provider caches its compatible-mode downgrade")
    func verifyKeyCachesCompatibleMode() async {
        let settings = makeSettings(provider: .openai)
        let attempts = Mutex(0)
        let transport = HTTPTranslationTransport(timeout: 5) { request in
            let attempt = attempts.withLock { state -> Int in
                state += 1
                return state
            }
            let status = attempt == 1 ? 400 : 200
            let body = attempt == 1 ? Data() : chatCompletionReplyBody
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil
            )!
            return (body, response)
        }
        let model = makeModel(settings: settings, transport: transport)
        await model.initialModelCheck?.value

        let verified = await model.verifyAndSelectTranslationProvider(.openai)

        #expect(verified.didVerify)
        #expect(settings.testResult(for: .openai) == .success)
        #expect(settings.isCompatibleMode(for: .openai))
        #expect(attempts.withLock { count in count } == 2)

        await stopTranslation(model)
    }

    /// Thread-safe text sink for result handlers.
    private final class TextRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var log: [String] = []

        func record(_ text: String) {
            lock.withLock { log.append(text) }
        }

        var texts: [String] {
            lock.withLock { log }
        }
    }
}

/// Valid chat-completions reply body used by the success transports.
private let chatCompletionReplyBody = Data(#"{"choices":[{"message":{"content":"hello"}}]}"#.utf8)
