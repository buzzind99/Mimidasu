@testable import Mimidasu

/// The transition table — the specification the machine is checked against.
///
/// Every action × every phase is listed with the expected category (legal /
/// refused / compensating) and the expected resulting phase. The table IS
/// the specification: nothing else in the machine decides anything.
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

    /// The three transition categories, as the table states them.
    enum Category: String, Sendable {
        case legal
        case refused
        case compensating
    }

    /// One action's outcome in one phase.
    enum Expectation: Sendable {
        /// The action was legal: the phase lands on `to`.
        case legal(to: SessionPhase)
        /// The action was refused: the phase stays.
        case refused
        /// The action was illegal but owes a compensation: the phase lands
        /// on `to` (it may have moved).
        case compensating(to: SessionPhase)
    }

    struct Row: Sendable {
        let action: SessionAction
        let from: SessionPhase
        let to: SessionPhase
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
            case let .legal(to):
                Row(action: action, from: from, to: to, category: .legal)
            case .refused:
                Row(action: action, from: from, to: from, category: .refused)
            case let .compensating(to):
                Row(action: action, from: from, to: to, category: .compensating)
            }
        }
    }

    /// The category a transition belongs to.
    static func category(of transition: SessionTransition) -> Category {
        switch transition.category {
        case .legal: .legal
        case .refused: .refused
        case .compensating: .compensating
        }
    }

    // MARK: - The table

    static let table: [Row] = rows(for: .startRequested, [
        .legal(to: .starting), // .idle
        .refused, // .needsModel
        .refused, // .starting
        .refused, // .running
        .refused, // .paused
        .refused, // .sourceLost
        .refused, // .stopping
        .legal(to: .starting) // .failed
    ]) + rows(for: .beginSucceeded, [
        .compensating(to: .idle), // .idle
        .compensating(to: .needsModel), // .needsModel
        .legal(to: .running), // .starting
        .compensating(to: .running), // .running
        .compensating(to: .paused), // .paused
        .compensating(to: .sourceLost), // .sourceLost
        .compensating(to: .stopping), // .stopping — COMPENSATING
        .compensating(to: .failed("boom")) // .failed
    ]) + rows(for: .beginReturnedNoModel, [
        .compensating(to: .idle), // .idle
        .compensating(to: .needsModel), // .needsModel
        .legal(to: .needsModel), // .starting
        .compensating(to: .running), // .running
        .compensating(to: .paused), // .paused
        .compensating(to: .sourceLost), // .sourceLost
        .compensating(to: .stopping), // .stopping
        .compensating(to: .failed("boom")) // .failed
    ]) + rows(for: .beginInterruptedByTeardown, [
        .compensating(to: .idle), // .idle
        .compensating(to: .needsModel), // .needsModel
        .refused, // .starting — not interrupted: the session may come up
        .compensating(to: .running), // .running
        .compensating(to: .paused), // .paused
        .compensating(to: .sourceLost), // .sourceLost
        .compensating(to: .stopping), // .stopping
        .compensating(to: .failed("boom")) // .failed
    ]) + rows(for: .teardownCompleted, [
        .refused, // .idle
        .refused, // .needsModel
        .refused, // .starting
        .refused, // .running
        .refused, // .paused
        .refused, // .sourceLost
        .legal(to: .idle), // .stopping — the wind-back
        .refused // .failed
    ]) + rows(for: .beginFailed("boom"), [
        .refused, // .idle
        .refused, // .needsModel
        .legal(to: .failed("boom")), // .starting
        .refused, // .running
        .refused, // .paused
        .refused, // .sourceLost
        .refused, // .stopping
        .refused // .failed
    ]) + rows(for: .pauseRequested, [
        .refused, // .idle
        .refused, // .needsModel
        .refused, // .starting
        .legal(to: .paused), // .running
        .refused, // .paused
        .refused, // .sourceLost
        .refused, // .stopping
        .refused // .failed
    ]) + rows(for: .resumeRequested, [
        .refused, // .idle
        .refused, // .needsModel
        .refused, // .starting
        .refused, // .running
        .legal(to: .paused), // .paused
        .refused, // .sourceLost
        .refused, // .stopping
        .refused // .failed
    ]) + rows(for: .resumeSucceeded, [
        .refused, // .idle
        .refused, // .needsModel
        .refused, // .starting
        .refused, // .running
        .legal(to: .running), // .paused
        .refused, // .sourceLost
        .refused, // .stopping
        .refused // .failed
    ]) + rows(for: .resumeFailed("boom"), [
        .refused, // .idle
        .refused, // .needsModel
        .refused, // .starting
        .refused, // .running
        .legal(to: .sourceLost), // .paused
        .refused, // .sourceLost
        .refused, // .stopping
        .refused // .failed
    ]) + rows(for: .resumeAbandoned, [
        .legal(to: .idle), // .idle
        .legal(to: .needsModel), // .needsModel
        .legal(to: .starting), // .starting
        .legal(to: .running), // .running
        .legal(to: .paused), // .paused
        .legal(to: .sourceLost), // .sourceLost
        .legal(to: .stopping), // .stopping
        .legal(to: .failed("boom")) // .failed
    ]) + rows(for: .captureLost("stream died"), [
        .refused, // .idle
        .refused, // .needsModel
        .legal(to: .sourceLost), // .starting
        .legal(to: .sourceLost), // .running
        // .paused — the error is deferred for the resume path, no phase change
        .legal(to: .paused),
        .refused, // .sourceLost
        .refused, // .stopping
        .refused // .failed
    ]) + rows(for: .captureRestartRequested, [
        .refused, // .idle
        .refused, // .needsModel
        .refused, // .starting
        .refused, // .running
        .legal(to: .starting), // .paused
        .legal(to: .starting), // .sourceLost
        .refused, // .stopping
        .refused // .failed
    ]) + rows(for: .captureRestartSucceeded, [
        .refused, // .idle
        .refused, // .needsModel
        .legal(to: .running), // .starting
        .refused, // .running
        .refused, // .paused
        .refused, // .sourceLost
        .refused, // .stopping
        .refused // .failed
    ]) + rows(for: .captureRestartFailed("boom"), [
        .refused, // .idle
        .refused, // .needsModel
        .legal(to: .sourceLost), // .starting
        .refused, // .running
        .refused, // .paused
        .refused, // .sourceLost
        .refused, // .stopping
        .refused // .failed
    ]) + rows(for: .modelResolved(resolved: true), [
        .legal(to: .idle), // .idle
        .legal(to: .idle), // .needsModel
        .legal(to: .starting), // .starting
        .legal(to: .running), // .running
        .legal(to: .paused), // .paused
        .legal(to: .sourceLost), // .sourceLost
        .legal(to: .stopping), // .stopping
        .legal(to: .failed("boom")) // .failed
    ]) + rows(for: .modelResolved(resolved: false), [
        .legal(to: .needsModel), // .idle
        .legal(to: .needsModel), // .needsModel
        .legal(to: .starting), // .starting
        .legal(to: .running), // .running
        .legal(to: .paused), // .paused
        .legal(to: .sourceLost), // .sourceLost
        .legal(to: .stopping), // .stopping
        .legal(to: .failed("boom")) // .failed
    ]) + rows(for: .stopRequested, [
        .refused, // .idle
        .refused, // .needsModel
        .legal(to: .stopping), // .starting
        .legal(to: .stopping), // .running
        .legal(to: .stopping), // .paused
        .legal(to: .stopping), // .sourceLost
        .refused, // .stopping — double stop refused
        .refused // .failed
    ]) + rows(for: .stopCompleted, [
        // The production write is unconditional: the teardown always winds
        // the session back to `.idle`.
        .legal(to: .idle), // .idle
        .legal(to: .idle), // .needsModel
        .legal(to: .idle), // .starting
        .legal(to: .idle), // .running
        .legal(to: .idle), // .paused
        .legal(to: .idle), // .sourceLost
        .legal(to: .idle), // .stopping
        .legal(to: .idle) // .failed
    ]) + rows(for: .terminationStarted, [
        .legal(to: .idle), // .idle
        .legal(to: .needsModel), // .needsModel
        .legal(to: .stopping), // .starting
        .legal(to: .stopping), // .running
        .legal(to: .stopping), // .paused
        .legal(to: .stopping), // .sourceLost
        .legal(to: .stopping), // .stopping — a stop is staged
        .legal(to: .failed("boom")) // .failed
    ])
}
