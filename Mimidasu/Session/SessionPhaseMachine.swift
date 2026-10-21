/// The owner of the app-level session phase.
///
/// A pure value type: no actor, no host, no I/O. The whole machine is one
/// `reduce` function over one state field, so the transition table is
/// testable on its own — no `AppModel`, no `SessionController`, no script.
///
/// Three transition categories, and the difference between them matters:
///
/// - a **legal** action moves the phase and emits its effects;
/// - a **refused** action changes nothing and emits nothing;
/// - a **compensating** action changes the phase only as the production code
///   does and still emits the effect that keeps a torn-down session from
///   coming back up.
///
/// The returned effects **name** the gated side effects, in the order they
/// happen. The host performs them — the list is the transition's
/// *description*, not an execution plan: the host's lifecycle spans several
/// actions and also owns bookkeeping the machine does not model.
///
/// The production-site table names the call sites production makes and what
/// each one does; its source check keeps that table and the production
/// sources in step, so a call site cannot appear or move unnoticed. The
/// effect lists themselves are a hand-written description of what each site
/// gates.
///
/// The quit-time teardown's order matters — the staged stop has to land
/// before the warm engine is retired — and it is stated here *and* asserted
/// against production by the session tests.
struct SessionPhaseMachine: Sendable {

    // MARK: - State

    /// The one owner of the app-level session phase.
    private(set) var phase: SessionPhase

    /// The resume double-click guard: a resume is airborne while the session
    /// is `.paused` and the IOProc is still coming back.
    private(set) var isResuming: Bool = false

    /// The quit-time teardown latch: once set, no new session may begin.
    private(set) var isTerminating: Bool = false

    init(phase: SessionPhase = .idle) {
        self.phase = phase
    }

    // MARK: - Derived live-phase predicates

    /// The 3-case predicate: `.running || .sourceLost || .paused`.
    ///
    /// A transcript is live in exactly these phases. The `.starting` phase is
    /// deliberately **not** live here: a session that is still coming up has
    /// no transcript to show, and a capture source that was lost is still a
    /// live session the user must be able to stop.
    ///
    /// The switch is exhaustive on purpose: the phase's case set is a
    /// contract, and this is the one place that states what "live" means.
    static func isLive(_ phase: SessionPhase) -> Bool {
        switch phase {
        case .running, .sourceLost, .paused: true
        case .needsModel, .idle, .starting, .stopping: false
        case .failed: false
        }
    }

    /// The 4-case predicate: the 3-case one plus `.starting`.
    ///
    /// A `.starting` session is live *for wind-down purposes* — a stop must
    /// be accepted while the session is still coming up, and the quit-time
    /// teardown must take it down — but not for transcript purposes. Two
    /// predicates, not one.
    ///
    /// The set is exactly the set a stop or a termination may wind down, so
    /// the machine reads this predicate where it once spelled the same four
    /// cases out twice.
    static func isLiveOrStarting(_ phase: SessionPhase) -> Bool {
        switch phase {
        case .running, .sourceLost, .paused, .starting: true
        case .needsModel, .idle, .stopping: false
        case .failed: false
        }
    }

    /// The 5-case predicate: the 4-case one plus `.stopping`.
    ///
    /// These are the phases in which a **session exists** and owns the app's
    /// session-scoped controls: an archived session cannot be opened over it,
    /// the target language is locked to it, and the quit-time teardown winds
    /// it down. `.stopping` counts — a session on its way out still holds the
    /// pane until the teardown lands.
    static func isLiveOrStopping(_ phase: SessionPhase) -> Bool {
        switch phase {
        case .running, .sourceLost, .paused, .starting, .stopping: true
        case .needsModel, .idle: false
        case .failed: false
        }
    }

    /// The 3-case predicate over the machine's own phase.
    var isLive: Bool {
        Self.isLive(phase)
    }

    /// The 4-case predicate over the machine's own phase.
    var isLiveOrStarting: Bool {
        Self.isLiveOrStarting(phase)
    }

