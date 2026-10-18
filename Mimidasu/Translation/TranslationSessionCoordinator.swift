import Foundation
import Observation
import Translation

/// Which translation engine is currently attached to the queue. Derived
/// state (status pill, Settings "Currently using" row) reads this, never the
/// provider picker — a provider change re-attaches the engine via
/// `activate()` before the labels could disagree.
enum ActiveTranslationEngine: Equatable {
    case apple
    case external
}

/// The intent held behind the cloud disclosure sheet: completing a provider
/// switch (the live translation engine), a re-translate engine selection, or
/// a bulk archive-translation start. All raise the same sheet with the same
/// semantics — raised on every selection, no persisted acknowledgment.
enum PendingCloudDisclosure: Equatable, Identifiable {
    case providerSwitch(TranslationProvider)
    case retranslateEngine(TranslationProvider)
    /// A bulk run's external provider pick, paired with the run's language;
    /// unlike the settings intents this is job-local (never persisted).
    case archiveTranslation(TranslationProvider, lang: String)

    var id: String {
        switch self {
        case let .providerSwitch(provider): "switch.\(provider.rawValue)"
        case let .retranslateEngine(provider): "retranslate.\(provider.rawValue)"
        case let .archiveTranslation(provider, lang): "archive.\(provider.rawValue).\(lang)"
        }
    }

    var provider: TranslationProvider {
        switch self {
        case let .providerSwitch(provider): provider
        case let .retranslateEngine(provider): provider
        case let .archiveTranslation(provider, _): provider
        }
    }
}

/// The live translation session: which engine is attached to the queue, the
/// manual retry, the one-way Apple fallback latch, the high-fidelity probe,
/// and the provider-selection machinery (key verification + cloud
/// disclosure). Deep module behind one seam — `activate` / `retry` /
/// `providerDidChange` / `handleStatus` — with the host's phase, entries,
/// and toasts reached through `TranslationSessionPort`.
///
/// Invalidates its sibling `RetranslateCoordinator` whenever the live engine
/// changes via explicit user intent: an Apple activation tears the dedicated
/// lane sessions down (the lane's configs pin the target and engine
/// generation the live switch just retired). The one exception is the
/// latched external→Apple fallback, which deliberately keeps the lane alive
/// — an in-flight lane result still has its deliverer. Status handling,
/// toast reconciliation, the fallback latch, the config build, and the
/// probe live in
/// `TranslationSessionCoordinator+Status.swift`.
@Observable
@MainActor
final class TranslationSessionCoordinator {
    /// The engine currently attached to the queue — Apple's via the hidden
    /// `.translationTask` host, an external one via `translationWorker`.
    var activeTranslationEngine: ActiveTranslationEngine = .apple

    /// Which external provider is attached while `activeTranslationEngine`
    /// is `.external` (nil on the Apple paths). Labels read this, never the
    /// picker, so the ENGINES card and "Currently using" row can't describe
    /// a provider that isn't actually attached.
    var activeExternalProvider: TranslationProvider?

    /// True once this session has latched onto Apple on-device after an
    /// external engine failed (the Settings "Currently using" row surfaces
    /// it). Reset by every manual retry and every session begin.
    var translationFallbackActive = false

    /// Drives the queue-status surface: the sidebar pill, the footer, and
    /// the failure cards all read this through the app model.
    var translationStatus: TranslationStatus = .idle

    /// Drives SwiftUI's `.translationTask` (session acquisition + pack
    /// prompt).
    var translationConfig: TranslationSession.Configuration?

    /// Outcome of the last high-fidelity (Apple Intelligence) probe: whether
    /// the OS reports the strategy installed, and the ja→target code it was
    /// probed for (nil until a probe lands).
    var appleHighFidelityProbe: (installed: Bool, targetCode: String?) = (false, nil)

    /// The intent held behind the cloud disclosure sheet; nil when no
    /// disclosure is pending. Shared with the re-translate lane, whose
    /// external engine selections are held here too.
    var providerAwaitingDisclosure: PendingCloudDisclosure?

    /// The spawned external-engine worker (`queue.run(with:)`). Apple runs
    /// belong to SwiftUI's `.translationTask` instead. Torn down on stop and
    /// re-attached on every activation.
    @ObservationIgnored var translationWorker: Task<Void, Never>?

    /// Monotonic token ruling which high-fidelity probe may land: every
    /// engine attach and teardown bumps it, so a probe superseded before it
    /// finished is dropped.
    @ObservationIgnored var highFidelitySequence = 0

    /// The re-translate lane — the sibling coordinator invalidated whenever
    /// the live engine changes via explicit user intent (an Apple activation
    /// tears the dedicated lane sessions down; the latched fallback leaves
    /// the lane intact; a terminal queue failure drops queue-owned markers).
    /// Weak: the app model owns both coordinators. Always wired in
    /// `AppModel.init` — the optional chaining below asserts that.
    @ObservationIgnored weak var retranslate: RetranslateCoordinator?

