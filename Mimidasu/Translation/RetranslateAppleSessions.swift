import Foundation
import Observation
import Translation

/// Outcome of resolving a lane or bulk-run engine. `.timedOut` and
/// `.cancelled` are distinct on purpose: the timeout reports a still-starting
/// session, while a cancellation is a user-initiated stop/teardown whose
/// toasts are already cleared, so reporting it would post a stray message.
enum LaneEngineResolution: Sendable {
    case ready(any TranslationEngine)
    case timedOut
    case cancelled
}

/// The lane's two dedicated Apple sessions behind one seam: per-kind arming,
/// the target-gated engine hand-over, the awaited wait for that hand-over,
/// and the invalidate-and-rebuild cycle a `.translationTask` host re-fires
/// on. One arm per Apple kind (fast model, Apple Intelligence) owns its
/// config, the target it was built for, and the session handed over by its
/// host.
@Observable
@MainActor
final class RetranslateAppleSessions {
    /// One armed session. `config` is nil until the first retry through the
    /// kind arms it; `target` records what the armed config pins; `engine`
    /// is the session its `.translationTask` host handed over.
    private struct Arm {
        var config: TranslationSession.Configuration?
        var target: String?
        var engine: (any TranslationEngine)?
    }

    /// A bound wait for a hand-over: the kind and target it was registered
    /// for, and the continuation to resume once the answer exists.
    private struct Waiter {
        let kind: TranslationEngineKind
        let target: String
        let laneOwned: Bool
        let continuation: CheckedContinuation<LaneEngineResolution, Never>
    }

    private var fastArm = Arm()
    private var hifiArm = Arm()

    @ObservationIgnored private var waiters: [Int: Waiter] = [:]
    @ObservationIgnored private var waiterTimeouts: [Int: Task<Void, Never>] = [:]
    @ObservationIgnored private var nextWaiterID = 0

    private let tierAvailability: AppleTierAvailability

    init(tierAvailability: AppleTierAvailability) {
        self.tierAvailability = tierAvailability
    }

    /// The fast-model session's config, read by its `.translationTask` host.
    var fastConfig: TranslationSession.Configuration? {
        fastArm.config
    }

    /// The Apple Intelligence session's config, read by its host.
    var hifiConfig: TranslationSession.Configuration? {
        hifiArm.config
    }

    /// ja→`target` configuration for one of the dedicated sessions. Mirrors
    /// the live session's config except the strategy, which is set
    /// EXPLICITLY above the strategy API: the property's default follows the
    /// SDK the app was built against, which would hand both lanes the same
    /// model as the live session and return byte-identical text, defeating
    /// the feature. Below the strategy API the config stays plain (the
    /// session is the fast model by definition).
    func makeConfig(highFidelity: Bool, target: String) -> TranslationSession.Configuration {
        var config = TranslationSession.Configuration(
            source: Locale.Language(identifier: "ja"),
            target: Locale.Language(identifier: target)
        )
        tierAvailability.applyPreferredStrategy(to: &config, highFidelity: highFidelity)
        return config
    }

    /// The target the kind's armed config pins, if any.
    func armedTarget(for kind: TranslationEngineKind) -> String? {
        arm(for: kind)?.target
    }

    /// The stored session for an Apple kind — target-gated, so an armed
    /// config rebuilt for another target never serves a wait for this one.
    func engine(for kind: TranslationEngineKind, target: String) -> (any TranslationEngine)? {
        guard let arm = arm(for: kind), arm.target == target else { return nil }
        return arm.engine
    }

    /// Arms the kind's dedicated session on the first retry through it.
    /// Never reassigns an armed config: reassignment is a path SwiftUI's
    /// `.translationTask` may not reliably re-fire on, and a timeout keeps
    /// the config armed so the next click is instant once the session (or
    /// its language-pack prompt) lands. An armed config pins its target, so
    /// a retry whose target differs rebuilds through the proven
    /// invalidate-and-reassign path. Arming also clears the stored engine:
    /// the wait that follows must be for this config's hand-over, never a
    /// stale engine an unknown path left behind.
    func arm(kind: TranslationEngineKind, target: String) {
        guard var arm = arm(for: kind) else { return }
        guard arm.config == nil || arm.target != target else { return }
        if arm.config != nil {
            invalidateStoredConfig(for: kind)
        }
        arm.engine = nil
        arm.config = makeConfig(highFidelity: kind == .appleHighFidelity, target: target)
        arm.target = target
        setArm(arm, for: kind)
    }

    /// Stores the session handed over by a `.translationTask` host and
    /// resumes the waits it answers. Gated on the kind having been armed at
    /// least once: a session for a lane that never armed must not be stored
    /// for the next lane to acquire instantly. An armed config rebuilt by a
    /// teardown accepts the late hand-over, but target-gated reads keep it
    /// from serving a wait registered for a different target.
    func retranslateSessionArrived(
        kind: TranslationEngineKind, engine: any TranslationEngine
    ) {
        guard var arm = arm(for: kind), arm.config != nil, let target = arm.target else {
            return
        }
        arm.engine = engine
        setArm(arm, for: kind)
        resumeWaiters(kind: kind, target: target, engine: engine)
    }

