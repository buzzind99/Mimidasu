@testable import Mimidasu
import Testing

/// The machine's internal latches and its test seam.
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
        #expect(transition.isLegal)
        #expect(transition.phase == .paused)
    }

    @Test("a second resumeRequested is refused while the latch is set")
    func secondResumeIsRefused() {
        var machine = SessionPhaseMachine(phase: .paused)
        _ = machine.reduce(.resumeRequested)
        let transition = machine.reduce(.resumeRequested)

        #expect(machine.phase == .paused)
        #expect(!transition.isLegal, "the double-click guard must hold")
    }

    @Test("the resuming latch clears when the resume settles", arguments: [
        (SessionAction.resumeSucceeded, SessionPhase.running),
        (.resumeFailed("boom"), .sourceLost),
        (.resumeAbandoned, .paused)
    ])
    func resumeSettleClearsLatch(
        action: SessionAction, expectedPhase: SessionPhase
    ) {
        var machine = SessionPhaseMachine(phase: .paused)
        _ = machine.reduce(.resumeRequested)

        let transition = machine.reduce(action)

        #expect(machine.phase == expectedPhase)
        #expect(!machine.isResuming)
        #expect(transition.isLegal)
        #expect(transition.phase == expectedPhase)
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

        #expect(!transition.isLegal, "quit-time teardown is single-shot")
    }

    @Test("startRequested is refused once the terminating latch is set")
    func startRefusedAfterTermination() {
        var machine = SessionPhaseMachine(phase: .idle)
        _ = machine.reduce(.terminationStarted)
        let transition = machine.reduce(.startRequested)

        #expect(machine.phase == .idle, "a terminating model never begins a new session")
        #expect(!transition.isLegal)
    }

    @Test("the terminating latch survives a phase change")
    func terminatingLatchSurvivesPhaseChange() {
        var machine = SessionPhaseMachine(phase: .running)
        _ = machine.reduce(.terminationStarted)
        _ = machine.reduce(.stopCompleted)

        #expect(machine.phase == .idle)
        #expect(machine.isTerminating, "the latch is not a phase")
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
        #expect(transition.isLegal)
        #expect(transition.phase == .paused)
    }

    @Test("a phase forced through the seam is still startable")
    func forcedIdleIsStartable() {
        var machine = SessionPhaseMachine(phase: .running)
        machine.setPhaseForTesting(.idle)

        let transition = machine.reduce(.startRequested)
        #expect(machine.phase == .starting)
        #expect(transition.isLegal)
        #expect(transition.phase == .starting)
    }
}