    /// The app-model port (phase, toasts, row landing). Weak: the app model
    /// owns this coordinator. Nil-host means no session can be live
    /// (`sessionPhase` reads `.idle`) and toast posts are skipped while
    /// published state still updates.
    @ObservationIgnored weak var host: (any TranslationSessionPort)?

    let queue: TranslationQueue
    let settings: TranslationSettings
    @ObservationIgnored let transport: HTTPTranslationTransport?
    @ObservationIgnored let probe: @Sendable (String) async -> Bool

    init(
        queue: TranslationQueue,
        settings: TranslationSettings,
        transport: HTTPTranslationTransport?,
        probe: @escaping @Sendable (String) async -> Bool
    ) {
        self.queue = queue
        self.settings = settings
        self.transport = transport
        self.probe = probe
    }

    /// The live session phase from the host; `.idle` when the host is gone
    /// (no session can be live without an app model).
    var sessionPhase: SessionPhase {
        host?.phase ?? .idle
    }

    /// The host's toast stack, or nil when the host is gone.
    var toasts: ToastCenter? {
        host?.toasts
    }
}

// MARK: - Attach / retry

extension TranslationSessionCoordinator {
    /// Retry after a translation failure (the toast's Reconnect action).
    /// Re-reads the selected provider (and its key) and re-attaches an
    /// engine — so a manual retry re-attempts the external engine even
    /// after the fallback latched, in case the key or network was fixed.
    /// Resets the latch: every manual retry re-arms the one-way
    /// auto-fallback, so a failure after a retry re-latches onto Apple
    /// instead of parking on `.unavailable` forever.
    func retry() {
        reengage()
    }

    /// Re-arms the one-way auto-fallback and re-attaches the selected engine:
    /// resets the latch, dismisses the latched degraded card (its Reconnect
    /// action would otherwise linger), then activates. Shared by the manual
    /// retry and a live provider change — both are explicit user intent to
    /// re-engage.
    private func reengage() {
        translationFallbackActive = false
        // A latched degraded card carries this action; clear it up front so
        // the re-engaged engine's statuses reconcile from a clean stack.
        toasts?.dismiss(key: ToastKey.translationFallback)
        activate()
    }

    /// Attaches the selected provider's engine to the queue — on session
    /// start, on `retry`, and (via `providerDidChange`) on a live provider
    /// change. External: build the engine (key read from the Keychain here)
    /// and spawn the worker, parking any attached Apple host. Apple:
    /// invalidate + recreate the config so `.translationTask` reliably
    /// re-fires and hands an `AppleSessionEngine` to the queue.
    func activate() {
        // Stamp the queue with the current target before any engine
        // attaches: `translateBatch` labels every result with it.
        queue.targetLangCode = settings.targetLanguage.code
        if var engine = makeExternalEngine(for: settings.selectedProvider) {
            // The lane leaves the retry hook nil (a per-row retry-progress
            // toast is noise); only the live queue path reports it.
            let queue = queue
            engine.onRetry = { progress in
                Task { @MainActor in queue.noteRetry(progress) }
            }
            activeTranslationEngine = .external
            activeExternalProvider = settings.selectedProvider
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
            // boundary (`RetranslateCoordinator.sessionDidEnd`, reached via
            // `AppModel.performStop`, covers the external-provider side,
            // where this branch never runs).
            assert(retranslate != nil, "the retranslate sibling is always wired by AppModel.init")
            retranslate?.teardown()
            refreshConfig()
            probeHighFidelity()
        }
    }

    /// Applies a provider selection change while a session is live:
    /// re-attaches the selected engine to the queue (pending sentences
    /// replay onto it via the queue's generation token) and resets the
    /// Apple-fallback latch — an explicit change is user intent to
    /// re-engage, same as a manual retry. No-op outside a running session:
    /// session start calls `activate` with the then-selected provider
    /// anyway. Selecting an unconfigured external provider keeps the
    /// currently attached engine instead of degrading to Apple — it's a
    /// settings edit, not a live switch; the key save's connection test
    /// (`SettingsKeyCard`) activates the new provider once it verifies.
    func providerDidChange() {
        // Nil-host reads `.idle` through `sessionPhase`, so an unwired
        // coordinator no-ops here by contract.
        guard sessionPhase == .running || sessionPhase == .sourceLost || sessionPhase == .paused
        else { return }
        let provider = settings.selectedProvider
        if provider.isExternal, settings.key(for: provider) == nil {
            return
        }
        reengage()
    }

