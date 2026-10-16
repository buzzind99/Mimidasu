import Foundation
import Translation

// Dedicated re-translate sessions of `RetranslateCoordinator` — the
// per-kind arming, the `.translationTask` hand-over hooks, the
// teardown/rebuild lifecycle, and the session-boundary marker resets —
// split from the main file to keep it under the lint file gate.

extension RetranslateCoordinator {

    // MARK: - Dedicated Apple sessions

    /// ja→target configuration for one of the dedicated re-translate
    /// sessions. Mirrors the live session's config except the strategy,
    /// which is set EXPLICITLY on 26.4+ — the property's default follows the
    /// SDK the app was built against, which would hand both lanes the same
    /// model as the live session and return byte-identical text, defeating
    /// the feature. Below 26.4 the config stays plain (the session is the
    /// fast model by definition).
    func makeRetranslateConfig(highFidelity: Bool) -> TranslationSession.Configuration {
        var config = TranslationSession.Configuration(
            source: Locale.Language(identifier: "ja"),
            target: Locale.Language(identifier: settings.targetLanguage.code)
        )
        if #available(macOS 26.4, *) {
            config.preferredStrategy = highFidelity ? .highFidelity : .lowLatency
        }
        return config
    }

    /// The stored dedicated-session engine for an Apple kind — each lane
    /// waits on its own host's hand-over, never the other's. Named apart from
    /// the `retranslateSessionEngine` / `retranslateHifiSessionEngine`
    /// properties it reads so a call site is never mistaken for one.
    /// (Internal, not private: the lane runner polls it.)
    func laneEngineStorage(
        for kind: TranslationEngineKind
    ) -> (any TranslationEngine)? {
        kind == .appleHighFidelity ? retranslateHifiSessionEngine : retranslateSessionEngine
    }

    /// Arms the kind's dedicated session on the first retry through it.
    /// Never reassigns an armed config: reassignment is a path SwiftUI's
    /// `.translationTask` may not reliably re-fire on, and a timeout keeps
    /// the config armed so the next click is instant once the session (or
    /// its language-pack download) lands. Arming also clears any stored
    /// engine for the kind: the wait that follows must be for THIS config's
    /// hand-over, never a stale engine an unknown path left behind.
    func armRetranslateSessionIfNeeded(for kind: TranslationEngineKind) {
        switch kind {
        case .appleFast:
            guard retranslateConfig == nil else { return }
            retranslateSessionEngine = nil
            retranslateConfig = makeRetranslateConfig(highFidelity: false)
        case .appleHighFidelity:
            guard retranslateHifiConfig == nil else { return }
            retranslateHifiSessionEngine = nil
            retranslateHifiConfig = makeRetranslateConfig(highFidelity: true)
        case .google, .deepl, .openrouter:
            break // externals build their engine at click time; no session
        }
    }

    /// Stores the fast-model session handed over by the second
    /// `.translationTask` host. Does not run the queue — the lane is the
    /// only consumer. Takes the engine existential (the host passes the
    /// `AppleSessionEngine` wrapper) so tests can hand over a mock. Gated
    /// on the config being armed: a hand-over for a torn-down lane must not
    /// store a session the next lane would acquire instantly.
    func retranslateSessionArrived(_ engine: any TranslationEngine) {
        guard retranslateConfig != nil else { return }
        retranslateSessionEngine = engine
    }

    /// Stores the Apple Intelligence session handed over by the third
    /// `.translationTask` host. Does not run the queue. Gated the same way
    /// as `retranslateSessionArrived`.
    func retranslateHifiSessionArrived(_ engine: any TranslationEngine) {
        guard retranslateHifiConfig != nil else { return }
        retranslateHifiSessionEngine = engine
    }

    /// Drops both armed-session states (configs + stored engines) and
    /// invalidates in-flight lane work with them. Called from every explicit
    /// Apple activation (`activate()`'s Apple branch) and from session end;
    /// the latched fallback keeps the lane alive by design (an in-flight
    /// lane result still has its deliverer). Within a session an armed config
    /// is always current — target changes are restart-only — so the reset
    /// covers the session boundary: a next session on an external provider
    /// never takes the Apple branch, and a config armed for a prior target
    /// must not survive to serve it.
    ///
    /// Cancelling the stored task and bumping the epoch makes the reset a
    /// lane-generation change, not just a session one: a chained task
    /// resuming after a mid-session teardown (an Apple activation while a
    /// lane flight is airborne) would otherwise pass the phase/epoch guards
    /// — the session is still live — and fly a session that just died, or
    /// toast over the activation the user just made. Its captured epoch no
    /// longer matches, so every delivery guard retires it silently.
    /// Session end cancels and bumps too; both are idempotent.
    ///
    /// Accepted loss: the cancellation reaches only the newest chained
    /// link, so a mid-air EXTERNAL flight (a paid round-trip) keeps running
    /// to completion — and then throws its result away at the delivery
    /// guard, with no toast. Documented rather than fixed: reporting it
    /// would toast over the activation the user just chose, and delivering
    /// it would stamp a row in a lane generation the user abandoned.
    ///
    /// The bump makes every lane-owned marker dead — no lane task can
    /// deliver past it — so they are retired here, synchronously, rather
    /// than left to the cancelled task's own exit: that exit now skips
    /// (stale epoch, see `retireLaneMarker`), and until session stop the
    /// row would sit dimmed with its retry button dead. Only the lane-owned
    /// subset goes; a queue-owned marker (a queued retry whose result the
    /// queue still owes) keeps its cue.
    ///
    /// The configs are REBUILT, not nil-ed: a nil → fresh-equal-config
    /// transition is the path SwiftUI's `.translationTask` does not
    /// reliably re-fire on, and the next Apple-kind retry would arm
    /// onto it — the lane would sit in its arm wait out to the timeout
    /// toast while the host never fires. Invalidate + reassign is the
    /// proven re-fire path (the one `refreshConfig` uses), and
    /// the rebuild reads the current target, so a config armed for a prior
    /// target does not survive. A never-armed config stays nil (lazy
    /// arming preserved); a rebuilt one parks a fresh dedicated session —
    /// the same kept-alive treatment the live config gets across a stop.
    /// The stored engines go with the old configs: the next lane must wait
    /// for the rebuilt config's own hand-over, never fly an orphan of an
    /// invalidated session.
    func teardown() {
        retranslateLaneTask?.cancel()
        retranslateLaneTask = nil
        retranslateSessionEpoch += 1
        pendingRetranslations.subtract(lanePendingRetranslations)
        lanePendingRetranslations.removeAll()
        retranslateConfig = rebuildRetranslateConfig(retranslateConfig, highFidelity: false)
        retranslateSessionEngine = nil
        retranslateHifiConfig = rebuildRetranslateConfig(retranslateHifiConfig, highFidelity: true)
        retranslateHifiSessionEngine = nil
    }

    /// The teardown successor of an armed lane config: invalidated, then
    /// rebuilt for the same kind so the host's `.translationTask` sees a
    /// change and re-fires. A nil config was never armed — it stays nil.
    private func rebuildRetranslateConfig(
        _ config: TranslationSession.Configuration?, highFidelity: Bool
    ) -> TranslationSession.Configuration? {
        guard var config else { return nil }
        config.invalidate()
        return makeRetranslateConfig(highFidelity: highFidelity)
    }
}

