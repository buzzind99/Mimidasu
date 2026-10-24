import Foundation
import Observation
import Translation

/// The re-translate lane: the transcript row's retry button re-running one
/// sentence through a chosen engine. Deep module behind one seam —
/// `retranslateSentence` / `selectRetranslateEngine` — owning the lane's
/// marker sets, epoch clock, dedicated Apple sessions, and the serialized
/// one-at-a-time runner. Engine identity and the high-fidelity probe resolve
/// through `AppleTierAvailability` — the pair-scoped probe evidence shared
/// with the sibling `TranslationSessionCoordinator` (the live session);
/// phase, entries, and toasts come from the host through
/// `TranslationSessionPort`.
///
/// File split: identity + selection + routing live here;
/// `RetranslateCoordinator+Lane.swift` holds the runner;
/// `RetranslateCoordinator+Sessions.swift` holds the dedicated-session
/// arming/teardown lifecycle.
@Observable
@MainActor
final class RetranslateCoordinator {
    /// Sentence indexes with a manual re-translation in flight (the
    /// transcript row's hover button). Membership is a dim cue and a
    /// double-click guard only — `applyTranslation` routes on the row's
    /// languages, so nothing about a result's *correctness* depends on it.
    /// Cleared by the landing result, by any lane exit that will not
    /// deliver (`retireLaneMarker`), by the queue's terminal `.unavailable`
    /// that engages no replay (queue-owned markers only), by session stop,
    /// and by the next session's begin.
    var pendingRetranslations: Set<Int> = []

    /// The lane-owned subset of `pendingRetranslations`: markers the
    /// re-translate lane itself inserted. The queue engine's terminal
    /// `.unavailable` clear drops queue-owned markers only — a lane
    /// translation in flight still has its deliverer, and losing the marker
    /// would re-open the double-click guard.
    var lanePendingRetranslations: Set<Int> = []

    /// Config for the dedicated low-latency (fast model) re-translate
    /// session, armed by the first Apple-fast retry.
    var retranslateConfig: TranslationSession.Configuration?

    /// The target code `retranslateConfig` was built for. Arming rebuilds a
    /// config whose target no longer matches (an armed config pins its
    /// target); nil while the config is unarmed.
    @ObservationIgnored var retranslateConfigTarget: String?

    /// The fast-model session handed out by the second `.translationTask`
    /// host, stored as the queue-side engine adapter.
    var retranslateSessionEngine: (any TranslationEngine)?

    /// Config for the dedicated high-fidelity (Apple Intelligence)
    /// re-translate session, armed by the first Apple-Intelligence retry.
    var retranslateHifiConfig: TranslationSession.Configuration?

    /// The target code `retranslateHifiConfig` was built for (see
    /// `retranslateConfigTarget`).
    @ObservationIgnored var retranslateHifiConfigTarget: String?

    /// The high-fidelity session handed out by the third `.translationTask`
    /// host, stored as the queue-side engine adapter.
    var retranslateHifiSessionEngine: (any TranslationEngine)?

    /// Serialized one-at-a-time runner for alternate-engine retries: each
    /// new lane task awaits the previous one, so a session-backed engine
    /// never sees concurrent `translate` calls.
    @ObservationIgnored var retranslateLaneTask: Task<Void, Never>?

    /// True while the newest lane-chain link has not finished. The chain is
    /// serial (each link awaits the previous), so the newest link's
    /// completion is the whole chain's. The bulk job's resolution waits on
    /// this instead of a captured task, so a close/swap releases the job's
    /// claim without awaiting a link the teardown already made
    /// undeliverable.
    @ObservationIgnored private(set) var laneChainIdle = true

    /// Serial of the newest lane-chain link (see `laneChainIdle`): an older
    /// link finishing after a newer one exists must not idle the chain.
    @ObservationIgnored private var laneChainSerial = 0

    /// Registers a new lane-chain link and returns its serial. The chain is
    /// marked busy before the link task exists, so a wait never observes an
    /// idle chain mid-registration.
    func beginLaneChainLink() -> Int {
        laneChainSerial += 1
        laneChainIdle = false
        return laneChainSerial
    }

    /// Marks the chain idle when `serial` is still the newest link's.
    func endLaneChainLink(serial: Int) {
        guard serial == laneChainSerial else { return }
        laneChainIdle = true
    }

    /// Session boundary token for the re-translate lane, in the same spirit
    /// as `TranslationQueue`'s session epoch: bumped in
    /// `sessionWillBegin`, `sessionDidEnd`, and `teardown` (a mid-session
    /// Apple activation is a lane-generation change, not a session one),
    /// captured when a retry is clicked, and compared after the flight. A
    /// lane task that outlives its session — stop cancels only the newest
    /// chained link, so earlier ones run to completion — would otherwise
    /// pass the phase guard (the next session is `.running` again) and
    /// write the *previous* session's translation onto an unrelated row,
    /// since `Sentence.index` restarts at 0.
    @ObservationIgnored var retranslateSessionEpoch = 0

