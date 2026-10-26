import Foundation

/// A scheduled firing; cancelled via the closure `schedule` returns.
private final class ManualTimerToken: @unchecked Sendable {
    let fire: @MainActor () -> Void
    var cancelled = false

    init(fire: @escaping @MainActor () -> Void) {
        self.fire = fire
    }
}

/// Deterministic scheduler shared by the toast and notice centers: records
/// every scheduled firing with a cancellable token, so a test fires pending
/// dismissals instead of sleeping.
final class ManualScheduler: @unchecked Sendable {
    private let lock = NSLock()
    private var scheduled: [ManualTimerToken] = []

    var delays: [Duration] = []

    func schedule(
        _ delay: Duration, _ fire: @escaping @MainActor () -> Void
    ) -> @Sendable () -> Void {
        let token = ManualTimerToken(fire: fire)
        lock.lock()
        scheduled.append(token)
        delays.append(delay)
        lock.unlock()
        return { [weak self] in
            guard let self else { return }
            lock.lock()
            token.cancelled = true
            lock.unlock()
        }
    }

    /// Live (uncancelled) firings, in schedule order.
    private var live: [ManualTimerToken] {
        lock.withLock { scheduled.filter { token in !token.cancelled } }
    }

    var pendingCount: Int {
        live.count
    }

    /// Fires every live dismissal and forgets the schedule. MainActor: the
    /// stored `fire` closures are, and every caller (the tests) is too.
    @MainActor
    func firePending() {
        let tokens = live
        lock.withLock { scheduled.removeAll() }
        for token in tokens {
            token.fire()
        }
    }
}
