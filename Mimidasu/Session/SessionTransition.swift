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

/// The outcome of a transition: what happened to the phase, and what the
/// host must do about it.
///
/// Three categories, and the difference between them matters:
///
/// - **legal** — the action was legal in the phase the machine was in: the
///   phase moved (or was already where it had to be);
/// - **refused** — the action was illegal: nothing changed;
/// - **compensating** — the action was illegal, but the session still owes a
///   teardown: the phase moves the way production moves it and the host
///   performs the compensating teardown.
struct SessionTransition: Sendable, Equatable {
    enum Category: Sendable, Equatable {
        case legal
        case refused
        case compensating
    }

    let phase: SessionPhase
    let category: Category

    /// Set only when `.captureLost` arrived while `.paused`: the host parks
    /// the message for the resume path instead of raising the capture-lost
    /// card. Nil for every other action.
    let deferredCaptureError: String?

    /// A legal transition: the phase landed on `phase`.
    static func legal(phase: SessionPhase) -> SessionTransition {
        SessionTransition(phase: phase, category: .legal, deferredCaptureError: nil)
    }

    /// A legal transition that parks a capture error for the resume path.
    static func legal(phase: SessionPhase, deferredCaptureError: String) -> SessionTransition {
        SessionTransition(phase: phase, category: .legal, deferredCaptureError: deferredCaptureError)
    }

    /// A refused transition: the phase did not move.
    static func refused(phase: SessionPhase) -> SessionTransition {
        SessionTransition(phase: phase, category: .refused, deferredCaptureError: nil)
    }

    /// A compensating transition: the action was illegal, but the session
    /// still owes a teardown. The phase landed on `phase` — it may have
    /// moved, exactly the way production moves it.
    static func compensating(phase: SessionPhase) -> SessionTransition {
        SessionTransition(phase: phase, category: .compensating, deferredCaptureError: nil)
    }

    /// Whether the action was legal in the phase the machine was in.
    var isLegal: Bool {
        category == .legal
    }

    /// Whether the transition asks for a session teardown — the compensating
    /// teardown that keeps a torn-down session from coming back up.
    ///
    /// The category decides: a compensating transition owes a teardown by
    /// definition, and a legal one never does.
    var requiresTeardown: Bool {
        category == .compensating
    }
}