    /// How long the re-translate lane waits for an arming dedicated Apple
    /// session before giving up on a click. Injectable so the timeout test
    /// can exercise the real path in milliseconds instead of faking it with
    /// a cancellation, which is a different outcome.
    @ObservationIgnored var laneArmTimeout = Duration.seconds(5)

    /// How long an Apple-kind re-translate lane waits for the activation
    /// probe to land before routing on it (both Apple kinds defer — the
    /// landing decides duplicate-vs-alternate): while the probe is unlanded
    /// the live identity is unknown and the pair's hifi availability
    /// unproven, so the lane defers. The probe is a fast async check; the
    /// bound only catches pathological cases. Injectable for tests.
    @ObservationIgnored var probeSettleTimeout = Duration.seconds(3)

    /// Injectable factory for the lane's external engines (tests); nil
    /// drives the live session's `makeExternalEngine(for:target:)`. The
    /// target is the click-time lane target, so a build for a foreign
    /// archive target is never served to a settings-target flight.
    @ObservationIgnored var retranslateEngineFactory:
        (@Sendable (TranslationProvider, TargetLanguage) -> (any TranslationEngine)?)?

    /// The app-model port (phase, toasts, row landing). Weak: the app model
    /// owns this coordinator.
    @ObservationIgnored weak var host: (any TranslationSessionPort)?

    /// The live session — engine identity and probe source. Weak: the
    /// app model owns both coordinators, so a lane outliving the live
    /// session degrades to unknown-identity instead of trapping.
    @ObservationIgnored weak var live: TranslationSessionCoordinator?

    let queue: TranslationQueue
    let settings: TranslationSettings
    let tierAvailability: AppleTierAvailability

    init(
        live: TranslationSessionCoordinator,
        queue: TranslationQueue,
        settings: TranslationSettings,
        tierAvailability: AppleTierAvailability
    ) {
        self.live = live
        self.queue = queue
        self.settings = settings
        self.tierAvailability = tierAvailability
    }

    /// The live session phase from the host; `.idle` when the host is gone
    /// (no retry can be clicked without an app model).
    var sessionPhase: SessionPhase {
        host?.phase ?? .idle
    }

    /// The host's toast stack, or nil when the host is gone.
    var toasts: ToastCenter? {
        host?.toasts
    }

    /// Whether an archived session is open in the transcript pane — the
    /// lane's second gate and its route switch: with no live session, every
    /// retry runs through a dedicated alternate engine and lands back into
    /// the store instead of the queue.
    var archiveOpen: Bool {
        host?.archiveSessionID != nil
    }

    /// The lane's target language: the opened archive's viewing language
    /// when there is one, else the settings target. The viewing language is
    /// the archive's stored target by default (switching it is view-only);
    /// an archive's codes resolve through the language table (unknown codes
    /// fall back to English, mirroring the persisted-selection rule).
    var laneTargetLanguage: TargetLanguage {
        guard archiveOpen, let code = host?.archiveViewingCode else {
            return settings.targetLanguage
        }
        return TargetLanguage(code: code)
    }
}

// MARK: - Engine identity

extension RetranslateCoordinator {
    /// Engine identity of the live caption path — the row marker's
    /// comparison target. Externals map from the attached provider; the
    /// Apple branch asks `tierAvailability.available(for:)` — the pair-scoped
    /// installed evidence. Below the strategy API the fast model is the only
    /// model. Until a probe lands, every Apple activation holds the evidence
    /// at `(false, nil)`, so the Apple branch reads `.appleFast`
    /// *provisionally* — the marker rule compensates by not comparing against
    /// a provisional identity, and `liveSessionRunsKind` refuses the
    /// provisional read outright so routing never acts on it.
    var activeEngineKind: TranslationEngineKind {
        guard let live else { return .appleFast }
        if live.activeTranslationEngine == .external, let provider = live.activeExternalProvider {
            // The attached provider is external by construction; only Apple
            // maps to nil.
            return TranslationEngineKind(provider: provider) ?? .appleFast
        }
        if tierAvailability.available(for: settings.targetLanguage.code) {
            return .appleHighFidelity
        }
        return .appleFast
    }

    /// True when the live Apple session runs the given Apple kind. Above the
    /// strategy API the identity is UNKNOWN until the activation probe lands
    /// (every activation resets the evidence to `(false, nil)`), and an
    /// unlanded identity must not route: a provisional `.appleFast` read
    /// would send a fast retry to a live high-fidelity session (unstamped
    /// wrong-engine text) and a high-fidelity retry to a duplicate of the
    /// live session — the byte-identical no-op that reads as a broken
    /// button. Callers treat `false` as "not provably the same engine": the
    /// click defers to the dedicated session and the lane re-routes on the
    /// landing. Below the strategy API the identity never depends on the
    /// probe.
    func liveSessionRunsKind(_ kind: TranslationEngineKind) -> Bool {
        guard let live, live.activeTranslationEngine == .apple else { return false }
        guard tierAvailability.identityKnown(for: settings.targetLanguage.code) else {
            return false
        }
        return activeEngineKind == kind
    }