// MARK: - Session lifecycle

extension RetranslateCoordinator {
    /// Session boundary: sentence indexes restart at 0 in every session, so
    /// a backlog left by the last one has no row to land on — the markers
    /// are dropped, and with them any re-translation still waiting on its
    /// result. The epoch bump retires any lane task still in flight from the
    /// previous session.
    func sessionWillBegin() {
        pendingRetranslations.removeAll()
        lanePendingRetranslations.removeAll()
        retranslateSessionEpoch += 1
    }

    /// Stop/teardown: the transcript stays on screen after a stop, so a row
    /// waiting on a re-translation would sit dimmed with its button
    /// disabled. Nothing will deliver that result any more, so every marker
    /// goes (queue-owned ones included — the queue's own landing is the only
    /// deliverer left, and stop has already drained it), and the lane
    /// teardown invalidates stragglers: cancelling reaches only the newest
    /// chained link, earlier lane tasks keep running to completion, and
    /// without the epoch bump they would pass the phase guard in the NEXT
    /// session (indexes restart at 0) and swap an unrelated row's
    /// translation.
    func sessionDidEnd() {
        pendingRetranslations.removeAll()
        teardown()
    }

    /// Retires the row's re-translation marker for a landed result. Cleared
    /// before the row lookup by `applyTranslation`: a result whose row is
    /// gone (the transcript cleared underneath it) must still retire its
    /// marker, or the row stays dimmed with its retry button dead.
    func clearMarkers(at index: Int) {
        pendingRetranslations.remove(index)
        lanePendingRetranslations.remove(index)
    }

    /// The queue's terminal-`.unavailable` clear: no engine swap follows the
    /// failure, so queue-owned markers have lost their deliverer — but a
    /// lane translation in flight still has its own, and dropping its marker
    /// would re-open the double-click guard.
    func dropQueueOwnedMarkers() {
        pendingRetranslations.formIntersection(lanePendingRetranslations)
    }
}
