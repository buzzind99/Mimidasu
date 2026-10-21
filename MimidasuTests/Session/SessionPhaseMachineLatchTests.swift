@testable import Mimidasu
import Testing

/// The machine's internal latches, its test seam, and the effect ordering
/// the quit-time teardown depends on.
///
/// The latches are the resume double-click guard and the quit-time teardown
/// latch moved into the machine. They are machine state, never new session
/// phases.
struct SessionPhaseMachineLatchTests {

    // MARK: - The resume latch

    @Test("resumeRequested arms the resuming latch and leaves the phase `.paused`")
    func resumeRequestedArmsLatch() {
        var machine = SessionPhaseMachine(phase: .paused)
        let transition = machine.reduce(.resumeRequested)

        #expect(machine.phase == .paused, "the phase stays `.paused` until the IOProc is back")
        #expect(machine.isResuming)
        #expect(transition.effects == [.resumeCapture])
    }

    @Test("a second resumeRequested is refused while the latch is set")
    func secondResumeIsRefused() {
        var machine = SessionPhaseMachine(phase: .paused)
        _ = machine.reduce(.resumeRequested)
        let transition = machine.reduce(.resumeRequested)

        #expect(machine.phase == .paused)
        #expect(transition.effects.isEmpty, "the double-click guard must hold")
    }

    @Test("the resuming latch clears when the resume succeeds")
    func resumeSucceededClearsLatch() {
        var machine = SessionPhaseMachine(phase: .paused)
        _ = machine.reduce(.resumeRequested)
        _ = machine.reduce(.resumeSucceeded)

        #expect(machine.phase == .running)
        #expect(!machine.isResuming)
    }

    @Test("the resuming latch clears when the resume fails")
    func resumeFailedClearsLatch() {
        var machine = SessionPhaseMachine(phase: .paused)
        _ = machine.reduce(.resumeRequested)
        _ = machine.reduce(.resumeFailed("boom"))

        #expect(machine.phase == .sourceLost)
        #expect(!machine.isResuming)
    }

    @Test("the resuming latch clears when the resume is abandoned")
    func resumeAbandonedClearsLatch() {
        var machine = SessionPhaseMachine(phase: .paused)
        _ = machine.reduce(.resumeRequested)
        let transition = machine.reduce(.resumeAbandoned)

        #expect(machine.phase == .paused)
        #expect(!machine.isResuming)
        #expect(transition.effects.isEmpty)
    }

    @Test("leaving `.paused` clears the resuming latch")
    func leavingPausedClearsLatch() {
        var machine = SessionPhaseMachine(phase: .paused)
        _ = machine.reduce(.resumeRequested)
        _ = machine.reduce(.stopRequested)

        #expect(machine.phase == .stopping)
        #expect(!machine.isResuming, "a stop ends the airborne resume")
    }

    // MARK: - The phase write

    @Test("a phase write that leaves `.paused` clears the resuming latch")
    func phaseWriteLeavingPausedClearsLatch() {
        var machine = SessionPhaseMachine(phase: .paused)
        _ = machine.reduce(.resumeRequested)

        machine.setPhase(.running)

        #expect(machine.phase == .running)
        #expect(!machine.isResuming, "the latch describes the phase, and the phase moved")
    }

    @Test("a phase write that stays `.paused` keeps the resuming latch")
    func phaseWriteStayingPausedKeepsLatch() {
        var machine = SessionPhaseMachine(phase: .paused)
        _ = machine.reduce(.resumeRequested)

        machine.setPhase(.paused)

        #expect(machine.isResuming, "a resume is still airborne while the session is paused")
    }

    @Test("a phase write never revokes the quit-time latch")
    func phaseWriteKeepsTheTerminatingLatch() {
        var machine = SessionPhaseMachine(phase: .running)
        _ = machine.reduce(.terminationStarted)

        machine.setPhase(.idle)
        machine.setPhase(.running)

        #expect(machine.isTerminating, "only the teardown may clear the quit-time latch")
    }

    @Test("the test seam is the only way to revoke the quit-time latch")
    func seamRevokesTheTerminatingLatch() {
        var machine = SessionPhaseMachine(phase: .running)
        _ = machine.reduce(.terminationStarted)

        machine.setPhaseForTesting(.idle)

        #expect(!machine.isTerminating, "the seam resets both latches")
    }

