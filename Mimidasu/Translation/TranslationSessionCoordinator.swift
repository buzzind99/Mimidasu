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

/// Outcome of a provider key verification + selection attempt. A superseded
/// probe is not a failure: Settings must not open the key card for a click
/// the user already replaced.
enum ProviderVerificationOutcome: Equatable, Sendable {
    /// The key verified and the selection was applied (or held for the
    /// cloud disclosure).
    case verified

    /// The key probe failed; its test result is recorded.
    case failed

    /// A newer intent or credential change voided the probe; no selection
    /// changed. A credential/sequence-superseded probe recorded nothing,
    /// while an intent-superseded probe may already have recorded its
    /// status-row result (the recording is for the credential, not the
    /// click).
    case superseded

    var didVerify: Bool {
        self == .verified
    }
}

/// The window that raised an archive bulk-run disclosure. The intent is
/// staged and confirmed within that window, so each window presents only its
/// own intents and clears only its own intents on a pane boundary.
enum ArchiveDisclosurePresenter: String, Equatable, Sendable {
    case mainWindow
    case archiveWindow
}

/// The intent held behind the cloud disclosure sheet: completing a provider
/// switch (the live translation engine), a re-translate engine selection, or
/// a bulk archive-translation start. All raise the same sheet with the same
/// semantics — raised on every selection, no persisted acknowledgment.
enum PendingCloudDisclosure: Equatable, Identifiable {
    case providerSwitch(TranslationProvider)
    case retranslateEngine(TranslationProvider)
    /// A bulk run's external provider pick, paired with the run's session,
    /// language, and owning window; unlike the settings intents this is
    /// job-local (never persisted).
    case archiveTranslation(
        TranslationProvider, lang: String, session: Int64, presenter: ArchiveDisclosurePresenter
    )

    var id: String {
        switch self {
        case let .providerSwitch(provider): "switch.\(provider.rawValue)"
        case let .retranslateEngine(provider): "retranslate.\(provider.rawValue)"
        case let .archiveTranslation(provider, lang, session, presenter):
            "archive.\(provider.rawValue).\(lang).\(session).\(presenter.rawValue)"
        }
    }

    var provider: TranslationProvider {
        switch self {
        case let .providerSwitch(provider): provider
        case let .retranslateEngine(provider): provider
        case let .archiveTranslation(provider, _, _, _): provider
        }
    }
}

