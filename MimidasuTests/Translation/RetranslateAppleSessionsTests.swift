import Foundation
@testable import Mimidasu
import Testing

/// Drives the lane's dedicated-session module directly: arming and its
/// target rebuild rule, the target-gated engine hand-over, the awaited
/// hand-over's ready/timeout/cancellation outcomes, and the teardown that
/// rebuilds armed configs and drops their engines.
@MainActor
@Suite("RetranslateAppleSessions")
struct RetranslateAppleSessionsTests {

    private func makeSUT() -> RetranslateAppleSessions {
        RetranslateAppleSessions(tierAvailability: AppleTierAvailability())
    }

    private func armReady(
        _ sut: RetranslateAppleSessions, kind: TranslationEngineKind = .appleFast,
        target: String = "en"
    ) {
        sut.arm(kind: kind, target: target)
        sut.retranslateSessionArrived(kind: kind, engine: LaneEchoEngine())
    }

    @Test("arming is lazy and keeps an already-armed config for the same target")
    func armKeepsConfig() {
        let sut = makeSUT()
        #expect(sut.fastConfig == nil)

        sut.arm(kind: .appleFast, target: "en")
        let armed = sut.fastConfig
        #expect(armed != nil)

        sut.arm(kind: .appleFast, target: "en")

        #expect(sut.fastConfig == armed, "a reassignment would gamble on a .translationTask re-fire")
    }

    @Test("a target change invalidates and rebuilds the armed config")
    func armRebuildsForNewTarget() {
        let sut = makeSUT()
        sut.arm(kind: .appleFast, target: "en")
        let armed = sut.fastConfig

        sut.arm(kind: .appleFast, target: "fr")

        #expect(sut.armedTarget(for: .appleFast) == "fr")
        #expect(sut.fastConfig != armed, "the config pins its target and must be rebuilt")
    }

    @Test("arming a non-Apple kind arms nothing")
    func armExternalKindArmsNothing() {
        let sut = makeSUT()

        sut.arm(kind: .google, target: "en")

        #expect(sut.fastConfig == nil)
        #expect(sut.hifiConfig == nil)
        #expect(sut.engine(for: .google, target: "en") == nil)
    }

    @Test("the stored engine is target-gated and per-kind")
    func storedEngineIsTargetGated() {
        let sut = makeSUT()
        armReady(sut, kind: .appleHighFidelity, target: "fr")

        #expect(sut.engine(for: .appleHighFidelity, target: "fr") != nil)
        #expect(sut.engine(for: .appleHighFidelity, target: "de") == nil)
        #expect(sut.engine(for: .appleFast, target: "fr") == nil)
    }

    @Test("a hand-over built for a superseded target is refused")
    func foreignTargetHandoverRefused() {
        let sut = makeSUT()
        sut.arm(kind: .appleFast, target: "fr")

        sut.retranslateSessionArrived(
            kind: .appleFast, engine: LaneEchoEngine(),
            targetLanguage: Locale.Language(identifier: "de")
        )
        #expect(
            sut.engine(for: .appleFast, target: "fr") == nil,
            "a session pinned to another target must not serve the armed arm"
        )