    /// Verifies a provider's stored key (`verifyKey`), then applies the
    /// selection on success — SettingsView's `.onChange(of: selectedProvider)`
    /// re-attaches the engine — unless it's already selected, in which case the
    /// engine re-attaches directly (the key card's re-test path, not a switch,
    /// so no disclosure). Every fresh activation of a cloud provider is held in
    /// `providerAwaitingDisclosure` until the user confirms the off-machine
    /// disclosure (`confirmDisclosure`); there is no persisted
    /// acknowledgment, so the sheet reappears on each switch to an external
    /// provider. A switch is not raised while another intent is already
    /// held: the raise would clobber it and swap the presented sheet's
    /// content mid-flight, so the switch is simply not offered — the user
    /// re-clicks once the held intent resolves. Returns whether the key
    /// verified.
    func verifyAndSelect(_ provider: TranslationProvider) async -> Bool {
        guard await verifyKey(for: provider) else { return false }
        if settings.selectedProvider == provider {
            // Already selected: a re-test, not a switch — re-attach directly.
            providerDidChange()
        } else if provider.isExternal {
            guard providerAwaitingDisclosure == nil else { return true }
            providerAwaitingDisclosure = .providerSwitch(provider)
        } else {
            settings.select(provider)
        }
        return true
    }

    /// Probes a provider's stored key and records the outcome for the inline
    /// status row (`ConnectionTestResult`). Returns whether the key verified.
    private func verifyKey(for provider: TranslationProvider) async -> Bool {
        guard let key = settings.key(for: provider) else {
            settings.setTestResult(.failure("No API key configured"), for: provider)
            return false
        }
        do {
            try await TranslationConnectionTester.test(
                provider: provider, key: key, target: settings.targetLanguage,
                transport: transport
            )
        } catch {
            settings.setTestResult(.failure(error.statusMessage), for: provider)
            return false
        }
        settings.setTestResult(.success, for: provider)
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
    func confirmDisclosure(_ presented: PendingCloudDisclosure) {
        guard providerAwaitingDisclosure == presented else { return }
        switch presented {
        case let .providerSwitch(provider):
            providerAwaitingDisclosure = nil
            settings.select(provider)
        case let .retranslateEngine(provider):
            // Validate the mapping BEFORE clearing the slot: a failed
            // mapping must not close the sheet having applied nothing
            // (defense in depth — retranslate intents are only built for
            // external providers, where the mapping is total).
            guard let engine = RetranslateEngine(provider: provider) else { return }
            providerAwaitingDisclosure = nil
            settings.selectRetranslate(engine)
        case let .archiveTranslation(provider, lang):
            // Validate the mapping BEFORE clearing the slot: a failed
            // mapping must not close the sheet having applied nothing
            // (defense in depth — archive intents are only built for
            // external providers, where the mapping is total).
            guard let engine = RetranslateEngine(provider: provider) else { return }
            providerAwaitingDisclosure = nil
            host?.beginArchiveTranslation(engine: engine, lang: lang)
        }
    }

    /// Declines the pending cloud disclosure: nothing is recorded — the
    /// next switch (provider or re-translate engine) raises the disclosure
    /// again.
    func declineDisclosure() {
        providerAwaitingDisclosure = nil
    }

    /// Builds `provider`'s engine, or nil when the provider isn't external
    /// or has no usable key (Apple is served by the `.translationTask` host
    /// in `activate`; the unconfigured edge falls back to Apple with a note
    /// there). The target threads into every engine: the OpenRouter prompt
    /// names it, Google/DeepL map it to their wire codes. No retry hook is
    /// wired — the activation path attaches `onRetry` after building; the
    /// re-translate lane leaves it nil.
    func makeExternalEngine(
        for provider: TranslationProvider, target: TargetLanguage
    ) -> (any TranslationEngine)? {
        guard provider.isExternal, let key = settings.key(for: provider) else {
            return nil
        }
        return switch provider {
        case .apple:
            nil
        case .google:
            GoogleTranslateEngine(apiKey: key, target: target, transport: transport)
        case .deepl:
            DeepLEngine(apiKey: key, target: target, transport: transport)
        case .openrouter:
            OpenRouterEngine(
                apiKey: key,
                model: settings.openRouterModel,
                target: target,
                transport: transport
            )
        }
    }

    /// The settings-target spelling, for the activation path.
    func makeExternalEngine(for provider: TranslationProvider) -> (any TranslationEngine)? {
        makeExternalEngine(for: provider, target: settings.targetLanguage)
    }
}

// MARK: - Session lifecycle

extension TranslationSessionCoordinator {
    /// Session boundary: a fresh session re-attempts the configured
    /// provider from scratch — the fallback latch is per session.
    func sessionWillBegin() {
        translationFallbackActive = false
    }

    /// Stop/teardown: parks the external worker (Apple runs are owned by
    /// SwiftUI and stay parked), retires the queue's session boundary,
    /// supersedes any airborne high-fidelity probe — a landing must not mark
    /// a session that no longer exists — and resets the published status.
    func sessionDidEnd() {
        translationWorker?.cancel()
        translationWorker = nil
        // Session boundary for the queue, not just a run boundary: a batch
        // still airborne across the stop has no session left to land in, so
        // its results and status are retired by the epoch (see
        // `TranslationQueue`) — a late failure must not repost a failure
        // card or re-latch the fallback over the cleared stack, and a
        // backlog the drain timed out on is dropped rather than carried.
        queue.resetForNewSession()
        highFidelitySequence += 1
        translationStatus = .idle
    }
}