    // MARK: - The termination latch

    @Test("terminationStarted latches the terminating flag")
    func terminationLatches() {
        var machine = SessionPhaseMachine(phase: .running)
        _ = machine.reduce(.terminationStarted)

        #expect(machine.isTerminating)
    }

    @Test("a second terminationStarted is refused (the re-entrancy latch)")
    func secondTerminationIsRefused() {
        var machine = SessionPhaseMachine(phase: .running)
        _ = machine.reduce(.terminationStarted)
        let transition = machine.reduce(.terminationStarted)

        #expect(transition.effects.isEmpty, "quit-time teardown is single-shot")
    }

    @Test("startRequested is refused once the terminating latch is set")
    func startRefusedAfterTermination() {
        var machine = SessionPhaseMachine(phase: .idle)
        _ = machine.reduce(.terminationStarted)
        let transition = machine.reduce(.startRequested)

        #expect(machine.phase == .idle, "a terminating model never begins a new session")
        #expect(transition.effects.isEmpty)
    }

    @Test("the terminating latch survives a phase change")
    func terminatingLatchSurvivesPhaseChange() {
        var machine = SessionPhaseMachine(phase: .running)
        _ = machine.reduce(.terminationStarted)
        _ = machine.reduce(.stopCompleted)

        #expect(machine.phase == .idle)
        #expect(machine.isTerminating, "the latch is not a phase")
    }

    // MARK: - Effect ordering

    @Test("the staged stop is awaited before the warm engine is retired")
    func stagedStopIsAwaitedBeforeRetiring() throws {
        var machine = SessionPhaseMachine(phase: .stopping)
        let effects = machine.reduce(.terminationStarted).effects

        let awaited = try #require(effects.firstIndex(of: .awaitStagedStop))
        let retired = try #require(effects.firstIndex(of: .retireWarmEngine))
        #expect(
            awaited < retired,
            "the staged stop must land before the engine is retired: \(effects)"
        )
    }

    @Test("the live teardown finalizes the session before the engine is retired")
    func liveTeardownFinalizesBeforeRetiring() throws {
        for phase in [SessionPhase.starting, .running, .paused, .sourceLost] {
            var machine = SessionPhaseMachine(phase: phase)
            let effects = machine.reduce(.terminationStarted).effects

            let finalized = try #require(effects.firstIndex(of: .finalizeLiveSession))
            let retired = try #require(effects.firstIndex(of: .retireWarmEngine))
            #expect(
                finalized < retired,
                "the session must be finalized before the engine is retired: \(effects)"
            )
        }
    }

    // MARK: - The test seam

    @Test("setPhaseForTesting forces the phase")
    func seamForcesPhase() {
        var machine = SessionPhaseMachine(phase: .idle)
        machine.setPhaseForTesting(.running)

        #expect(machine.phase == .running)
    }

    @Test("setPhaseForTesting resets both internal latches")
    func seamResetsLatches() {
        var machine = SessionPhaseMachine(phase: .paused)
        _ = machine.reduce(.resumeRequested)
        #expect(machine.isResuming)

        machine.setPhaseForTesting(.paused)
        #expect(!machine.isResuming, "the resuming latch must not survive the seam")

        var terminating = SessionPhaseMachine(phase: .running)
        _ = terminating.reduce(.terminationStarted)
        #expect(terminating.isTerminating)

        terminating.setPhaseForTesting(.idle)
        #expect(!terminating.isTerminating, "the terminating latch must not survive the seam")
    }

    @Test("a phase forced through the seam is still resumable")
    func forcedPausedIsResumable() {
        var machine = SessionPhaseMachine(phase: .idle)
        machine.setPhaseForTesting(.paused)

        let transition = machine.reduce(.resumeRequested)
        #expect(machine.isResuming, "the seam must not leave the resume guard closed")
        #expect(transition.effects == [.resumeCapture])
    }

    @Test("a phase forced through the seam is still startable")
    func forcedIdleIsStartable() {
        var machine = SessionPhaseMachine(phase: .running)
        machine.setPhaseForTesting(.idle)

        let transition = machine.reduce(.startRequested)
        #expect(machine.phase == .starting)
        #expect(transition.effects == [.awaitDictionary, .beginSession])
    }
}
