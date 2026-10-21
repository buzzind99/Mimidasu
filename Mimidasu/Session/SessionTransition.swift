/// The inputs the session phase reacts to.
///
/// One case per thing that can change the phase, plus the ones that must be
/// said out loud even though they change nothing by themselves: the resume
/// that was abandoned, and the model availability that was resolved.
enum SessionAction: Sendable, Equatable, Hashable {
    // Start
    case startRequested
    case beginSucceeded
    case beginReturnedNoModel
    case beginFailed(String)
    /// The bring-up was interrupted by a teardown that moved the phase off
    /// `.starting` while `begin()` was in flight. The host asks the machine
    /// with this action right after `begin()` returns: a **refusal** means the
    /// phase is still `.starting` (the session may come up), a **compensating**
    /// transition means it is not (the bring-up left something behind that
    /// must be torn down).
    case beginInterruptedByTeardown
    /// The teardown a raced bring-up owed has landed: a `.stopping` session
    /// winds back to `.idle`.
    case teardownCompleted
    // Pause / resume
    case pauseRequested
    case resumeRequested
    case resumeSucceeded
    case resumeFailed(String)
    case resumeAbandoned
    // Capture
    case captureLost(String)
    case captureRestartRequested
    case captureRestartSucceeded
    case captureRestartFailed(String)
    // Model availability
    case modelResolved(resolved: Bool)
    // Stop / termination
    case stopRequested
    case stopCompleted
    case terminationStarted

    /// The family the action belongs to.
    ///
    /// The families exist so the machine's dispatch can be split into four
    /// readable reducers; they carry no behaviour of their own.
    var family: SessionActionFamily {
        switch self {
        case .startRequested, .beginSucceeded, .beginReturnedNoModel, .beginFailed,
             .beginInterruptedByTeardown, .teardownCompleted:
            .start
        case .pauseRequested, .resumeRequested, .resumeSucceeded, .resumeFailed, .resumeAbandoned:
            .pauseResume
        case .captureLost, .captureRestartRequested, .captureRestartSucceeded, .captureRestartFailed:
            .capture
        case .modelResolved, .stopRequested, .stopCompleted, .terminationStarted:
            .lifecycle
        }
    }
}

/// The four families of session actions.
enum SessionActionFamily: Sendable, Equatable, Hashable {
    case start
    case pauseResume
    case capture
    case lifecycle
}

/// The side effects a transition asks the host to perform.
///
/// Only *gated* effects live here — the ones that must NOT happen when a
/// transition is refused. Bookkeeping that is unconditional once a transition
/// is accepted (toast dismissals, the pause-span close, the capture-lost
/// anchor, the translation-queue reset) stays at the call site.
///
/// The three capture-lost cards are distinct cases because they carry
/// different bodies; one shared case would push presentation back into the
/// machine.
enum SessionEffect: Sendable, Equatable, Hashable {
    // Start path
    case awaitDictionary
    case beginSession
    // Capture / pause / resume
    case stopCapture
    case resumeCapture
    case flushEngine
    case restartCapture
    case deferCaptureError(String)
    // Cards
    case postCaptureLost(String)
    case postRestartFailed(String)
    case postResumeFailed(String)
    case postSessionFailed(String)
    // Session bring-up
    case activateTranslation
    case startTimers
    case armNoAudioWatchdog
    // Model availability
    case warmUpEngine
    // Stop / teardown
    case tearDownSession
    case drainTranslation
    case clearToastsAndNotices
    case finalizeLiveSession
    case postArchivedRecentToast
    // Termination
    /// Wait for the stop that is already staged before retiring the engine.
    case awaitStagedStop
    case retireWarmEngine
    case postTerminationTeardownComplete
}

/// The outcome of a transition: what happened to the phase, and what the
/// host must do about it.
///
/// Three categories, and the difference between them matters:
///
/// - **legal** — the action was legal in the phase the machine was in: the
///   phase moved (or was already where it had to be) and the effects must
///   run;
/// - **refused** — the action was illegal: nothing changed, nothing runs;
/// - **compensating** — the action was illegal, but the session still owes a
///   teardown: the phase moves the way production moves it and the
///   compensating effect must run.
enum SessionTransition: Sendable, Equatable {
    /// A legal transition: the phase landed on `phase` and the effects must
    /// run, in the order they are listed.
    case legal(phase: SessionPhase, effects: [SessionEffect])
    /// A refused transition: the phase did not move and no effect runs.
    case refused(phase: SessionPhase)
    /// A compensating transition: the action was illegal, but the session
    /// still owes a teardown. The phase landed on `phase` — it may have
    /// moved, exactly the way production moves it — and the effects must run.
    case compensating(phase: SessionPhase, effects: [SessionEffect])

    /// The phase after the transition.
    var phase: SessionPhase {
        switch self {
        case let .legal(phase, _), let .refused(phase), let .compensating(phase, _):
            phase
        }
    }

    /// The effects the host must run, in order. Empty for a refusal.
    var effects: [SessionEffect] {
        switch self {
        case let .legal(_, effects), let .compensating(_, effects):
            effects
        case .refused:
            []
        }
    }

    /// Whether the action was legal in the phase the machine was in.
    var isLegal: Bool {
        switch self {
        case .legal:
            true
        case .refused, .compensating:
            false
        }
    }

    /// Whether the transition asks for a session teardown — the compensating
    /// effect that keeps a torn-down session from coming back up.
    var requiresTeardown: Bool {
        effects.contains(.tearDownSession)
    }
}
