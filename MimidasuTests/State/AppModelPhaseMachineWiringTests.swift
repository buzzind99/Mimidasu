import Foundation
@testable import Mimidasu
import Testing

/// `AppModel`'s wiring to the session-phase machine.
///
/// The model no longer owns the phase: the machine does, and the model's
/// `phase` is a view of it. These tests pin that wiring — the model and the
/// machine never diverge, the test seam clears the machine's latches, and the
/// latches that used to live on the model now guard the start and the
/// resume.
@MainActor
@Suite("AppModel phase-machine wiring")
struct AppModelPhaseMachineWiringTests {

    /// A thread-safe one-shot flag: the observation callback runs outside
    /// the test's actor.
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false

        var isSet: Bool {
            lock.withLock { value }
        }

        func set() {
            lock.withLock { value = true }
        }
    }

    private func makeModel() async -> AppModel {
        let model = AppModel(
            translationSettings: isolatedTranslationSettings(suite: "test.AppModelPhaseMachineWiring"),
            asrModelSettings: isolatedASRModelSettings(suite: "test.AppModelPhaseMachineWiring"),
            favorites: isolatedFavorites(),
            archive: isolatedArchive(),
            initialModelResolve: { _ in nil }
        )
        await model.initialModelCheck?.value
        return model
    }

    @Test("a phase write reaches the machine")
    func phaseWriteReachesTheMachine() async {
        let model = await makeModel()
        model.phase = .running

        #expect(model.phaseMachine.phase == .running)
    }

    @Test("a production stop drives the machine through the teardown")
    func stopDrivesTheMachine() async {
        let model = await makeModel()
        model.phase = .running

        model.stop()

        #expect(model.phase == .stopping)
        #expect(model.phaseMachine.phase == .stopping)
        #expect(await pollUntil { model.phase == .idle }, "stop winds down to idle")
        #expect(model.phaseMachine.phase == .idle)
    }

    @Test("the test seam clears the machine's resume latch")
    func seamClearsTheResumeLatch() async {
        let model = await makeModel()
        model.phase = .paused
        #expect(model.reducePhase(.resumeRequested).isLegal)
        #expect(model.phaseMachine.isResuming, "the resume latch is armed")

        model.forcePhaseForTesting(.paused)
        #expect(!model.phaseMachine.isResuming, "the seam must not leave the resume guard closed")
    }

    @Test("a phase write never disarms the quit-time teardown")
    func phaseWriteKeepsTheTerminatingLatch() async {
        let model = await makeModel()
        #expect(model.reducePhase(.terminationStarted).isLegal)
        #expect(model.phaseMachine.isTerminating)

        model.phase = .running

        #expect(
            model.phaseMachine.isTerminating,
            "a phase write may not revoke the quit-time latch"
        )
        #expect(
            !model.reducePhase(.startRequested).isLegal,
            "a terminating app never begins a new session"
        )
    }

    @Test("the terminating latch refuses a new session")
    func terminatingLatchRefusesStart() async {
        let model = await makeModel()
        #expect(model.reducePhase(.terminationStarted).isLegal)
        #expect(model.phaseMachine.isTerminating)

        #expect(
            !model.reducePhase(.startRequested).isLegal,
            "a terminating app never begins a new session"
        )
    }

    @Test("a phase change notifies observers — the views that read the phase still re-render")
    func phaseChangeNotifiesObservers() async {
        let model = await makeModel()
        let observed = Flag()
        withObservationTracking {
            _ = model.phase
        } onChange: {
            observed.set()
        }

        model.phase = .running

        #expect(
            observed.isSet,
            "the machine's phase change must invalidate the views that read it"
        )
    }
}
