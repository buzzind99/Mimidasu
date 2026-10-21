import Foundation
import Translation

// Status routing, toast reconciliation, the latched Apple fallback, and the
// config build of `TranslationSessionCoordinator` — split from the main file
// to keep it under the lint file gate.

extension TranslationSessionCoordinator {
    /// Routes queue status updates to the published state, reconciles the
    /// translation toasts, and drives the latched Apple
    /// fallback. When an external engine exhausts its retries
    /// (`.unavailable`) and the fallback hasn't engaged this session,
    /// invalidate + recreate `translationConfig` — the hidden
    /// `TranslationSessionHost` fires, hands an `AppleSessionEngine` to
    /// `queue.run(with:)`, the generation token retires the dead external
    /// run, and the surviving `pending` replays onto Apple. Internal so
    /// tests can drive the queue's status callback directly.
    func handleStatus(_ status: TranslationStatus) {
        translationStatus = status
        reconcileToasts(status)
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
            // guard and stack a duplicate lane task. Nil-host skips only the
            // toast posts below; `translationStatus` above already updated.
            assert(retranslate != nil, "the retranslate sibling is always wired by AppModel.init")
            retranslate?.dropQueueOwnedMarkers()
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
    private func reconcileToasts(_ status: TranslationStatus) {
        let latched = translationFallbackActive && activeTranslationEngine == .apple
        switch status {
        case let .retrying(message):
            toasts?.post(
                key: ToastKey.translationRetry, style: .yellowAuto,
                title: "Translation retrying", body: message
            )
        case let .degraded(message, _):
            toasts?.dismiss(key: ToastKey.translationUnavailable)
            toasts?.post(
                key: ToastKey.translationFallback, style: .yellowPersistent,
                title: "Translation degraded", body: message,
                action: retryAction
            )
        case let .unavailable(message, _):
            toasts?.dismiss(key: ToastKey.translationFallback)
            toasts?.post(
                key: ToastKey.translationUnavailable, style: .redPersistent,
                title: "Translation unavailable", body: message,
                action: retryAction
            )
        case .ready:
            toasts?.dismiss(key: ToastKey.translationUnavailable)
            if !latched {
                toasts?.dismiss(key: ToastKey.translationFallback)
            }
        case .translating, .idle:
            toasts?.dismiss(key: ToastKey.translationUnavailable)
        }
    }

    private var retryAction: ToastCenter.Action {
        ToastCenter.Action(
            label: "Reconnect", handler: { [weak self] in self?.retry() }
        )
    }

    /// The one-way latch: once on Apple for the rest of the session (no
    /// periodic re-probing). Publishes `.degraded` so the footer explains the
    /// switch; the fresh Apple run publishes `.ready` over it once flowing.
    private func fallBackToApple(severity: TranslationFailureSeverity) {
        activeTranslationEngine = .apple
        activeExternalProvider = nil
        // The body is prose, not a tier name: it explains the switch to the
        // user, so it keeps its own wording rather than borrowing the
        // canonical tier vocabulary.
        translationStatus = .degraded("External translation failed — using Apple on-device", severity)
        reconcileToasts(translationStatus)
        refreshConfig()
        // Unlike an explicit Apple activation, this re-fires only the live
        // Apple host — the lane's dedicated sessions are deliberately left
        // alone, so an in-flight lane result keeps its deliverer. The
        // external attach cleared the probe marker, so re-probe for the
        // ENGINES card to report what the fresh config actually requests.
        tierAvailability.beginProbe(for: settings.targetLanguage.code)
    }

    /// Invalidates the live config (parking any attached Apple host) and
    /// recreates it so `.translationTask` reliably re-fires and hands a fresh
    /// `AppleSessionEngine` to `queue.run(with:)`. Internal (not private):
    /// `activate` in `TranslationSessionCoordinator.swift` re-fires the
    /// Apple host through this.
    func refreshConfig() {
        translationConfig?.invalidate()
        translationConfig = makeConfig()
    }

    /// ja→target configuration, built identically for session start and retry
    /// so SwiftUI's `.translationTask` treats both paths the same way. The
    /// target reads current settings each time, so a picker change applies at
    /// the next build (session start / retry) — restart-only by design.
    /// Where the strategy API exists the config prefers the high-fidelity
    /// (Apple Intelligence) strategy for more fluent output; where the device
    /// or language pair can't serve it, the framework silently falls back to
    /// the fast model, so the request degrades to today's behavior.
    private func makeConfig() -> TranslationSession.Configuration {
        var config = TranslationSession.Configuration(
            source: Locale.Language(identifier: "ja"),
            target: Locale.Language(identifier: settings.targetLanguage.code)
        )
        tierAvailability.applyPreferredStrategy(to: &config, highFidelity: true)
        return config
    }

    /// High fidelity for the pair the labels display: the strategy API
    /// exists, the last probe landed installed for exactly the selected
    /// target. A marker probed for an older pair never labels the current
    /// one — the target is restart-only, so a mid-session picker change drops
    /// the marker until the next Apple activation re-probes.
    var appleHighFidelity: Bool {
        tierAvailability.available(for: settings.targetLanguage.code)
    }
}
