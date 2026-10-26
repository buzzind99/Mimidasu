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