/// The live translation session: which engine is attached to the queue, the
/// manual retry, the one-way Apple fallback latch, the high-fidelity
/// evidence owned by `AppleTierAvailability`, and the provider-selection
/// machinery (key verification + cloud disclosure). Deep module behind one
/// seam — `activate` / `retry` / `providerDidChange` / `handleStatus` — with
/// the host's phase, entries, and toasts reached through
/// `TranslationSessionPort`.
///
/// Invalidates its sibling `RetranslateCoordinator` whenever the live engine
/// changes via explicit user intent: an Apple activation tears the dedicated
/// lane sessions down (the lane's configs pin the target and engine
/// generation the live switch just retired). The one exception is the
/// latched external→Apple fallback, which deliberately keeps the lane alive
/// — an in-flight lane result still has its deliverer. Status handling,
/// toast reconciliation, the fallback latch, and the config build live in
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

    /// Outcome of the last high-fidelity (Apple Intelligence) probe, owned by
    /// `tierAvailability`: whether the OS reports the strategy installed, and
    /// the ja→target code it was probed for (nil until a probe lands). The
    /// setter lands evidence directly (the test seam).
    var appleHighFidelityProbe: (installed: Bool, targetCode: String?) {
        get { tierAvailability.probe }
        set {
            tierAvailability.land(
                installed: newValue.installed,
                targetCode: newValue.targetCode
            )
        }
    }

    /// The intent held behind the cloud disclosure sheet; nil when no
    /// disclosure is pending. Shared with the re-translate lane, whose
    /// external engine selections are held here too.
    var providerAwaitingDisclosure: PendingCloudDisclosure?

    /// Monotonic token for provider-row clicks. A probe completion whose
    /// generation moved can no longer stage a selection the user superseded.
    private var providerIntentGeneration = 0

    /// Per-provider probe sequence. A completion whose sequence moved was
    /// superseded by a later probe for the same provider and must not write
    /// its test result or compatible-mode evidence over the newer one.
    private var probeSequences: [TranslationProvider: Int] = [:]

    /// The spawned external-engine worker (`queue.run(with:)`). Apple runs
    /// belong to SwiftUI's `.translationTask` instead. Torn down on stop and
    /// re-attached on every activation.
    @ObservationIgnored var translationWorker: Task<Void, Never>?

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
    let tierAvailability: AppleTierAvailability

    init(
        queue: TranslationQueue,
        settings: TranslationSettings,
        transport: HTTPTranslationTransport?,
        tierAvailability: AppleTierAvailability
    ) {
        self.queue = queue
        self.settings = settings
        self.transport = transport
        self.tierAvailability = tierAvailability
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
            // `beginProbe` invalidates any airborne probe via the module's
            // sequence token (the fallback latch can re-enter Apple while a
            // pre-attach probe is still in flight, and that stale landing
            // must not re-mark the engine).
            tierAvailability.beginProbe(for: settings.targetLanguage.code)
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
            tierAvailability.beginProbe(for: settings.targetLanguage.code)
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
        guard SessionPhaseMachine.isLive(sessionPhase) else { return }
        let provider = settings.selectedProvider
        if provider.isExternal, settings.key(for: provider) == nil {
            return
        }
        reengage()
    }

    /// Marks a new provider-row intent and returns the token the caller must
    /// pass back to `verifyAndSelect`. Called synchronously by the row action
    /// so a slow probe started by an earlier click cannot stage a selection
    /// after the user has moved on (Apple included).
    @discardableResult
    func noteProviderIntent() -> Int {
        providerIntentGeneration &+= 1
        return providerIntentGeneration
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
    /// re-clicks once the held intent resolves.
    /// - Parameter intent: the row-click token captured by the caller. Nil
    ///   captures the current token at entry (the Test button, which is not
    ///   a row selection).
    func verifyAndSelect(
        _ provider: TranslationProvider, intent: Int? = nil
    ) async -> ProviderVerificationOutcome {
        let generation = intent ?? providerIntentGeneration
        let verification = await verifyKey(for: provider)
        // Failures are reported regardless of intent generation: callers
        // read the per-provider test-result slot, which belongs to the
        // credential, not the click.
        guard verification == .verified else { return verification }
        // The generation clause covers later intents (row clicks,
        // confirm/decline, selection changes, window events); the hasKey
        // clause is defense-in-depth, because key removal mid-probe is
        // normally caught inside `verifyKey`'s `isCurrent` key-equality
        // check.
        guard generation == providerIntentGeneration,
              settings.hasKey(for: provider)
        else { return .superseded }
        if settings.selectedProvider == provider {
            // Already selected: a re-test, not a switch — re-attach directly.
            providerDidChange()
        } else if provider.isExternal {
            guard providerAwaitingDisclosure == nil else { return .verified }
            providerAwaitingDisclosure = .providerSwitch(provider)
        } else {
            settings.select(provider)
        }
        return .verified
    }

    /// A probe that needed the reasoning-free shape caches it; one that
    /// succeeded in fast mode clears a stale entry naming the same model, so
    /// a provider that starts accepting the fast shape stops paying for the
    /// downgrade on every new engine.
    private func recordProbeOutcome(
        _ downgraded: Bool, provider: TranslationProvider, model: String
    ) {
        if downgraded {
            settings.setCompatibleMode(for: provider, model: model)
        } else {
            settings.clearCompatibleMode(for: provider, ifModelMatches: model)
        }
    }

    /// Identity of one in-flight probe: the provider sequence it belongs to
    /// and the credential it exercised.
    private struct ProbeToken {
        let sequence: Int
        let key: String
    }

    /// Starts a probe for `provider`, superseding any earlier one. The
    /// captured key makes a completion after a key swap stale even when no
    /// newer probe was started for the provider.
    private func beginProbe(
        for provider: TranslationProvider, key: String
    ) -> ProbeToken {
        let sequence = (probeSequences[provider] ?? 0) &+ 1
        probeSequences[provider] = sequence
        return ProbeToken(sequence: sequence, key: key)
    }

    /// Whether a probe still describes the provider's current credential and
    /// has not been superseded by a later probe.
    private func isCurrent(
        _ probe: ProbeToken, for provider: TranslationProvider
    ) -> Bool {
        probeSequences[provider] == probe.sequence
            && settings.key(for: provider) == probe.key
    }

    /// Probes a provider's stored key with its current effective model and
    /// records the outcome for the inline status row (`ConnectionTestResult`).
    /// A reported compatible-mode downgrade is cached for that effective
    /// model so later engine attachments skip the rejected request shape.
    /// A superseded probe records nothing and reports `.superseded`.
    private func verifyKey(
        for provider: TranslationProvider
    ) async -> ProviderVerificationOutcome {
        guard let key = settings.key(for: provider) else {
            settings.setTestResult(.failure("No API key configured"), for: provider)
            return .failed
        }
        let model = settings.effectiveModel(for: provider)
        let probe = beginProbe(for: provider, key: key)
        do {
            let downgraded = try await TranslationConnectionTester.test(
                provider: provider, key: key, model: model,
                target: settings.targetLanguage, transport: transport
            )
            guard isCurrent(probe, for: provider) else { return .superseded }
            recordProbeOutcome(downgraded, provider: provider, model: model)
        } catch {
            guard isCurrent(probe, for: provider) else { return .superseded }
            settings.setTestResult(.failure(error.statusMessage), for: provider)
            return .failed
        }
        settings.setTestResult(.success, for: provider)
        return .verified
    }

    /// Probes a draft model against the provider's stored key and records the
    /// outcome for the inline status row, without persisting the draft,
    /// selecting the provider, or re-attaching an engine. An empty (or
    /// whitespace-only) draft resolves to the provider's catalog default
    /// before probing and before keying the compatible-mode cache. Returns
    /// whether the model verified.
    func verifyModel(_ draft: String, for provider: TranslationProvider) async -> Bool {
        guard let key = settings.key(for: provider) else {
            settings.setTestResult(.failure("No API key configured"), for: provider)
            return false
        }
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = trimmed.isEmpty ? provider.defaultModel : trimmed
        let probe = beginProbe(for: provider, key: key)
        do {
            let downgraded = try await TranslationConnectionTester.test(
                provider: provider, key: key, model: model,
                target: settings.targetLanguage, transport: transport
            )
            guard isCurrent(probe, for: provider) else { return false }
            recordProbeOutcome(downgraded, provider: provider, model: model)
        } catch {
            guard isCurrent(probe, for: provider) else { return false }
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
        // The user resolved the sheet; any probe still airborne belongs to an
        // earlier intent and must not re-stage the same selection.
        providerIntentGeneration &+= 1
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
        case let .archiveTranslation(provider, lang, session, _):
            // Validate the mapping BEFORE clearing the slot: a failed
            // mapping must not close the sheet having applied nothing
            // (defense in depth — archive intents are only built for
            // external providers, where the mapping is total).
            guard let engine = RetranslateEngine(provider: provider) else { return }
            providerAwaitingDisclosure = nil
            host?.beginArchiveTranslation(engine: engine, lang: lang, sessionID: session)
        }
    }

    /// Declines the pending cloud disclosure: nothing is recorded — the
    /// next switch (provider or re-translate engine) raises the disclosure
    /// again.
    func declineDisclosure() {
        // A declined intent is resolved: an older probe still airborne must
        // not raise the same sheet again.
        providerIntentGeneration &+= 1
        providerAwaitingDisclosure = nil
    }

    /// Builds `provider`'s engine, or nil when the provider isn't external
    /// or has no usable key (Apple is served by the `.translationTask` host
    /// in `activate`; the unconfigured edge falls back to Apple with a note
    /// there). The factory resolves the provider's effective model and seeds
    /// the compatible-mode memory; a newly learned downgrade is persisted for
    /// later engines. The target threads into every engine: the LLM prompt
    /// names it, Google/DeepL map it to their wire codes. No retry hook is
    /// wired — the activation path attaches `onRetry` after building; the
    /// re-translate lane leaves it nil.
    func makeExternalEngine(
        for provider: TranslationProvider, target: TargetLanguage
    ) -> (any TranslationEngine)? {
        guard provider.isExternal, let key = settings.key(for: provider) else {
            return nil
        }
        let model = settings.effectiveModel(for: provider)
        let settings = settings
        return TranslationEngineFactory.make(
            provider: provider,
            key: key,
            model: model,
            target: target,
            transport: transport,
            compatibleMode: settings.isCompatibleMode(for: provider),
            onCompatibleModeLearned: { [weak settings] in
                await settings?.recordLiveCompatibleMode(for: provider, model: model, probedKey: key)
            }
        )
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
        tierAvailability.supersedeInFlightProbe()
        translationStatus = .idle
    }
}
