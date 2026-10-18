import Foundation

/// Session-stop and quit-time teardown surface of `AppModel` (file split for
/// the lint gate): stopping a live session and releasing the warm ASR engine.
extension AppModel {
    func stop() {
        // `.starting` is stoppable too: begin() is a multi-await operation
        // (TCC prompt, capture, engine), and a session the user cancels
        // mid-start must never come up afterwards. `.paused` is live: stop
        // from paused finalizes normally.
        guard phase == .starting || phase == .running || phase == .paused || phase == .sourceLost
        else { return }
        phase = .stopping

        stopTask = Task { @MainActor in
            await performStop()
            stopTask = nil
        }
    }

    /// Whether pressing Stop must ask first: a non-empty transcript in a
    /// live-ish phase with a store that can actually persist the result.
    /// Empty sessions, cancel-during-start, and an unavailable store stop
    /// directly; the quit path never prompts at all. The window presents the
    /// alert — this is the policy it branches on.
    var shouldConfirmStop: Bool {
        guard !entries.isEmpty, archiveAvailable else { return false }
        switch phase {
        case .running, .paused, .sourceLost: return true
        case .needsModel, .idle, .starting, .stopping, .failed: return false
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
        // End order is live-then-lane (begin order in `wireSessionController`
        // is lane-then-live). The halves are independent — worker/sequence/
        // status reset vs marker-clear/teardown-rebuild — so the swap is
        // harmless. `sessionDidEnd` is not config-idempotent: `teardown`
        // rebuilds armed configs on every call, but a double `performStop`
        // is unreachable (`stop` guards on the live phases, and
        // `shutdownForTermination` awaits the in-flight `stopTask` — or, for
        // its own branch, is latched by `isTerminating`).
        // The external worker parks in the queue's wake loop after draining;
        // once `sessionController.stop()` has drained (translations intact),
        // the live session tears the worker down (Apple runs are owned by
        // SwiftUI and stay parked), supersedes any airborne high-fidelity
        // probe (a landing must not mark a session that no longer exists),
        // and resets the published status.
        translationSession.sessionDidEnd()
        // The transcript stays on screen after a stop, so a row waiting on a
        // re-translation would sit dimmed with its button disabled. Nothing
        // will deliver that result any more; the lane drops every marker,
        // cancels its task, invalidates stragglers through its epoch bump,
        // and rebuilds the armed sessions in place — a nil → fresh-equal
        // config reassignment is the `.translationTask` path that does not
        // reliably re-fire, so the teardown must not nil them (see
        // `RetranslateCoordinator.teardown`).
        retranslate.sessionDidEnd()
        let endedAt = ContinuousClock.now
        sessionEndedAt = endedAt
        // Stop/teardown clears all toasts and notices (phase → `.idle`).
        toasts.clearAll()
        notices.dismiss()
        phase = .idle
        // The archive finalize runs last so its toast — or its one-shot
        // failure warning — survives the teardown's `clearAll` above. Every
        // stop finalizes as a recent; promotion is a later one-click action.
        if let durationMS = activeSessionDurationMS(to: endedAt),
           finalizeLiveSession(durationMS: durationMS)
        {
            postArchivedRecentToast()
        }
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
        // Re-entrancy latch: a second notification while the first teardown
        // is suspended must not run a concurrent second `performStop` (it is
        // not config-idempotent). The first call's completion notification is
        // a broadcast, so any second waiter is served by it; `isTerminating`
        // also keeps `start()` refused for good.
        guard !isTerminating else { return }
        isTerminating = true
        if let stopTask {
            await stopTask.value
        } else if phase == .starting || phase == .running || phase == .paused
            || phase == .stopping || phase == .sourceLost
        {
            phase = .stopping
            await performStop()
        }
        retireWarmEngine()
        NotificationCenter.default.post(name: .mimidasuTerminationTeardownComplete, object: nil)
    }
}
