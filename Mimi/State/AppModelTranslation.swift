import Foundation
import Translation

/// Translation-engine management surface of `AppModel` (retry, provider
/// activation, queue-status handling, the latched Apple fallback, and the
/// translation toasts), split out to keep `AppModel.swift` under the 600-line
/// lint gate.
extension AppModel {
    /// Retry after a translation failure (the toast's Retry action). Re-reads
    /// the selected provider (and its key) and re-attaches an engine — so a
    /// manual retry re-attempts the external engine even after the fallback
    /// latched, in case the key or network was fixed. Resets the latch:
    /// every manual retry re-arms the one-way auto-fallback, so a
    /// failure after a retry re-latches onto Apple instead of parking on
    /// `.unavailable` forever.
    func retryTranslation() {
        reengageTranslation()
    }

    /// Re-arms the one-way auto-fallback and re-attaches the selected engine:
    /// resets the latch, dismisses the latched degraded card (its Retry action
    /// would otherwise linger), then activates. Shared by the manual retry and
    /// a live provider change — both are explicit user intent to re-engage.
    private func reengageTranslation() {
        translationFallbackActive = false
        // A latched degraded card carries this action; clear it up front so
        // the re-engaged engine's statuses reconcile from a clean stack.
        toasts.dismiss(key: ToastKey.translationFallback)
        activateTranslation()
    }

    /// Attaches the selected provider's engine to the queue — on session
    /// start, on `retryTranslation`, and (via `translationProviderDidChange`)
    /// on a live provider change. External: build the engine (key read from
    /// the Keychain here) and spawn the worker, parking any attached Apple
    /// host. Apple: invalidate + recreate the config so `.translationTask`
    /// reliably re-fires and hands an `AppleSessionEngine` to the queue.
    func activateTranslation() {
        if let engine = makeExternalEngine() {
            activeTranslationEngine = .external
            activeExternalProvider = translationSettings.selectedProvider
            translationConfig?.invalidate()
            translationWorker?.cancel()
            let queue = translationQueue
            translationWorker = Task {
                await queue.run(with: engine)
            }
        } else {
            // A selected-but-unconfigured external provider (key deleted)
            // degrades to Apple here; the footer and ENGINES card surface
            // the state. Dev builds pin the key store to a no-op
            // (`TranslationSettings.init`), so externals always land here.
            activeTranslationEngine = .apple
            activeExternalProvider = nil
            refreshTranslationConfig()
        }
    }

    /// Applies a provider selection change while a session is live:
    /// re-attaches the selected engine to the queue (pending sentences
    /// replay onto it via the queue's generation token) and resets the
    /// Apple-fallback latch — an explicit change is user intent to
    /// re-engage, same as a manual retry. No-op outside a running session:
    /// session start calls `activateTranslation` with the then-selected
    /// provider anyway. Selecting an unconfigured external provider keeps
    /// the currently attached engine instead of degrading to Apple — it's
    /// a settings edit, not a live switch; the key save's connection test
    /// (`SettingsKeyCard`) activates the new provider once it verifies.
    func translationProviderDidChange() {
        guard phase == .running || phase == .sourceLost else { return }
        let provider = translationSettings.selectedProvider
        if provider.isExternal, translationSettings.key(for: provider) == nil {
            return
        }
        reengageTranslation()
    }

    /// Verifies a provider's stored key (`verifyKey`), then applies the
    /// selection on success — SettingsView's `.onChange(of: selectedProvider)`
    /// re-attaches the engine — unless it's already selected, in which case the
    /// engine re-attaches directly (the key card's re-test path, not a switch,
    /// so no disclosure). Every fresh activation of a cloud provider is held in
    /// `providerAwaitingDisclosure` until the user confirms the off-machine
    /// disclosure (`confirmCloudDisclosure`); there is no persisted
    /// acknowledgment, so the sheet reappears on each switch to an external
    /// provider. Returns whether the key verified.
    func verifyAndSelectTranslationProvider(_ provider: TranslationProvider) async -> Bool {
        guard await verifyKey(for: provider) else { return false }
        if translationSettings.selectedProvider == provider {
            // Already selected: a re-test, not a switch — re-attach directly.
            translationProviderDidChange()
        } else if provider.isExternal {
            providerAwaitingDisclosure = provider
        } else {
            translationSettings.select(provider)
        }
        return true
    }

    /// Probes a provider's stored key and records the outcome for the inline
    /// status row (`ConnectionTestResult`). Returns whether the key verified.
    private func verifyKey(for provider: TranslationProvider) async -> Bool {
        guard let key = translationSettings.key(for: provider) else {
            translationSettings.setTestResult(.failure("No API key configured"), for: provider)
            return false
        }
        do {
            try await TranslationConnectionTester.test(
                provider: provider, key: key, transport: translationTransport
            )
        } catch {
            translationSettings.setTestResult(.failure(error.statusMessage), for: provider)
            return false
        }
        translationSettings.setTestResult(.success, for: provider)
        return true
    }

    /// Confirms the pending cloud disclosure: completes the held selection
    /// (SettingsView's `.onChange` then re-attaches the engine). The sheet
    /// dismisses through the cleared `providerAwaitingDisclosure`.
    func confirmCloudDisclosure() {
        guard let provider = providerAwaitingDisclosure else { return }
        providerAwaitingDisclosure = nil
        translationSettings.select(provider)
    }

