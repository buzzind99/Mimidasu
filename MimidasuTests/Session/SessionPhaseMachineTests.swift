@testable import Mimidasu
import Testing

/// The exhaustive transition table.
///
/// Every action × every phase is listed, with the expected category, the
/// expected resulting phase and the expected effects. The table IS the
/// specification: nothing else in the machine decides anything.
struct SessionPhaseMachineTests {

    // MARK: - Tests

    @Test("the transition table is exhaustive: every action × every phase")
    func tableIsExhaustive() {
        for row in SessionPhaseMachineTransitionTable.table {
            var machine = SessionPhaseMachine(phase: row.from)
            let transition = machine.reduce(row.action)

            #expect(
                machine.phase == row.to,
                "\(row.action) from \(row.from) must land on \(row.to), landed on \(machine.phase)"
            )
            #expect(
                transition.phase == row.to,
                "\(row.action) from \(row.from) must report \(row.to), reported \(transition.phase)"
            )
            #expect(
                transition.effects == row.effects,
                "\(row.action) from \(row.from) must emit \(row.effects), emitted \(transition.effects)"
            )
            #expect(
                SessionPhaseMachineTransitionTable.category(of: transition) == row.category,
                "\(row.action) from \(row.from) must be \(row.category.rawValue)"
            )
        }
    }

    @Test("the table covers every action × phase pair exactly once")
    func tableCoversEveryPair() {
        var seen: Set<String> = []
        for row in SessionPhaseMachineTransitionTable.table {
            let key = "\(row.action)|\(SessionPhaseMachineTransitionTable.canonicalPhases.firstIndex(of: row.from) ?? -1)"
            #expect(!seen.contains(key), "duplicate table entry for \(key)")
            seen.insert(key)
        }

        #expect(seen.count == SessionPhaseMachineTransitionTable.table.count)
        // 19 actions, but `modelResolved` is exercised with both payloads.
        let actionVariants: Set<String> = Set(SessionPhaseMachineTransitionTable.table.map { row in "\(row.action)" })
        #expect(actionVariants.count == 20, "20 rows: 19 actions, `modelResolved` twice")
        #expect(SessionPhaseMachineTransitionTable.table.count == 20 * SessionPhaseMachineTransitionTable.canonicalPhases.count)
    }

    /// A legal transition never owes a teardown: the teardown is what makes
    /// a transition *compensating*, and the category decides.
    @Test("no legal transition carries the compensating teardown effect")
    func legalTransitionsNeverTearDown() {
        for row in SessionPhaseMachineTransitionTable.table where row.category == .legal {
            #expect(
                !row.effects.contains(.tearDownSession),
                "\(row.action) from \(row.from) is legal and must not tear down"
            )
        }
    }

    // MARK: - Compensating transitions

    /// The compensating transitions, spelled out one by one.
    ///
    /// Every one of them is an *illegal* action: the phase must not be
    /// brought up by it, and a compensating effect must still be emitted so
    /// the engine a raced teardown left behind does not survive.
    @Test(
        "compensation: beginSucceeded after a teardown tears down and never comes up",
        arguments: [
            SessionPhase.idle,
            .needsModel,
            .running,
            .paused,
            .sourceLost,
            .failed("boom")
        ]
    )
    func beginSucceededAfterTeardownCompensates(from: SessionPhase) {
        var machine = SessionPhaseMachine(phase: from)
        let transition = machine.reduce(.beginSucceeded)

        #expect(machine.phase == from, "the phase must not move")
        #expect(transition.effects == [.tearDownSession], "the engine must still be torn down")
        #expect(SessionPhaseMachineTransitionTable.category(of: transition) == .compensating)
    }

    @Test("compensation: beginSucceeded while stopping tears down and leaves the wind-back alone")
    func beginSucceededWhileStoppingCompensates() {
        var machine = SessionPhaseMachine(phase: .stopping)
        let transition = machine.reduce(.beginSucceeded)

        #expect(
            machine.phase == .stopping,
            "the wind-back lands after the teardown, not before it"
        )
        #expect(transition.effects == [.tearDownSession])
        #expect(SessionPhaseMachineTransitionTable.category(of: transition) == .compensating)
    }

    @Test(
        "the teardown always winds the phase back to idle (production's unconditional write)",
        arguments: SessionPhaseFixtures.all
    )
    func stopCompletionAlwaysWindsBack(from: SessionPhase) {
        var machine = SessionPhaseMachine(phase: from)
        let transition = machine.reduce(.stopCompleted)

        #expect(machine.phase == .idle)
        #expect(transition.effects == SessionPhaseMachineTransitionTable.stopCompletionBundle)
        #expect(SessionPhaseMachineTransitionTable.category(of: transition) == .legal)
    }

    // MARK: - Refusals

    @Test("a late begin failure is dropped: it must not resurrect `.failed`")
    func lateBeginFailureIsDropped() {
        var machine = SessionPhaseMachine(phase: .stopping)
        let transition = machine.reduce(.beginFailed("boom"))

        #expect(machine.phase == .stopping)
        #expect(
            transition.effects.isEmpty,
            "a dropped failure must not repost over the cleared toast stack"
        )
        #expect(SessionPhaseMachineTransitionTable.category(of: transition) == .refused)
    }

    @Test("a double stop is refused")
    func doubleStopIsRefused() {
        var machine = SessionPhaseMachine(phase: .stopping)
        let transition = machine.reduce(.stopRequested)

        #expect(machine.phase == .stopping)
        #expect(transition.effects.isEmpty)
        #expect(SessionPhaseMachineTransitionTable.category(of: transition) == .refused)
    }

    @Test("an interrupted bring-up is refused while the phase is still `.starting`")
    func interruptedBringUpIsRefusedWhileStarting() {
        var machine = SessionPhaseMachine(phase: .starting)
        let transition = machine.reduce(.beginInterruptedByTeardown)

        #expect(machine.phase == .starting, "the session may still come up")
        #expect(transition.effects.isEmpty, "nothing to tear down yet")
        #expect(SessionPhaseMachineTransitionTable.category(of: transition) == .refused)
    }

    // MARK: - Derived predicates

    @Test("isLive is the 3-case predicate")
    func isLiveIsThreeCase() {
        for phase in SessionPhaseFixtures.all {
            let machine = SessionPhaseMachine(phase: phase)
            let expected = phase == .running || phase == .sourceLost || phase == .paused
            #expect(machine.isLive == expected, "\(phase)")
            #expect(SessionPhaseMachine.isLive(phase) == expected, "\(phase)")
        }
    }

    @Test("isLiveOrStarting is the 4-case predicate")
    func isLiveOrStartingIsFourCase() {
        for phase in SessionPhaseFixtures.all {
            let machine = SessionPhaseMachine(phase: phase)
            let expected = phase == .running || phase == .sourceLost || phase == .paused
                || phase == .starting
            #expect(machine.isLiveOrStarting == expected, "\(phase)")
            #expect(SessionPhaseMachine.isLiveOrStarting(phase) == expected, "\(phase)")
        }
    }

    @Test("isLiveOrStopping is the 5-case predicate")
    func isLiveOrStoppingIsFiveCase() {
        for phase in SessionPhaseFixtures.all {
            let machine = SessionPhaseMachine(phase: phase)
            let expected = phase == .running || phase == .sourceLost || phase == .paused
                || phase == .starting || phase == .stopping
            #expect(machine.isLiveOrStopping == expected, "\(phase)")
            #expect(SessionPhaseMachine.isLiveOrStopping(phase) == expected, "\(phase)")
        }
    }

    @Test("the 4-case predicate is strictly wider than the 3-case one")
    func livePredicatesDiffer() {
        let machine = SessionPhaseMachine(phase: .starting)
        #expect(!machine.isLive)
        #expect(machine.isLiveOrStarting)
    }

    @Test("the 5-case predicate is strictly wider than the 4-case one")
    func liveOrStoppingIsWider() {
        let machine = SessionPhaseMachine(phase: .stopping)
        #expect(!machine.isLiveOrStarting)
        #expect(machine.isLiveOrStopping)
    }
}

/// Every case of the session-phase enum, with a representative payload for
/// `.failed`.
///
/// The enum lives in the app target and is internal, so the test target
/// spells the case list out here. The list is checked against the canonical
/// order the transition table is written in.
enum SessionPhaseFixtures {
    static let all: [SessionPhase] = [
        .needsModel,
        .idle,
        .starting,
        .running,
        .paused,
        .sourceLost,
        .stopping,
        .failed("boom")
    ]
}
