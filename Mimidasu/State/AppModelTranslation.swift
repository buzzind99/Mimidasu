import Foundation
import Translation

// Translation-engine management surface of `AppModel` (retry, provider
// activation, queue-status handling, the latched Apple fallback, and the
// translation toasts), split out to keep `AppModel.swift` under the 600-line
// lint gate.

/// Which translation engine is currently attached to the queue. Derived
/// state (status pill, Settings "Currently using" row) reads this, never the
/// provider picker — a provider change re-attaches the engine via
/// `activateTranslation` before the labels could disagree.
enum ActiveTranslationEngine: Equatable {
    case apple
    case external
}

extension AppModel {
    /// Retry after a translation failure (the toast's Reconnect action).
    /// Re-reads the selected provider (and its key) and re-attaches an
    /// engine — so a manual retry re-attempts the external engine even
    /// after the fallback latched, in case the key or network was fixed.
    /// Resets the latch: every manual retry re-arms the one-way
    /// auto-fallback, so a failure after a retry re-latches onto Apple
    /// instead of parking on `.unavailable` forever.
    func retryTranslation() {
        reengageTranslation()
    }

    /// Re-arms the one-way auto-fallback and re-attaches the selected engine:
    /// resets the latch, dismisses the latched degraded card (its Reconnect
    /// action would otherwise linger), then activates. Shared by the manual
    /// retry and a live provider change — both are explicit user intent to
    /// re-engage.
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
        // Stamp the queue with the current target before any engine
        // attaches: `translateBatch` labels every result with it.
        translationQueue.targetLangCode = translationSettings.targetLanguage.code
        if var engine = makeExternalEngine(for: translationSettings.selectedProvider) {
            // The lane leaves the retry hook nil (a per-row retry-progress
            // toast is noise); only the live queue path reports it.
            let queue = translationQueue
            engine.onRetry = { progress in
                Task { @MainActor in queue.noteRetry(progress) }
            }
            activeTranslationEngine = .external
            activeExternalProvider = translationSettings.selectedProvider
            // Re-probe high fidelity: the pair's availability is a machine
            // fact, not an engine one, and an external-live session is
            // exactly where a stale "unknown" would let a persisted Apple
            // Intelligence re-translate selection stamp fast-model output.
            // `probeHighFidelity` invalidates any airborne probe via the
            // sequence token (the fallback latch can re-enter Apple while a
            // pre-attach probe is still in flight, and that stale landing
            // must not re-mark the engine).
            probeHighFidelity()
            translationConfig?.invalidate()
            translationWorker?.cancel()
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
            // Drop any fast-model retranslate session from a prior session
            // or prior target: the armed config pins the target it was built
            // for. Target changes are restart-only, so within a session the
            // armed config is always current — the reset is for the session
            // boundary (performStop covers the external-provider side, where
            // this branch never runs).
            teardownRetranslateSession()
            refreshTranslationConfig()
            probeHighFidelity()
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
            providerAwaitingDisclosure = .providerSwitch(provider)
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
                provider: provider, key: key, target: translationSettings.targetLanguage,
                transport: translationTransport
            )
        } catch {
            translationSettings.setTestResult(.failure(error.statusMessage), for: provider)
            return false
        }
        translationSettings.setTestResult(.success, for: provider)
        return true
    }

    /// Confirms the cloud disclosure for the sheet the user read. Completes
    /// the held intent — a provider selection (SettingsView's `.onChange`
    /// then re-attaches the engine) or a re-translate engine selection — and
    /// the sheet dismisses through the cleared `providerAwaitingDisclosure`.
    /// Applies only while the slot still equals the presented intent: a slot
    /// clobbered between presentation and the click holds a newer intent
    /// whose own sheet will present, and confirming the stale sheet must not
    /// select the newer provider (a consent mismatch).
    func confirmCloudDisclosure(_ presented: PendingCloudDisclosure) {
        guard providerAwaitingDisclosure == presented else { return }
        providerAwaitingDisclosure = nil
        switch presented {
        case let .providerSwitch(provider):
            translationSettings.select(provider)
        case let .retranslateEngine(provider):
            guard let engine = RetranslateEngine(provider: provider) else { return }
            translationSettings.selectRetranslate(engine)
        }
    }

    /// Declines the pending cloud disclosure: nothing is recorded — the
    /// next switch (provider or re-translate engine) raises the disclosure
    /// again.
    func declineCloudDisclosure() {
        providerAwaitingDisclosure = nil
    }

    /// Builds `provider`'s engine, or nil when the provider isn't external
    /// or has no usable key (Apple is served by the `.translationTask` host
    /// in `activateTranslation`; the unconfigured edge falls back to Apple
    /// with a note there). The selected target language threads into every
    /// engine: the OpenRouter prompt names it, Google/DeepL map it to their
    /// wire codes. No retry hook is wired — the activation path attaches
    /// `onRetry` after building; the re-translate lane leaves it nil.
    /// Internal: the re-translate lane's injectable factory defaults to it.
    func makeExternalEngine(for provider: TranslationProvider) -> (any TranslationEngine)? {
        guard provider.isExternal, let key = translationSettings.key(for: provider) else {
            return nil
        }
        let target = translationSettings.targetLanguage
        return switch provider {
        case .apple:
            nil
        case .google:
            GoogleTranslateEngine(apiKey: key, target: target, transport: translationTransport)
        case .deepl:
            DeepLEngine(apiKey: key, target: target, transport: translationTransport)
        case .openrouter:
            OpenRouterEngine(
                apiKey: key,
                model: translationSettings.openRouterModel,
                target: target,
                transport: translationTransport
            )
        }
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
        guard case let .unavailable(_, severity) = status else { return }
        guard activeTranslationEngine == .external, !translationFallbackActive else {
            // No engine swap follows this failure, so nothing will ever
            // service the backlog: Apple itself failed (a language pack that
            // is absent, a framework error), or this is the fallback's own
            // Apple replay failing. The failed run exited, so its engine is
            // released — a row still wearing its in-flight marker would sit
            // dimmed for the rest of the session, and neither the row button
            // (hidden under the failure card, no worker) nor the retry guard
            // could act. Drop the cue; the way back is the card's Reconnect,
            // which re-attaches an engine and replays the backlog. A lane
            // translation in flight still has its own deliverer, so its
            // marker survives — dropping it would re-open the double-click
            // guard and stack a duplicate lane task.
            pendingRetranslations.formIntersection(lanePendingRetranslations)
            return
        }
        // The one branch a fresh engine follows, so the backlog (and every
        // marker on it) survives: latching Apple replays `pending` onto it.
        translationFallbackActive = true
        fallBackToApple(severity: severity)
    }

    /// Posts/clears the translation toasts on state change (post on entry,
    /// dismiss on exit): retry progress is transient; degraded/unavailable
    /// are persistent cards carrying Reconnect. The fallback card stays for the
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
            label: "Reconnect", handler: { [weak self] in self?.retryTranslation() }
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
        // The fallback is an Apple activation: the external attach cleared
        // the marker, so re-probe for the ENGINES card to report what the
        // fresh config actually requests.
        probeHighFidelity()
    }

    /// Invalidates the live config (parking any attached Apple host) and
    /// recreates it so `.translationTask` reliably re-fires and hands a fresh
    /// `AppleSessionEngine` to `queue.run(with:)`.
    private func refreshTranslationConfig() {
        translationConfig?.invalidate()
        translationConfig = makeTranslationConfig()
    }

    /// ja→target configuration, built identically for session start and retry
    /// so SwiftUI's `.translationTask` treats both paths the same way. The
    /// target reads current settings each time, so a picker change applies at
    /// the next build (session start / retry) — restart-only by design.
    /// On macOS 26.4+ the config prefers the high-fidelity (Apple
    /// Intelligence) strategy for more fluent output; where the device or
    /// language pair can't serve it, the framework silently falls back to the
    /// fast model, so the request degrades to today's behavior.
    private func makeTranslationConfig() -> TranslationSession.Configuration {
        var config = TranslationSession.Configuration(
            source: Locale.Language(identifier: "ja"),
            target: Locale.Language(identifier: translationSettings.targetLanguage.code)
        )
        if #available(macOS 26.4, *) {
            config.preferredStrategy = .highFidelity
        }
        return config
    }

    /// High fidelity for the pair the labels display: the last probe must
    /// have landed installed for exactly the selected target. A marker
    /// probed for an older pair never labels the current one — the target
    /// is restart-only, so a mid-session picker change drops the marker
    /// until the next Apple activation re-probes.
    var appleHighFidelity: Bool {
        appleHighFidelityProbe.installed
            && appleHighFidelityProbe.targetCode == translationSettings.targetLanguage.code
    }

    /// Probes whether the OS can serve the high-fidelity (Apple
    /// Intelligence) strategy for the current ja→target pair and records the
    /// outcome (with the probed code) for the ENGINES card, the Settings
    /// labels, and the re-translate hifi degrade. Fired on every activation
    /// — Apple (session start, retry, provider change, the latched fallback)
    /// or external. The sequence token drops a probe whose activation was
    /// superseded before it landed; the landing does not check the live
    /// engine, because the pair's availability does not depend on one.
    private func probeHighFidelity() {
        appleHighFidelityProbe = (false, nil)
        highFidelitySequence += 1
        let sequence = highFidelitySequence
        let targetCode = translationSettings.targetLanguage.code
        let probe = highFidelityProbe
        Task { [weak self] in
            let available = await probe(targetCode)
            guard let self,
                  sequence == highFidelitySequence
            else { return }
            appleHighFidelityProbe = (available, targetCode)
        }
    }

    /// The real probe: on macOS 26.4+ asks `LanguageAvailability` whether
    /// the high-fidelity (Apple Intelligence) strategy is installed for
    /// ja→target — only `.installed` counts, since a merely downloadable
    /// pair still runs the fast model. Older systems report false.
    nonisolated static func checkHighFidelityAvailability(targetCode: String) async -> Bool {
        guard #available(macOS 26.4, *) else { return false }
        let availability = LanguageAvailability(preferredStrategy: .highFidelity)
        let status = await availability.status(
            from: Locale.Language(identifier: "ja"),
            to: Locale.Language(identifier: targetCode)
        )
        return status == .installed
    }

    /// Internal (not private) so tests can exercise known/unknown indexes.
    /// Routing is the entry's decision, not the caller's: it swaps the
    /// row's same-language translation in place and appends only a genuinely
    /// new language. So a repeat, an engine-swap replay, and a manual retry
    /// all land as the fresh text — none of them can grow an `" / "` pileup.
    /// Returns whether the row was still present; a false return means the
    /// transcript no longer contains the index (the callers that must not
    /// act on a vanished row — the lane's cache seeding — check it).
    @discardableResult
    func applyTranslation(index: Int, translation: SentenceTranslation) -> Bool {
        // Cleared before the row lookup: a result whose row is gone (the
        // transcript cleared underneath it) must still retire its marker,
        // or the row stays dimmed with its retry button dead.
        pendingRetranslations.remove(index)
        lanePendingRetranslations.remove(index)
        guard let at = entryPositionBySentence[index] else { return false }
        entries[at].replaceTranslation(translation)
        return true
    }
}