    /// The 5-case predicate over the machine's own phase.
    var isLiveOrStopping: Bool {
        Self.isLiveOrStopping(phase)
    }

    // MARK: - Transition

    /// The whole machine: one pure function over one state field.
    ///
    /// The dispatch runs through the action's family, so each family's
    /// reducer stays small enough to read at a glance — the machine's
    /// behaviour is unaffected by the grouping.
    mutating func reduce(_ action: SessionAction) -> SessionTransition {
        switch action.family {
        case .start: reduceStart(action)
        case .pauseResume: reducePauseResume(action)
        case .capture: reduceCapture(action)
        case .lifecycle: reduceLifecycle(action)
        }
    }

    // MARK: - Family dispatch

    /// The start path: a request to begin, and the outcomes a begin can have.
    ///
    /// The `default` arm is unreachable: the dispatch hands each family only
    /// its own actions. It stays a refusal rather than a trap because the
    /// transition table is the real guard — an action added to a family
    /// without a rule here gets a table row, and the table then fails.
    private mutating func reduceStart(_ action: SessionAction) -> SessionTransition {
        switch action {
        case .startRequested: reduceStartRequested()
        case .beginSucceeded: reduceBeginSucceeded()
        case .beginReturnedNoModel: reduceBeginReturnedNoModel()
        case .beginInterruptedByTeardown: reduceBeginInterruptedByTeardown()
        case .teardownCompleted: reduceTeardownCompleted()
        case let .beginFailed(message): reduceBeginFailed(message)
        default: .refused(phase: phase)
        }
    }

    /// The pause path: suspending capture and the resume that follows.
    private mutating func reducePauseResume(_ action: SessionAction) -> SessionTransition {
        switch action {
        case .pauseRequested: reducePauseRequested()
        case .resumeRequested: reduceResumeRequested()
        case .resumeSucceeded: reduceResumeSucceeded()
        case let .resumeFailed(message): reduceResumeFailed(message)
        case .resumeAbandoned: reduceResumeAbandoned()
        default: .refused(phase: phase)
        }
    }

    /// The capture path: a lost source and the restart that may follow.
    private mutating func reduceCapture(_ action: SessionAction) -> SessionTransition {
        switch action {
        case let .captureLost(message): reduceCaptureLost(message)
        case .captureRestartRequested: reduceCaptureRestartRequested()
        case .captureRestartSucceeded: reduceCaptureRestartSucceeded()
        case let .captureRestartFailed(message): reduceCaptureRestartFailed(message)
        default: .refused(phase: phase)
        }
    }

    /// The lifecycle path: the model's availability, the stop, and the
    /// quit-time teardown.
    private mutating func reduceLifecycle(_ action: SessionAction) -> SessionTransition {
        switch action {
        case let .modelResolved(resolved): reduceModelResolved(resolved)
        case .stopRequested: reduceStopRequested()
        case .stopCompleted: reduceStopCompleted()
        case .terminationStarted: reduceTerminationStarted()
        default: .refused(phase: phase)
        }
    }

    // MARK: - Transitions

    /// The start request. Only an idle or failed session may begin; a failed
    /// session restarts like an idle one, because the sidebar offers Start
    /// from `.failed` and the failure card clears on the next Start.
    ///
    /// The archive and model-availability guards are not session-phase facts
    /// and stay with the caller; the quit-time latch is machine state.
    private mutating func reduceStartRequested() -> SessionTransition {
        guard !isTerminating else { return .refused(phase: phase) }
        switch phase {
        case .idle, .failed:
            move(to: .starting)
            return .legal(phase: phase, effects: [.awaitDictionary, .beginSession])
        default:
            return .refused(phase: phase)
        }
    }