    /// High fidelity is *known* unavailable when the last probe landed for
    /// `targetCode` and reported it not installed. Deliberately narrower
    /// than "cannot serve": a probe that never landed or one run for a
    /// different target is not evidence of unavailability. Delegates to
    /// `tierAvailability.knownUnavailable(for:)`, which owns the pair-scoped
    /// evidence — a foreign archive target compares against its own code,
    /// never the settings pair.
    func highFidelityKnownUnavailable(for targetCode: String) -> Bool {
        tierAvailability.knownUnavailable(for: targetCode)
    }

    /// The settings-pair spelling of `highFidelityKnownUnavailable(for:)`.
    var highFidelityKnownUnavailable: Bool {
        highFidelityKnownUnavailable(for: settings.targetLanguage.code)
    }

    /// The Apple tier `engine` can actually deliver for `targetCode`, which
    /// is not always the selected one. `.appleHighFidelity` names a strategy
    /// the OS may not be able to serve: below the strategy API there is no
    /// strategy selection at all, and where the ja→target pair is not
    /// `.installed` the dedicated config still requests high fidelity and the
    /// framework silently falls back to the fast model (the same caveat
    /// `makeConfig` documents). Requesting it anyway would return text
    /// byte-identical to a fast session while stamping the row
    /// `.appleHighFidelity` — a "· via Apple Intelligence" marker over
    /// fast-model output. So a *known*-unavailable high-fidelity route
    /// degrades to the fast model, which is a genuine alternate. Delegates to
    /// `tierAvailability.effectiveTier(_:targetCode:)`; non-Apple selections
    /// pass through untouched.
    ///
    /// Accepted caveat: a foreign target (an archive whose viewing language
    /// differs from the settings target) has no probe evidence, so it keeps
    /// requesting high fidelity and the framework may silently serve the
    /// fast model — the same caveat the config builders document. No
    /// on-demand probe runs at archive-run start.
    func effectiveAppleTier(_ engine: RetranslateEngine, targetCode: String) -> RetranslateEngine {
        tierAvailability.effectiveTier(engine, targetCode: targetCode)
    }

    /// The settings re-translate selection resolved for `targetCode` — the
    /// settings-selection spelling of `effectiveAppleTier(_:targetCode:)`,
    /// which documents the degrade semantics. Every consumer switches on the
    /// effective selection, so the persisted `.appleHighFidelity` is never
    /// rewritten; only its resolution degrades.
    func effectiveRetranslateSelection(targetCode: String) -> RetranslateEngine {
        effectiveAppleTier(settings.retranslateEngine, targetCode: targetCode)
    }

    /// The settings-pair spelling of `effectiveRetranslateSelection(targetCode:)`.
    var effectiveRetranslateSelection: RetranslateEngine {
        effectiveRetranslateSelection(targetCode: settings.targetLanguage.code)
    }

    /// True when the configured retry engine resolves to an engine *other
    /// than* the live session engine — the transcript's retry button drops
    /// its worker/status requirements in that case (a dead session engine is
    /// exactly when routing the retry elsewhere is useful). A selection that
    /// names the live session's own engine is not an alternate: the lane
    /// would run the identical engine (for Apple, a deterministic one) and
    /// show no marker.
    ///
    /// Archive mode has no live session to differ from: every retry is a
    /// dedicated alternate there (a `.session` selection maps to Apple-fast;
    /// externals are alternates when their key is usable), so only the
    /// key-less external case reports "not an alternate".
    var alternateRetranslateEngineActive: Bool {
        if archiveOpen {
            switch effectiveRetranslateSelection {
            case .session, .appleFast, .appleHighFidelity:
                return true
            case let selection:
                guard let provider = selection.provider else { return false }
                return settings.hasKey(for: provider)
            }
        }
        switch effectiveRetranslateSelection {
        case .session:
            return false
        case .appleFast:
            return !liveSessionRunsKind(.appleFast)
        case .appleHighFidelity:
            return !liveSessionRunsKind(.appleHighFidelity)
        case let selection:
            guard let provider = selection.provider,
                  provider != live?.activeExternalProvider
            else { return false }
            return settings.hasKey(for: provider)
        }
    }

    // MARK: - Settings selection

    /// Settings card selection. The on-device rows complete immediately; an
    /// external row holds its intent behind the cloud disclosure sheet —
    /// same semantics as provider switching, no persisted acknowledgment.
    func selectRetranslateEngine(_ engine: RetranslateEngine) {
        switch engine {
        case .session, .appleFast, .appleHighFidelity:
            settings.selectRetranslate(engine)
        case let selection:
            guard let provider = selection.provider else { return }
            // Same invariant as `verifyAndSelect`: a selection is not raised
            // while another disclosure intent is held — the raise would
            // clobber it and swap the presented sheet's content mid-flight.
            guard live?.providerAwaitingDisclosure == nil else { return }
            live?.providerAwaitingDisclosure = .retranslateEngine(provider)
        }
    }
}
