@testable import Mimidasu
import Testing

/// The transition table — the specification the machine is checked against.
///
/// Every action × every phase is listed with the expected category (legal /
/// refused / compensating), the expected resulting phase and the expected
/// effects. The table IS the specification: nothing else in the machine
/// decides anything.
enum SessionPhaseMachineTransitionTable {

    /// The canonical phase order every expectation row is written in:
    /// `.idle`, `.needsModel`, `.starting`, `.running`, `.paused`,
    /// `.sourceLost`, `.stopping`, `.failed("boom")`.
    static let canonicalPhases: [SessionPhase] = [
        .idle,
        .needsModel,
        .starting,
        .running,
        .paused,
        .sourceLost,
        .stopping,
        .failed("boom")
    ]

    /// The effect bundle a finished stop runs.
    static let stopCompletionBundle: [SessionEffect] = [
        .drainTranslation,
        .clearToastsAndNotices,
        .finalizeLiveSession,
        .postArchivedRecentToast
    ]

    /// The effect bundle a quit-time teardown runs from a live phase.
    static let terminationTeardownBundle: [SessionEffect] = [
        .stopCapture,
        .drainTranslation,
        .clearToastsAndNotices,
        .finalizeLiveSession,
        .postArchivedRecentToast,
        .retireWarmEngine,
        .postTerminationTeardownComplete
    ]

    /// The effect bundle a quit-time teardown runs when a stop is already
    /// staged: the staged stop is awaited before the engine is retired.
    static let stagedTerminationBundle: [SessionEffect] = [
        .awaitStagedStop,
        .retireWarmEngine,
        .postTerminationTeardownComplete
    ]

    /// The three transition categories, as the table states them.
    enum Category: String, Sendable {
        case legal
        case refused
        case compensating
    }

    /// One action's outcome in one phase.
    enum Expectation: Sendable {
        /// The action was legal: the phase lands on `to` and the effects run.
        case legal(to: SessionPhase, effects: [SessionEffect])
        /// The action was refused: the phase stays and nothing runs.
        case refused
        /// The action was illegal but owes a compensation: the phase lands on
        /// `to` (it may have moved) and the effects run.
        case compensating(to: SessionPhase, effects: [SessionEffect])
    }

    struct Row: Sendable {
        let action: SessionAction
        let from: SessionPhase
        let to: SessionPhase
        let effects: [SessionEffect]
        let category: Category
    }

    /// Builds the eight expectation rows for one action, in the canonical
    /// phase order.
    static func rows(
        for action: SessionAction,
        _ expectations: [Expectation]
    ) -> [Row] {
        precondition(
            expectations.count == canonicalPhases.count,
            "every action needs one expectation per phase"
        )
        return zip(canonicalPhases, expectations).map { from, expectation in
            switch expectation {
            case let .legal(to, effects):
                Row(action: action, from: from, to: to, effects: effects, category: .legal)
            case .refused:
                Row(action: action, from: from, to: from, effects: [], category: .refused)
            case let .compensating(to, effects):
                Row(action: action, from: from, to: to, effects: effects, category: .compensating)
            }
        }
    }

    /// The category a transition belongs to.
    static func category(of transition: SessionTransition) -> Category {
        switch transition {
        case .legal: .legal
        case .refused: .refused
        case .compensating: .compensating
        }
    }

    // MARK: - The table