        sut.retranslateSessionArrived(
            kind: .appleFast, engine: LaneEchoEngine(),
            targetLanguage: Locale.Language(identifier: "fr")
        )
        #expect(sut.engine(for: .appleFast, target: "fr") != nil)
    }

    @Test("a hand-over for an unarmed session is refused")
    func unarmedHandoverRefused() {
        let sut = makeSUT()

        sut.retranslateSessionArrived(kind: .appleFast, engine: LaneEchoEngine())

        #expect(sut.engine(for: .appleFast, target: "en") == nil)
    }

    @Test("waiting for a stored engine resolves immediately")
    func waitResolvesImmediately() async {
        let sut = makeSUT()
        armReady(sut)

        switch await sut.awaitEngine(for: .appleFast, target: "en", timeout: .seconds(1), laneOwned: true) {
        case .ready:
            break
        case .timedOut, .cancelled:
            Issue.record("a stored engine must resolve without waiting")
        }
    }

    @Test("waiting resolves when the hand-over lands")
    func waitResolvesOnHandover() async {
        let sut = makeSUT()
        sut.arm(kind: .appleFast, target: "en")
        let wait = Task {
            await sut.awaitEngine(for: .appleFast, target: "en", timeout: .seconds(5), laneOwned: true)
        }
        try? await Task.sleep(for: .milliseconds(50))

        sut.retranslateSessionArrived(kind: .appleFast, engine: LaneEchoEngine())

        switch await wait.value {
        case .ready:
            break
        case .timedOut, .cancelled:
            Issue.record("the hand-over must resolve the parked wait")
        }
    }

    @Test("waiting times out when no hand-over arrives")
    func waitTimesOut() async {
        let sut = makeSUT()
        sut.arm(kind: .appleFast, target: "en")

        switch await sut.awaitEngine(for: .appleFast, target: "en", timeout: .milliseconds(50), laneOwned: true) {
        case .timedOut:
            break
        case .ready, .cancelled:
            Issue.record("an absent hand-over must time out")
        }
    }

    @Test("cancelling the waiting task reports cancellation")
    func waitIsCancelled() async {
        let sut = makeSUT()
        sut.arm(kind: .appleFast, target: "en")
        let wait = Task {
            await sut.awaitEngine(for: .appleFast, target: "en", timeout: .seconds(10), laneOwned: true)
        }
        try? await Task.sleep(for: .milliseconds(50))

        wait.cancel()

        switch await wait.value {
        case .cancelled:
            break
        case .ready, .timedOut:
            Issue.record("task cancellation must win over the timeout")
        }
    }

    @Test("teardown rebuilds armed configs and drops their engines")
    func teardownRebuildsArmedSessions() {
        let sut = makeSUT()
        sut.arm(kind: .appleFast, target: "en")
        sut.arm(kind: .appleHighFidelity, target: "en")
        sut.retranslateSessionArrived(kind: .appleFast, engine: LaneEchoEngine())
        sut.retranslateSessionArrived(kind: .appleHighFidelity, engine: LaneEchoEngine())

        sut.teardown()

        #expect(sut.fastConfig != nil, "an armed config is rebuilt, never nil-ed")
        #expect(sut.hifiConfig != nil)
        #expect(sut.engine(for: .appleFast, target: "en") == nil)
        #expect(sut.engine(for: .appleHighFidelity, target: "en") == nil)
    }

    @Test("teardown leaves a never-armed kind nil")
    func teardownKeepsUnarmedKindLazy() {
        let sut = makeSUT()

        sut.teardown()

        #expect(sut.fastConfig == nil)
        #expect(sut.hifiConfig == nil)
    }

    @Test("teardown resolves a parked wait as cancelled")
    func teardownCancelsWait() async {
        let sut = makeSUT()
        sut.arm(kind: .appleFast, target: "en")
        let wait = Task {
            await sut.awaitEngine(for: .appleFast, target: "en", timeout: .seconds(10), laneOwned: true)
        }
        try? await Task.sleep(for: .milliseconds(50))

        sut.teardown()

        switch await wait.value {
        case .cancelled:
            break
        case .ready, .timedOut:
            Issue.record("a generation boundary must abandon the wait")
        }
    }

    @Test("an already-cancelled task reports cancellation without registering")
    func waitInCancelledTask() async {
        let sut = makeSUT()
        sut.arm(kind: .appleFast, target: "en")

        let result = await Task {
            withUnsafeCurrentTask { current in current?.cancel() }
            return await sut.awaitEngine(for: .appleFast, target: "en", timeout: .seconds(10), laneOwned: true)
        }.value

        switch result {
        case .cancelled:
            break
        case .ready, .timedOut:
            Issue.record("a cancelled task must not wait for a hand-over")
        }
    }

    @Test("a lane-generation cancel leaves a bulk-run wait parked")
    func laneCancelLeavesJobWait() async {
        let sut = makeSUT()
        sut.arm(kind: .appleFast, target: "en")
        let laneWait = Task {
            await sut.awaitEngine(
                for: .appleFast, target: "en", timeout: .seconds(5), laneOwned: true
            )
        }
        let jobWait = Task {
            await sut.awaitEngine(
                for: .appleFast, target: "en", timeout: .seconds(5), laneOwned: false
            )
        }
        try? await Task.sleep(for: .milliseconds(50))

        sut.cancelLaneWaiters()

        switch await laneWait.value {
        case .cancelled:
            break
        case .ready, .timedOut:
            Issue.record("the lane wait must be abandoned")
        }
        sut.retranslateSessionArrived(kind: .appleFast, engine: LaneEchoEngine())
        switch await jobWait.value {
        case .ready:
            break
        case .timedOut, .cancelled:
            Issue.record("the bulk-run wait must survive a lane-generation cancel")
        }
    }
}