    /// Waits bounded for the kind's session to be handed over for `target`.
    /// Returns the stored engine immediately when one exists; otherwise
    /// registers a continuation that the hand-over, the timeout, or task
    /// cancellation resolves. The deadline is monotonic because the timeout
    /// runs on `ContinuousClock` through `Task.sleep(for:)`.
    func awaitEngine(
        for kind: TranslationEngineKind, target: String, timeout: Duration,
        laneOwned: Bool
    ) async -> LaneEngineResolution {
        if Task.isCancelled {
            return .cancelled
        }
        if let engine = engine(for: kind, target: target) {
            return .ready(engine)
        }
        let waiterID = nextWaiterID
        nextWaiterID += 1
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                // No suspension exists between the stored-engine check above
                // and this registration, so a hand-over cannot land in between.
                // A cancellation that is already pending runs its handler's
                // main-actor hop only after this synchronous body registers.
                waiters[waiterID] = Waiter(
                    kind: kind, target: target, laneOwned: laneOwned,
                    continuation: continuation
                )
                waiterTimeouts[waiterID] = Task { [weak self] in
                    guard let self else { return }
                    do {
                        try await Task.sleep(for: timeout)
                    } catch {
                        return
                    }
                    finishWaiter(waiterID, with: .timedOut)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finishWaiter(waiterID, with: .cancelled)
            }
        }
    }

    /// Cancels the hand-over waits a lane generation turn makes stale,
    /// leaving the bulk run's own resolution parked. Lane waiters are the
    /// per-row retries; only a teardown cancels the job's waiter too.
    func cancelLaneWaiters() {
        let matching = waiters.filter { entry in
            entry.value.laneOwned
        }.map(\.key)
        for waiterID in matching {
            finishWaiter(waiterID, with: .cancelled)
        }
    }

    /// Drops both armed-session states for a new lane generation. Armed
    /// configs are REBUILT, never nil-ed: a nil → fresh-equal-config
    /// transition is the path `.translationTask` does not reliably re-fire
    /// on, and the next retry through the kind would arm onto it while the
    /// host never fires. The rebuild preserves each config's target; a
    /// never-armed config stays nil (lazy arming preserved). Stored engines
    /// go with the old configs, and outstanding waits resolve as cancelled —
    /// no task can deliver past the generation boundary this marks.
    func teardown() {
        for waiterID in Array(waiters.keys) {
            finishWaiter(waiterID, with: .cancelled)
        }
        for kind in [TranslationEngineKind.appleFast, .appleHighFidelity] {
            guard var arm = arm(for: kind), arm.config != nil,
                  let target = arm.target
            else {
                continue
            }
            // Mutate the stored config (bumping its version) before the
            // reassignment, the same invalidate-then-reassign shape the live
            // session's refresh uses so the host re-fires.
            invalidateStoredConfig(for: kind)
            arm.config = makeConfig(
                highFidelity: kind == .appleHighFidelity, target: target
            )
            arm.engine = nil
            setArm(arm, for: kind)
        }
    }

    // MARK: - Wait bookkeeping

    private func arm(for kind: TranslationEngineKind) -> Arm? {
        switch kind {
        case .appleFast: fastArm
        case .appleHighFidelity: hifiArm
        default: nil
        }
    }

    /// Invalidates the kind's stored config in place so its version bumps
    /// before the fresh replacement is assigned.
    private func invalidateStoredConfig(for kind: TranslationEngineKind) {
        switch kind {
        case .appleFast: fastArm.config?.invalidate()
        case .appleHighFidelity: hifiArm.config?.invalidate()
        default: break
        }
    }

    private func setArm(_ arm: Arm, for kind: TranslationEngineKind) {
        switch kind {
        case .appleFast: fastArm = arm
        case .appleHighFidelity: hifiArm = arm
        default: break
        }
    }

    private func resumeWaiters(
        kind: TranslationEngineKind, target: String, engine: any TranslationEngine
    ) {
        let matching = waiters.filter { entry in
            entry.value.kind == kind && entry.value.target == target
        }.map(\.key)
        for waiterID in matching {
            finishWaiter(waiterID, with: .ready(engine))
        }
    }

    /// Resumes one waiter at most once. Everything here runs on the main
    /// actor, so removing the record before resuming is enough to make a
    /// late timeout or cancellation a no-op.
    private func finishWaiter(_ waiterID: Int, with resolution: LaneEngineResolution) {
        guard let waiter = waiters.removeValue(forKey: waiterID) else { return }
        waiterTimeouts.removeValue(forKey: waiterID)?.cancel()
        waiter.continuation.resume(returning: resolution)
    }
}
