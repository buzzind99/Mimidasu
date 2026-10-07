import Foundation

/// Session-stop and quit-time teardown surface of `AppModel` (file split for
/// the lint gate): stopping a live session and releasing the warm ASR engine.
extension AppModel {
    func stop() {
        // `.starting` is stoppable too: begin() is a multi-await operation
        // (TCC prompt, capture, engine), and a session the user cancels
        // mid-start must never come up afterwards.
        guard phase == .starting || phase == .running || phase == .sourceLost else { return }
        phase = .stopping

        stopTask = Task { @MainActor in
            await performStop()
            stopTask = nil
        }
    }

    /// Teardown via `SessionController` (capture, ASR, buffering, timers),
    /// after which the translation queue has drained and the session winds
    /// down. That keeps the tail of the session exportable with translations
    /// intact.
    ///
    /// The translation config is deliberately left alive: once drained, the
    /// worker is suspended harmlessly, and keeping the config non-nil lets
    /// `beginSession` restart via the reliable invalidate + reassign path
    /// (same as `retryTranslation`). Nil-ing here and reassigning an
    /// identical config on start is a path SwiftUI's `.translationTask`
    /// does not reliably re-fire on. Internal: driven by `stop()` and from
    /// the quit-time teardown below.
    func performStop() async {
        await sessionController.stop()
        // The external worker parks in the queue's wake loop after draining;
        // once `sessionController.stop()` has drained (translations intact),
        // tear it down. Apple runs are owned by SwiftUI and stay parked.
        translationWorker?.cancel()
        translationWorker = nil
        // Teardown supersedes any airborne high-fidelity probe: a landing
        // must not mark a session that no longer exists.
        highFidelitySequence += 1
        translationStatus = .idle
        // The transcript stays on screen after a stop, so a row waiting on a
        // re-translation would sit dimmed with its button disabled. Nothing
        // will deliver that result any more; drop the cue.
        pendingRetranslations.removeAll()
        // The lane task is cancelled (its post-await phase guard drops any
        // late result), the armed fast-session state goes with the session —
        // a next session on an external provider never takes the Apple
        // branch, so a config armed for a prior target must not survive —
        // and the lane-owned markers join the queue's clear. The teardown's
        // epoch bump retires stragglers: cancelling reaches only the newest
        // chained link, earlier lane tasks keep running to completion, and
        // without it they would pass the phase guard in the NEXT session
        // (indexes restart at 0) and swap an unrelated row's translation.
        retranslateLaneTask?.cancel()
        retranslateLaneTask = nil
        lanePendingRetranslations.removeAll()
        teardownRetranslateSession()
        sessionEndedAt = .now
        // Stop/teardown clears all toasts and notices (phase → `.idle`).
        toasts.clearAll()
        notices.dismiss()
        phase = .idle
    }

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
