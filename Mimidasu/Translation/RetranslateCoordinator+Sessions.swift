import Foundation
import Translation

// Dedicated re-translate sessions and the bulk job's engine resolution of
// `RetranslateCoordinator` — the session/archive boundaries and the awaited
// resolution path — split from the main file to keep it under the lint file
// gate.

extension RetranslateCoordinator {

    // MARK: - Dedicated Apple sessions

    /// Stores the session handed over by a `.translationTask` host. The
    /// kind selects the arm; the arm refuses a hand-over while its config is
    /// unarmed or built for another target, so a session for a torn-down or
    /// superseded lane is never stored.
    func retranslateSessionArrived(
        _ kind: TranslationEngineKind, engine: any TranslationEngine,
        targetLanguage: Locale.Language? = nil
    ) {
        appleSessions.retranslateSessionArrived(
            kind: kind, engine: engine, targetLanguage: targetLanguage
        )
    }

    // MARK: - Bulk job engine resolution

    /// Resolves the bulk archive-translation job's engine from the archive
    /// plan: `.session` / `.appleFast` arm the dedicated fast session, the
    /// plan's effective high-fidelity selection arms its session, and an
    /// external comes from its stored key. The plan scopes the effective
    /// selection to the run's target, so no settings-pair degrade applies
    /// here. Cancelling the job cancels this resolution's task, which every
    /// wait below observes.
    func resolveArchiveJobEngine(
        selection: RetranslateEngine, target: TargetLanguage
    ) async -> ArchiveTranslationJob.EngineResolution {
        let plan = plan(surface: .archive, target: target, selection: selection)
        if case let .unavailable(reason) = plan.route {
            return .unavailable(reason: reason)
        }
        // An archive plan always routes a lane; `.session` can only be a
        // defensive fallback here and resolves the plain on-device model.
        let engine = plan.route.laneEngine ?? .appleFast
        if let provider = engine.provider {
            return archiveExternalResolution(for: provider, target: target)
        }
        return await resolveJobAppleEngine(
            kind: engine.kind ?? .appleFast, target: target
        )
    }

    /// The external half of the job resolution: the provider's stored key
    /// supplies its lane engine over the run's target. The plan's key check
    /// already admitted the route, so a nil engine means the build failed —
    /// the key is unreadable (deleted from the secure store, denied after a
    /// re-sign) or a test factory reports no engine.
    private func archiveExternalResolution(
        for provider: TranslationProvider, target: TargetLanguage
    ) -> ArchiveTranslationJob.EngineResolution {
        guard let engine = laneExternalEngine(for: provider, target: target) else {
            return .unavailable(
                reason: "Couldn't build a \(provider.displayName) engine — try again in a moment."
            )
        }
        return .ready(
            engine: engine,
            kind: TranslationEngineKind(provider: provider) ?? .appleFast
        )
    }

    /// The Apple half of the job resolution: arms the kind's dedicated
    /// session for the run's target, waits for the lane chain to drain (per-
    /// row retries are refused from the job's claim onward, so the chain is
    /// already being cut off — but a link airborne before the claim may
    /// still be flying, and a session-backed engine never sees concurrent
    /// calls), then waits for the hand-over. Both waits are continuations
    /// abandoned by teardown or task cancellation, so a close/swap releases
    /// the claim promptly only when the run itself was cancelled. A timeout
    /// reports the still-starting copy and keeps the config armed, so the
    /// next attempt is instant once the session (or its language pack)
    /// lands; an abandoned wait is a cancellation whose surface is already
    /// gone.
    private func resolveJobAppleEngine(
        kind: TranslationEngineKind, target: TargetLanguage
    ) async -> ArchiveTranslationJob.EngineResolution {
        appleSessions.arm(kind: kind, target: target.code)
        guard await waitForLaneChainIdle() else { return .cancelled }
        switch await appleSessions.awaitEngine(
            for: kind, target: target.code, timeout: laneArmTimeout, laneOwned: false
        ) {
        case let .ready(engine):
            return .ready(engine: engine, kind: kind)
        case .timedOut:
            return .unavailable(
                reason: "\(kind.tier.name) session is still starting — try again in a moment."
            )
        case .cancelled:
            return .cancelled
        }
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
        clearAllMarkers()
        beginLaneEpoch()
        cancelLaneWaits()
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
        clearAllMarkers()
        teardown()
    }

    /// Archive boundary — an archived session was opened into the pane. Its
    /// rows replace the live transcript's wholesale, so every marker
    /// (queue-owned included) has lost its deliverer, and the lane work is
    /// retired: a straggler from the live session (or the previously opened
    /// archive, whose indexes are unrelated) must never land on the new
    /// rows. The dedicated Apple sessions stay armed — a running bulk job
    /// holds one, and arming plus target-gated storage reads make a stale
    /// config inert.
    func archiveWillOpen() {
        retireLaneWork()
    }

    /// Archive boundary — the opened archive closed and the pane emptied.
    /// Same retirement: nothing the lane could deliver to remains on screen.
    func archiveWillClose() {
        retireLaneWork()
    }
}