    /// The session came up.
    ///
    /// From `.starting` the session goes live. From any other phase the
    /// session must **not** come up — but whatever the bring-up left behind
    /// still has to be torn down, or a stopped session would survive its own
    /// teardown.
    ///
    /// The compensation does **not** move the phase: production winds a
    /// stopped session back to `.idle` *after* the teardown has landed (see
    /// `teardownCompleted`), and moving it earlier would offer the user a
    /// Start while the old session is still being torn down.
    private mutating func reduceBeginSucceeded() -> SessionTransition {
        switch phase {
        case .starting:
            move(to: .running)
            return .legal(
                phase: phase,
                effects: [.activateTranslation, .startTimers, .armNoAudioWatchdog]
            )
        default:
            return .compensating(phase: phase, effects: [.tearDownSession])
        }
    }

    /// The bring-up found no usable model.
    ///
    /// The phase check comes first: a bring-up that was interrupted by a
    /// teardown must not resurrect a `.needsModel` phase over a session that
    /// is being wound down — the teardown wins, and the compensation leaves
    /// the wind-back to the teardown's completion.
    private mutating func reduceBeginReturnedNoModel() -> SessionTransition {
        switch phase {
        case .starting:
            move(to: .needsModel)
            return .legal(phase: phase, effects: [])
        default:
            return .compensating(phase: phase, effects: [.tearDownSession])
        }
    }

    /// The bring-up was interrupted by a teardown.
    ///
    /// The host asks the machine with this action right after `begin()`
    /// returns, because the phase may have moved while `begin()` was in
    /// flight:
    ///
    /// - from `.starting` the action is **refused** — the bring-up was not
    ///   interrupted and the session may still come up;
    /// - from any other phase the teardown is owed.
    ///
    /// The phase stays put: production winds a stopped session back to
    /// `.idle` *after* the teardown lands (`teardownCompleted`), and moving
    /// it here would offer the user a Start while the old session is still
    /// being torn down.
    private mutating func reduceBeginInterruptedByTeardown() -> SessionTransition {
        switch phase {
        case .starting:
            .refused(phase: phase)
        default:
            .compensating(phase: phase, effects: [.tearDownSession])
        }
    }

    /// The teardown a raced bring-up owed has landed: a session that was
    /// wound down while the bring-up was in flight goes back to `.idle`.
    ///
    /// This is production's `if phase == .stopping { phase = .idle }` — the
    /// wind-back lands **after** the teardown, so a session left in
    /// `.stopping` never outlives it (the stop confirmation, the sidebar
    /// title, the archive gate and the target-language card would all keep
    /// reading "stopping" forever). From any other phase the action is
    /// refused: the wind-back belongs to the session that was winding down.
    private mutating func reduceTeardownCompleted() -> SessionTransition {
        guard phase == .stopping else { return .refused(phase: phase) }
        move(to: .idle)
        return .legal(phase: phase, effects: [])
    }

    /// The bring-up failed.
    ///
    /// A failure that lands after a raced teardown is **dropped**: it must
    /// not resurrect a failed phase and must not repost over the toast stack
    /// the teardown cleared. Note the asymmetry with a successful bring-up —
    /// a dropped failure emits nothing at all, because there is nothing to
    /// tear down.
    private mutating func reduceBeginFailed(_ message: String) -> SessionTransition {
        guard phase == .starting else { return .refused(phase: phase) }
        move(to: .failed(message))
        return .legal(phase: phase, effects: [.postSessionFailed(message)])
    }

    /// The pause request. The phase flips to `.paused` synchronously,
    /// *before* the capture stop is even enqueued — so there is no
    /// pause-result phase write.
    private mutating func reducePauseRequested() -> SessionTransition {
        guard phase == .running else { return .refused(phase: phase) }
        move(to: .paused)
        return .legal(phase: phase, effects: [.stopCapture])
    }

    /// The resume request. The phase stays `.paused` until the IOProc is
    /// actually back; the double-click guard is a latch, not a phase.
    private mutating func reduceResumeRequested() -> SessionTransition {
        guard phase == .paused, !isResuming else { return .refused(phase: phase) }
        isResuming = true
        return .legal(phase: phase, effects: [.resumeCapture])
    }