    /// Declines the pending cloud disclosure: the selection stays put and
    /// nothing is recorded — the next switch to that provider raises the
    /// disclosure again.
    func declineCloudDisclosure() {
        providerAwaitingDisclosure = nil
    }

    /// Builds the selected external provider's engine, or nil when Apple is
    /// selected (or the external provider has no usable key — the unconfigured
    /// edge falls back to Apple with a note in `activateTranslation`).
    private func makeExternalEngine() -> (any TranslationEngine)? {
        let provider = translationSettings.selectedProvider
        guard provider.isExternal, let key = translationSettings.key(for: provider) else {
            return nil
        }
        // The guard narrowed the domain to the external providers; Apple is
        // served by the `.translationTask` host in `activateTranslation`.
        var engine: any TranslationEngine = if provider == .google {
            GoogleTranslateEngine(apiKey: key, transport: translationTransport)
        } else if provider == .deepl {
            DeepLEngine(apiKey: key, transport: translationTransport)
        } else {
            OpenRouterEngine(
                apiKey: key,
                model: translationSettings.openRouterModel,
                transport: translationTransport
            )
        }
        let queue = translationQueue
        engine.onRetry = { progress in
            Task { @MainActor in queue.noteRetry(progress) }
        }
        return engine
    }

    /// Routes queue status updates to the published state, reconciles the
    /// translation toasts, and drives the latched Apple
    /// fallback. When an external engine exhausts its retries
    /// (`.unavailable`) and the fallback hasn't engaged this session,
    /// invalidate + recreate `translationConfig` — the hidden
    /// `TranslationSessionHost` fires, hands an `AppleSessionEngine` to
    /// `queue.run(with:)`, the generation token retires the dead external
    /// run, and the surviving `pending` replays onto Apple. Internal so tests
    /// can drive the queue's status callback directly.
    func handleTranslationStatus(_ status: TranslationStatus) {
        translationStatus = status
        reconcileTranslationToasts(status)
        guard case let .unavailable(_, severity) = status,
              activeTranslationEngine == .external,
              !translationFallbackActive
        else { return }
        translationFallbackActive = true
        fallBackToApple(severity: severity)
    }

    /// Posts/clears the translation toasts on state change (post on entry,
    /// dismiss on exit): retry progress is transient; degraded/unavailable
    /// are persistent cards carrying Retry. The fallback card stays for the
    /// session while the latch is active — the fresh Apple run's `.ready`
    /// must not clear it (it would flash for under a second); it clears on
    /// manual retry (latch reset) or session stop. `.unavailable` always
    /// dismisses the fallback card, and both clear when the status genuinely
    /// moves on (external engine flowing again).
    private func reconcileTranslationToasts(_ status: TranslationStatus) {
        let latched = translationFallbackActive && activeTranslationEngine == .apple
        switch status {
        case let .retrying(message):
            toasts.post(
                key: ToastKey.translationRetry, style: .yellowAuto,
                title: "Translation retrying", body: message
            )
        case let .degraded(message, _):
            toasts.dismiss(key: ToastKey.translationUnavailable)
            toasts.post(
                key: ToastKey.translationFallback, style: .yellowPersistent,
                title: "Translation degraded", body: message,
                action: retryAction
            )
        case let .unavailable(message, _):
            toasts.dismiss(key: ToastKey.translationFallback)
            toasts.post(
                key: ToastKey.translationUnavailable, style: .redPersistent,
                title: "Translation unavailable", body: message,
                action: retryAction
            )
        case .ready:
            toasts.dismiss(key: ToastKey.translationUnavailable)
            if !latched {
                toasts.dismiss(key: ToastKey.translationFallback)
            }
        case .translating, .idle:
            toasts.dismiss(key: ToastKey.translationUnavailable)
        }
    }

    private var retryAction: ToastCenter.Action {
        ToastCenter.Action(
            label: "Retry", handler: { [weak self] in self?.retryTranslation() }
        )
    }

    /// The one-way latch: once on Apple for the rest of the session (no
    /// periodic re-probing). Publishes `.degraded` so the footer explains the
    /// switch; the fresh Apple run publishes `.ready` over it once flowing.
    private func fallBackToApple(severity: TranslationFailureSeverity) {
        activeTranslationEngine = .apple
        activeExternalProvider = nil
        translationStatus = .degraded("External translation failed — using Apple on-device", severity)
        reconcileTranslationToasts(translationStatus)
        refreshTranslationConfig()
    }

    /// Invalidates the live config (parking any attached Apple host) and
    /// recreates it so `.translationTask` reliably re-fires and hands a fresh
    /// `AppleSessionEngine` to `queue.run(with:)`.
    private func refreshTranslationConfig() {
        translationConfig?.invalidate()
        translationConfig = makeTranslationConfig()
    }

    /// ja→en configuration, built identically for session start and retry so
    /// SwiftUI's `.translationTask` treats both paths the same way.
    private func makeTranslationConfig() -> TranslationSession.Configuration {
        TranslationSession.Configuration(
            source: Locale.Language(identifier: "ja"),
            target: Locale.Language(identifier: "en")
        )
    }
}
