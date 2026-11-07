import Observation
import Translation

/// The re-translate lane: the transcript row's retry button re-running one
/// sentence through a chosen engine. Deep module behind one seam —
/// `retranslateSentence` / `selectRetranslateEngine` — owning the lane's
/// marker ownership, epoch clock, serialized one-at-a-time runner, and the
/// two dedicated Apple sessions (behind `RetranslateAppleSessions`). Engine
/// identity and the high-fidelity probe resolve through
/// `AppleTierAvailability` — the pair-scoped probe evidence shared with the
/// sibling `TranslationSessionCoordinator` (the live session); phase,
/// transcript pane, and toasts come from the host through
/// `TranslationSessionPort`.
///
/// File split: identity + selection + lane bookkeeping live here; the
/// decision builder sits in `RetranslateCoordinator+Plan.swift`;
/// `RetranslateCoordinator+Lane.swift` executes the row lane;
/// `RetranslateCoordinator+Sessions.swift` holds the session/archive
/// boundaries and the bulk job's engine resolution.
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
    private(set) var pendingRetranslations: Set<Int> = []

    /// The lane-owned subset of `pendingRetranslations`: markers the
    /// re-translate lane itself inserted. Fully internal — callers see the
    /// visible cue above, while the queue's terminal `.unavailable` clear
    /// uses this record to drop queue-owned markers only.
    @ObservationIgnored private var lanePendingRetranslations: Set<Int> = []

    /// Serialized one-at-a-time runner for alternate-engine retries: each
    /// new lane task awaits the previous one, so a session-backed engine
    /// never sees concurrent `translate` calls. Only the newest link can be
    /// cancelled; earlier ones run to completion and drop their results at
    /// the delivery guard.
    @ObservationIgnored private var laneChainTask: Task<Void, Never>?

    /// True while the newest lane-chain link has not finished. The chain is
    /// serial (each link awaits the previous), so the newest link's
    /// completion is the whole chain's. The bulk job's resolution waits on
    /// this instead of a captured task, so a close/swap releases the job's
    /// claim without awaiting a link the teardown already made
    /// undeliverable.
    @ObservationIgnored private var laneChainIdle = true

    /// Serial of the newest lane-chain link (see `laneChainIdle`): an older
    /// link finishing after a newer one exists must not idle the chain.
    @ObservationIgnored private var laneChainSerial = 0

    /// Waits registered on the chain going idle, keyed by waiter id.
    @ObservationIgnored private var chainIdleWaiters: [Int: CheckedContinuation<Bool, Never>] = [:]
    @ObservationIgnored private var nextChainWaiterID = 0

    /// Session boundary token for the re-translate lane, in the same spirit
    /// as `TranslationQueue`'s session epoch: bumped in
    /// `sessionWillBegin`, `sessionDidEnd` (through `teardown`), and
    /// archive boundaries (a mid-session Apple activation is a lane-
    /// generation change too), captured when a retry is clicked, and
    /// compared after the flight. A lane task that outlives its session —
    /// stop cancels only the newest chained link, so earlier ones run to
    /// completion — would otherwise pass the phase guard (the next session
    /// is `.running` again) and write the *previous* session's translation
    /// onto an unrelated row, since `Sentence.index` restarts at 0.
    @ObservationIgnored private var laneEpoch = 0

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

    /// The two dedicated Apple sessions, one arm per kind.
    let appleSessions: RetranslateAppleSessions

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
        appleSessions = RetranslateAppleSessions(tierAvailability: tierAvailability)
    }

    /// The fast-model session's config for its `.translationTask` host.
    var fastSessionConfig: TranslationSession.Configuration? {
        appleSessions.fastConfig
    }

    /// The Apple Intelligence session's config for its host.
    var hifiSessionConfig: TranslationSession.Configuration? {
        appleSessions.hifiConfig
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

    // MARK: - Lane bookkeeping

    /// The epoch a click captures; compared after every flight.
    var currentLaneEpoch: Int {
        laneEpoch
    }

    /// The newest chained link, for chaining the next one and for tests that
    /// need its lifetime. Read-only: only the boundary verbs replace it.
    var newestLaneTask: Task<Void, Never>? {
        laneChainTask
    }

    /// Registers a new lane-chain link and returns its serial. The chain is
    /// marked busy before the link task exists, so a wait never observes an
    /// idle chain mid-registration.
    func beginLaneChainLink() -> Int {
        laneChainSerial += 1
        laneChainIdle = false
        return laneChainSerial
    }

    /// Adopts the newest link's task so a boundary can cancel it.
    func trackLaneTask(_ task: Task<Void, Never>) {
        laneChainTask = task
    }

    /// Cancels the newest lane-chain link without a generation change — the
    /// shape a scheduler cancellation has. Teardown and the archive
    /// boundaries use their own verbs; this stays a narrow test seam.
    func cancelNewestLaneLink() {
        laneChainTask?.cancel()
    }

    /// Marks the chain idle when `serial` is still the newest link's, and
    /// answers every wait that was parked on the chain.
    func endLaneChainLink(serial: Int) {
        guard serial == laneChainSerial else { return }
        laneChainIdle = true
        resumeChainIdleWaiters(with: true)
    }

    /// Waits for the newest lane-chain link to finish. Returns false when
    /// the wait was abandoned by a teardown or by task cancellation — the
    /// bulk run resolving an engine treats that as its own cancellation.
    func waitForLaneChainIdle() async -> Bool {
        if Task.isCancelled {
            return false
        }
        if laneChainIdle {
            return true
        }
        let waiterID = nextChainWaiterID
        nextChainWaiterID += 1
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                // No suspension exists between the idle check above and this
                // registration, so the chain cannot turn idle in between.
                chainIdleWaiters[waiterID] = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finishChainWaiter(waiterID, with: false)
            }
        }
    }

    private func finishChainWaiter(_ waiterID: Int, with idle: Bool) {
        guard let waiter = chainIdleWaiters.removeValue(forKey: waiterID) else { return }
        waiter.resume(returning: idle)
    }

    private func resumeChainIdleWaiters(with idle: Bool) {
        for waiterID in Array(chainIdleWaiters.keys) {
            finishChainWaiter(waiterID, with: idle)
        }
    }

    /// Abandons every chain wait. Teardown is the only caller: an archive
    /// boundary deliberately keeps the bulk run's chain wait alive, since the
    /// run outlives the pane it was started from.
    private func abandonChainIdleWaiters() {
        resumeChainIdleWaiters(with: false)
    }

    // MARK: - Markers

    /// Inserts the visible cue, and records lane ownership when the lane is
    /// the deliverer.
    func markPending(_ index: Int, laneOwned: Bool) {
        pendingRetranslations.insert(index)
        if laneOwned {
            lanePendingRetranslations.insert(index)
        }
    }

    /// Hands a lane marker to the queue path: the cue stays (the queue's
    /// landing, failure, or stop clears it) while the lane-ownership record
    /// goes, so the queue's terminal `.unavailable` clear may drop it.
    func handPendingToQueue(_ index: Int) {
        lanePendingRetranslations.remove(index)
    }

    /// Retires the row's re-translation marker for a landed result.
    func clearMarkers(at index: Int) {
        pendingRetranslations.remove(index)
        lanePendingRetranslations.remove(index)
    }

    /// Drops every marker — a session/archive boundary.
    func clearAllMarkers() {
        pendingRetranslations.removeAll()
        lanePendingRetranslations.removeAll()
    }

    /// Drops lane-owned markers only; a queue-owned marker still has the
    /// queue as its deliverer.
    func retractLaneOwnedMarkers() {
        pendingRetranslations.subtract(lanePendingRetranslations)
        lanePendingRetranslations.removeAll()
    }

    /// The queue's terminal-`.unavailable` clear: no engine swap follows the
    /// failure, so queue-owned markers have lost their deliverer — but a
    /// lane translation in flight still has its own, and dropping its marker
    /// would re-open the double-click guard.
    func dropQueueOwnedMarkers() {
        pendingRetranslations.formIntersection(lanePendingRetranslations)
    }

    /// Retires the dim cue for a lane-owned index. Every exit that will not
    /// deliver must call this: a marker with no deliverer left dims the row
    /// and disables its retry button until session stop. Stop and a new
    /// session's begin clear the sets wholesale, but neither covers a capture
    /// restart — the phase simply parks in `.starting` while the device
    /// reopens, and a lane task crossing that window has to retire its own
    /// marker. Accepted loss: a same-session result that crosses the restart
    /// window is dropped without a toast (the row keeps its translation) —
    /// delivering mid-restart would race the transcript swap, and the
    /// alternative (a toast per dropped result) reads as an error the user
    /// did not cause.
    ///
    /// Gated on the captured epoch: retirement is the one lane operation a
    /// *stale* task still performs after its own delivery guards fail, and a
    /// blind remove by index could clobber a marker a NEW session's retry
    /// just inserted for the same (restarted-at-0) index — undimming a row
    /// whose translation is still in flight and reopening the double-click
    /// guard. A stale task's own markers were already retired by whichever
    /// boundary bumped the epoch, so skipping is always correct; the one
    /// epoch-preserving boundary (capture restart) still retires.
    func retireLaneMarker(_ index: Int, epoch: Int) {
        guard epoch == laneEpoch else { return }
        clearMarkers(at: index)
    }

    /// Whether a lane result captured against `epoch` may still be applied.
    /// Live: the session must be live (so a stop, or a capture restart that
    /// parks the phase in `.starting`, refuses the delivery) and must be the
    /// one the retry was clicked in. Archive mode: no phase to read — the
    /// open archive is the delivery target — and the epoch carries the whole
    /// check, since open and close both turn the lane generation over.
    func retranslateLaneCanDeliver(epoch: Int) -> Bool {
        guard epoch == laneEpoch else { return false }
        if archiveOpen {
            return true
        }
        return SessionPhaseMachine.isLive(sessionPhase)
    }

    /// Turns the lane generation over.
    func beginLaneEpoch() {
        laneEpoch += 1
    }

    /// Cancels the waits a lane generation turn makes stale: per-row retry
    /// engine hand-overs and the activation-probe deferral. The bulk run's
    /// resolution waits are not lane-owned and stay parked.
    func cancelLaneWaits() {
        appleSessions.cancelLaneWaiters()
        tierAvailability.cancelLaneWaiters()
    }

    /// Drops both armed-session states and invalidates in-flight lane work
    /// with them. Called from every explicit Apple activation and from
    /// session end. Cancelling the stored task and bumping the epoch makes
    /// the reset a lane-generation change, not just a session one; the
    /// marker split retires lane-owned cues synchronously while a
    /// queue-owned marker keeps its deliverer. Chain waits are abandoned so
    /// a bulk run resolving against the old generation reports cancelled
    /// instead of parking on a link this teardown made undeliverable.
    func teardown() {
        laneChainTask?.cancel()
        laneChainTask = nil
        beginLaneEpoch()
        retractLaneOwnedMarkers()
        abandonChainIdleWaiters()
        tierAvailability.cancelLaneWaiters()
        appleSessions.teardown()
    }

    /// Lane work and markers only: cancels the in-flight lane generation,
    /// drops every marker, and bumps the epoch so nothing still airborne can
    /// deliver. The dedicated Apple configs and stored engines are left
    /// untouched — they are target-scoped, not archive-scoped.
    func retireLaneWork() {
        clearAllMarkers()
        laneChainTask?.cancel()
        laneChainTask = nil
        beginLaneEpoch()
        cancelLaneWaits()
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