    /// The resume succeeded.
    private mutating func reduceResumeSucceeded() -> SessionTransition {
        guard phase == .paused else { return .refused(phase: phase) }
        move(to: .running)
        return .legal(phase: phase, effects: [.flushEngine])
    }

    /// The resume failed: the capture is gone, so the session reads as
    /// source-lost rather than paused.
    private mutating func reduceResumeFailed(_ message: String) -> SessionTransition {
        guard phase == .paused else { return .refused(phase: phase) }
        move(to: .sourceLost)
        return .legal(phase: phase, effects: [.postCaptureLost(message)])
    }

    /// The resume was abandoned: the latch is cleared and nothing else
    /// changes.
    ///
    /// The latch is also cleared whenever the phase leaves `.paused` (see
    /// `move(to:)`), so this action is the host's explicit "I gave up on
    /// this resume" — it does not depend on that rule holding.
    private mutating func reduceResumeAbandoned() -> SessionTransition {
        isResuming = false
        return .legal(phase: phase, effects: [])
    }

    /// The capture source died.
    ///
    /// While the session is running (or still coming up) it reads as
    /// source-lost. While it is **paused** the error is parked for the
    /// resume path instead — the paused phase does not change, because the
    /// capture is stopped on purpose and the resume rebuilds it.
    private mutating func reduceCaptureLost(_ message: String) -> SessionTransition {
        switch phase {
        case .running, .starting:
            move(to: .sourceLost)
            return .legal(phase: phase, effects: [.postCaptureLost(message)])
        case .paused:
            return .legal(phase: phase, effects: [.deferCaptureError(message)])
        default:
            return .refused(phase: phase)
        }
    }

    /// A capture restart was requested.
    ///
    /// The production write is unconditional, but only two callers reach it
    /// and each has its own guard — a restart from source-lost, and the
    /// rebuild a deferred resume performs. The machine relocates that
    /// caller-level guard into the legal-from set, which leaves the
    /// reachable set unchanged.
    private mutating func reduceCaptureRestartRequested() -> SessionTransition {
        switch phase {
        case .sourceLost, .paused:
            move(to: .starting)
            return .legal(phase: phase, effects: [.restartCapture])
        default:
            return .refused(phase: phase)
        }
    }

    /// The capture restart succeeded.
    private mutating func reduceCaptureRestartSucceeded() -> SessionTransition {
        guard phase == .starting else { return .refused(phase: phase) }
        move(to: .running)
        return .legal(phase: phase, effects: [.armNoAudioWatchdog])
    }

    /// The capture restart failed: the session is still source-lost.
    private mutating func reduceCaptureRestartFailed(_ message: String) -> SessionTransition {
        guard phase == .starting else { return .refused(phase: phase) }
        move(to: .sourceLost)
        return .legal(phase: phase, effects: [.postCaptureLost(message)])
    }

    /// The model's availability was resolved.
    ///
    /// An idle session whose model cannot be found reads as needing a model;
    /// a session that needed one and now has it goes back to idle. The warm-up
    /// runs either way — it is not gated on the phase.
    private mutating func reduceModelResolved(_ resolved: Bool) -> SessionTransition {
        switch (phase, resolved) {
        case (.idle, false):
            move(to: .needsModel)
        case (.needsModel, true):
            move(to: .idle)
        default:
            break
        }
        return .legal(phase: phase, effects: [.warmUpEngine])
    }

    /// The stop request. `.stopping` is not in the legal-from set: a second
    /// stop is a no-op, not a second teardown.
    private mutating func reduceStopRequested() -> SessionTransition {
        guard isLiveOrStarting else { return .refused(phase: phase) }
        move(to: .stopping)
        return .legal(phase: phase, effects: [.stopCapture, .drainTranslation])
    }