    static let table: [Row] = rows(for: .startRequested, [
        .legal(to: .starting, effects: [.awaitDictionary, .beginSession]), // .idle
        .refused, // .needsModel
        .refused, // .starting
        .refused, // .running
        .refused, // .paused
        .refused, // .sourceLost
        .refused, // .stopping
        .legal(to: .starting, effects: [.awaitDictionary, .beginSession]) // .failed
    ]) + rows(for: .beginSucceeded, [
        .compensating(to: .idle, effects: [.tearDownSession]), // .idle
        .compensating(to: .needsModel, effects: [.tearDownSession]), // .needsModel
        .legal(
            to: .running,
            effects: [.activateTranslation, .startTimers, .armNoAudioWatchdog]
        ), // .starting
        .compensating(to: .running, effects: [.tearDownSession]), // .running
        .compensating(to: .paused, effects: [.tearDownSession]), // .paused
        .compensating(to: .sourceLost, effects: [.tearDownSession]), // .sourceLost
        .compensating(to: .stopping, effects: [.tearDownSession]), // .stopping — COMPENSATING
        .compensating(to: .failed("boom"), effects: [.tearDownSession]) // .failed
    ]) + rows(for: .beginReturnedNoModel, [
        .compensating(to: .idle, effects: [.tearDownSession]), // .idle
        .compensating(to: .needsModel, effects: [.tearDownSession]), // .needsModel
        .legal(to: .needsModel, effects: []), // .starting
        .compensating(to: .running, effects: [.tearDownSession]), // .running
        .compensating(to: .paused, effects: [.tearDownSession]), // .paused
        .compensating(to: .sourceLost, effects: [.tearDownSession]), // .sourceLost
        .compensating(to: .stopping, effects: [.tearDownSession]), // .stopping
        .compensating(to: .failed("boom"), effects: [.tearDownSession]) // .failed
    ]) + rows(for: .beginInterruptedByTeardown, [
        .compensating(to: .idle, effects: [.tearDownSession]), // .idle
        .compensating(to: .needsModel, effects: [.tearDownSession]), // .needsModel
        .refused, // .starting — not interrupted: the session may come up
        .compensating(to: .running, effects: [.tearDownSession]), // .running
        .compensating(to: .paused, effects: [.tearDownSession]), // .paused
        .compensating(to: .sourceLost, effects: [.tearDownSession]), // .sourceLost
        .compensating(to: .stopping, effects: [.tearDownSession]), // .stopping
        .compensating(to: .failed("boom"), effects: [.tearDownSession]) // .failed
    ]) + rows(for: .teardownCompleted, [
        .refused, // .idle
        .refused, // .needsModel
        .refused, // .starting
        .refused, // .running
        .refused, // .paused
        .refused, // .sourceLost
        .legal(to: .idle, effects: []), // .stopping — the wind-back
        .refused // .failed
    ]) + rows(for: .beginFailed("boom"), [
        .refused, // .idle
        .refused, // .needsModel
        .legal(to: .failed("boom"), effects: [.postSessionFailed("boom")]), // .starting
        .refused, // .running
        .refused, // .paused
        .refused, // .sourceLost
        .refused, // .stopping
        .refused // .failed
    ]) + rows(for: .pauseRequested, [
        .refused, // .idle
        .refused, // .needsModel
        .refused, // .starting
        .legal(to: .paused, effects: [.stopCapture]), // .running
        .refused, // .paused
        .refused, // .sourceLost
        .refused, // .stopping
        .refused // .failed
    ]) + rows(for: .resumeRequested, [
        .refused, // .idle
        .refused, // .needsModel
        .refused, // .starting
        .refused, // .running
        .legal(to: .paused, effects: [.resumeCapture]), // .paused
        .refused, // .sourceLost
        .refused, // .stopping
        .refused // .failed
    ]) + rows(for: .resumeSucceeded, [
        .refused, // .idle
        .refused, // .needsModel
        .refused, // .starting
        .refused, // .running
        .legal(to: .running, effects: [.flushEngine]), // .paused
        .refused, // .sourceLost
        .refused, // .stopping
        .refused // .failed
    ]) + rows(for: .resumeFailed("boom"), [
        .refused, // .idle
        .refused, // .needsModel
        .refused, // .starting
        .refused, // .running
        .legal(to: .sourceLost, effects: [.postResumeFailed("boom")]), // .paused
        .refused, // .sourceLost
        .refused, // .stopping
        .refused // .failed
    ]) + rows(for: .resumeAbandoned, [
        .legal(to: .idle, effects: []), // .idle
        .legal(to: .needsModel, effects: []), // .needsModel
        .legal(to: .starting, effects: []), // .starting
        .legal(to: .running, effects: []), // .running
        .legal(to: .paused, effects: []), // .paused
        .legal(to: .sourceLost, effects: []), // .sourceLost
        .legal(to: .stopping, effects: []), // .stopping
        .legal(to: .failed("boom"), effects: []) // .failed
    ]) + rows(for: .captureLost("stream died"), [
        .refused, // .idle
        .refused, // .needsModel
        .legal(to: .sourceLost, effects: [.postCaptureLost("stream died")]), // .starting
        .legal(to: .sourceLost, effects: [.postCaptureLost("stream died")]), // .running
        // .paused — deferred, no phase change
        .legal(to: .paused, effects: [.deferCaptureError("stream died")]),
        .refused, // .sourceLost
        .refused, // .stopping
        .refused // .failed
    ]) + rows(for: .captureRestartRequested, [
        .refused, // .idle
        .refused, // .needsModel
        .refused, // .starting
        .refused, // .running
        .legal(to: .starting, effects: [.restartCapture]), // .paused
        .legal(to: .starting, effects: [.restartCapture]), // .sourceLost
        .refused, // .stopping
        .refused // .failed
    ]) + rows(for: .captureRestartSucceeded, [
        .refused, // .idle
        .refused, // .needsModel
        .legal(to: .running, effects: [.armNoAudioWatchdog]), // .starting
        .refused, // .running
        .refused, // .paused
        .refused, // .sourceLost
        .refused, // .stopping
        .refused // .failed
    ]) + rows(for: .captureRestartFailed("boom"), [
        .refused, // .idle
        .refused, // .needsModel
        .legal(to: .sourceLost, effects: [.postRestartFailed("boom")]), // .starting
        .refused, // .running
        .refused, // .paused
        .refused, // .sourceLost
        .refused, // .stopping
        .refused // .failed
    ]) + rows(for: .modelResolved(resolved: true), [
        .legal(to: .idle, effects: [.warmUpEngine]), // .idle
        .legal(to: .idle, effects: [.warmUpEngine]), // .needsModel
        .legal(to: .starting, effects: [.warmUpEngine]), // .starting
        .legal(to: .running, effects: [.warmUpEngine]), // .running
        .legal(to: .paused, effects: [.warmUpEngine]), // .paused
        .legal(to: .sourceLost, effects: [.warmUpEngine]), // .sourceLost
        .legal(to: .stopping, effects: [.warmUpEngine]), // .stopping
        .legal(to: .failed("boom"), effects: [.warmUpEngine]) // .failed
    ]) + rows(for: .modelResolved(resolved: false), [
        .legal(to: .needsModel, effects: [.warmUpEngine]), // .idle
        .legal(to: .needsModel, effects: [.warmUpEngine]), // .needsModel
        .legal(to: .starting, effects: [.warmUpEngine]), // .starting
        .legal(to: .running, effects: [.warmUpEngine]), // .running
        .legal(to: .paused, effects: [.warmUpEngine]), // .paused
        .legal(to: .sourceLost, effects: [.warmUpEngine]), // .sourceLost
        .legal(to: .stopping, effects: [.warmUpEngine]), // .stopping
        .legal(to: .failed("boom"), effects: [.warmUpEngine]) // .failed
    ]) + rows(for: .stopRequested, [
        .refused, // .idle
        .refused, // .needsModel
        .legal(to: .stopping, effects: [.stopCapture, .drainTranslation]), // .starting
        .legal(to: .stopping, effects: [.stopCapture, .drainTranslation]), // .running
        .legal(to: .stopping, effects: [.stopCapture, .drainTranslation]), // .paused
        .legal(to: .stopping, effects: [.stopCapture, .drainTranslation]), // .sourceLost
        .refused, // .stopping — double stop refused
        .refused // .failed
    ]) + rows(for: .stopCompleted, [
        // The production write is unconditional: the teardown always winds
        // the session back to `.idle`.
        .legal(to: .idle, effects: stopCompletionBundle), // .idle
        .legal(to: .idle, effects: stopCompletionBundle), // .needsModel
        .legal(to: .idle, effects: stopCompletionBundle), // .starting
        .legal(to: .idle, effects: stopCompletionBundle), // .running
        .legal(to: .idle, effects: stopCompletionBundle), // .paused
        .legal(to: .idle, effects: stopCompletionBundle), // .sourceLost
        .legal(to: .idle, effects: stopCompletionBundle), // .stopping
        .legal(to: .idle, effects: stopCompletionBundle) // .failed
    ]) + rows(for: .terminationStarted, [
        .legal(
            to: .idle,
            effects: [.retireWarmEngine, .postTerminationTeardownComplete]
        ), // .idle
        .legal(
            to: .needsModel,
            effects: [.retireWarmEngine, .postTerminationTeardownComplete]
        ), // .needsModel
        .legal(to: .stopping, effects: terminationTeardownBundle), // .starting
        .legal(to: .stopping, effects: terminationTeardownBundle), // .running
        .legal(to: .stopping, effects: terminationTeardownBundle), // .paused
        .legal(to: .stopping, effects: terminationTeardownBundle), // .sourceLost
        .legal(to: .stopping, effects: stagedTerminationBundle), // .stopping — a stop is staged
        .legal(
            to: .failed("boom"),
            effects: [.retireWarmEngine, .postTerminationTeardownComplete]
        ) // .failed
    ])
}
