import Foundation

/// Quit-time teardown surface of `AppModel` (file split for the lint gate):
/// winding a live session down and releasing the warm ASR engine before the
/// process exits.
extension AppModel {
    /// Quit-time teardown, invoked via `.mimidasuAppWillTerminate` (posted by
    /// `AppDelegate.applicationShouldTerminate`, which returns
    /// `.terminateLater` and waits for `.mimidasuTerminationTeardownComplete`).
    ///
    /// Winds a live session down exactly like a manual stop — flush decode +
    /// translation tail stay exportable — then permanently releases the
    /// process-warm ASR engine so the C library frees its session (and its
    /// Metal contexts) before the process exits instead of leaving them alive
    /// at device teardown. Completes with the teardown-complete notification
    /// in all paths, including an idle model (the warm engine can exist with
    /// no session ever started), latching `isTerminating` first.
    func shutdownForTermination() async {
        isTerminating = true
        if let stopTask {
            await stopTask.value
        } else if phase == .starting || phase == .running || phase == .stopping || phase == .sourceLost {
            phase = .stopping
            await performStop()
        }
        retireWarmEngine()
        NotificationCenter.default.post(name: .mimidasuTerminationTeardownComplete, object: nil)
    }
}