    /// The teardown finished.
    ///
    /// The production write is unconditional: the teardown always winds the
    /// session back to `.idle`, whatever phase the teardown started from. The
    /// teardown is only *reached* after the phase was moved to `.stopping`
    /// (or after a raced teardown already wound it back to idle) — a stale
    /// completion is not a thing the app can produce, and production's
    /// unconditional write is what the machine reproduces.
    private mutating func reduceStopCompleted() -> SessionTransition {
        move(to: .idle)
        return .legal(
            phase: phase,
            effects: [
                .drainTranslation,
                .clearToastsAndNotices,
                .finalizeLiveSession,
                .postArchivedRecentToast
            ]
        )
    }

    /// The quit-time teardown began.
    ///
    /// The latch makes it single-shot: a second termination request is
    /// refused, and no new session may begin afterwards.
    ///
    /// From a live phase the machine winds the session down itself; from
    /// `.stopping` a stop is already staged and owns the teardown, so the
    /// machine waits for it — **the staged stop must land before the warm
    /// engine is retired**, and the effect order states that explicitly.
    private mutating func reduceTerminationStarted() -> SessionTransition {
        guard !isTerminating else { return .refused(phase: phase) }
        isTerminating = true
        if isLiveOrStarting {
            move(to: .stopping)
            return .legal(
                phase: phase,
                effects: [
                    .stopCapture,
                    .drainTranslation,
                    .clearToastsAndNotices,
                    .finalizeLiveSession,
                    .postArchivedRecentToast,
                    .retireWarmEngine,
                    .postTerminationTeardownComplete
                ]
            )
        }
        if phase == .stopping {
            return .legal(
                phase: phase,
                effects: [.awaitStagedStop, .retireWarmEngine, .postTerminationTeardownComplete]
            )
        }
        return .legal(
            phase: phase,
            effects: [.retireWarmEngine, .postTerminationTeardownComplete]
        )
    }

    // MARK: - Phase writes

    /// A phase write that is not a transition: the phase moves, the machine's
    /// own coherence rule applies, and the **quit-time latch survives**.
    ///
    /// The latch is the one fact a phase write may never revoke: it says the
    /// app is tearing down, and only the teardown may clear it. A host that
    /// wrote the phase directly must not be able to re-open the start gate
    /// underneath a termination in flight.
    mutating func setPhase(_ newPhase: SessionPhase) {
        move(to: newPhase)
    }

    /// Test seam: force the phase without going through a transition.
    ///
    /// **Both internal latches are reset** — this is the only way to clear
    /// the quit-time latch, and it exists for tests alone.
    ///
    /// `isResuming` and `isTerminating` describe facts about the *current*
    /// phase's session, and the phases a test forces are exactly the phases
    /// where those facts are either impossible or irrelevant:
    ///
    /// - `isResuming` is only meaningful while `.paused` (a resume is
    ///   airborne). A test that forces `.paused` is simulating "a paused
    ///   session that is not mid-resume"; leaving the latch set would make
    ///   the next resume request a silent no-op.
    /// - `isTerminating` is only meaningful while a teardown is in flight. A
    ///   test that forces `.idle` is simulating "no session"; leaving the
    ///   latch set would permanently refuse a start, and no production path
    ///   ever clears it — the test could not recover.
    ///
    /// Preserving the latches would also enlarge the machine's state space
    /// past what production can reach (e.g. `.idle` + `isTerminating`).
    mutating func setPhaseForTesting(_ newPhase: SessionPhase) {
        phase = newPhase
        isResuming = false
        isTerminating = false
    }

    // MARK: - Private

    /// Moves the phase and keeps the `isResuming` latch coherent: a resume
    /// is only airborne while the session is `.paused`, so leaving `.paused`
    /// clears the latch.
    private mutating func move(to newPhase: SessionPhase) {
        phase = newPhase
        if newPhase != .paused {
            isResuming = false
        }
    }
}
