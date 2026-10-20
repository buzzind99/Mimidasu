import Foundation
import Translation

// Dedicated re-translate sessions of `RetranslateCoordinator` — the
// per-kind arming, the `.translationTask` hand-over hooks, the
// teardown/rebuild lifecycle, and the session-boundary marker resets —
// split from the main file to keep it under the lint file gate.

extension RetranslateCoordinator {

    // MARK: - Dedicated Apple sessions

    /// ja→`target` configuration for one of the dedicated re-translate
    /// sessions. Mirrors the live session's config except the strategy,
    /// which `tierAvailability.applyPreferredStrategy(to:highFidelity:)` sets
    /// EXPLICITLY above the strategy API — the property's default follows the
    /// SDK the app was built against, which would hand both lanes the same
    /// model as the live session and return byte-identical text, defeating
    /// the feature. Below the strategy API the config stays plain (the
    /// session is the fast model by definition). The target is passed in
    /// rather than read from the settings: an archive retry runs to the
    /// archived session's stored target, which can differ from the current
    /// selection.
    func makeRetranslateConfig(
        highFidelity: Bool, target: String
    ) -> TranslationSession.Configuration {
        var config = TranslationSession.Configuration(
            source: Locale.Language(identifier: "ja"),
            target: Locale.Language(identifier: target)
        )
        tierAvailability.applyPreferredStrategy(to: &config, highFidelity: highFidelity)
        return config
    }

    /// The settings-target spelling, for callers outside the lane (the
    /// `.translationTask` hosts' configs, tests).
    func makeRetranslateConfig(highFidelity: Bool) -> TranslationSession.Configuration {
        makeRetranslateConfig(highFidelity: highFidelity, target: settings.targetLanguage.code)
    }

    /// The stored dedicated-session engine for an Apple kind — each lane
    /// waits on its own host's hand-over, never the other's. Named apart from
    /// the `retranslateSessionEngine` / `retranslateHifiSessionEngine`
    /// properties it reads so a call site is never mistaken for one.
    /// Target-gated: an armed config rebuilt for another target carries that
    /// target's hand-over, so a link still waiting for its own target must
    /// not adopt it. (Internal, not private: the lane runner polls it.)
    func laneEngineStorage(
        for kind: TranslationEngineKind, target: String
    ) -> (any TranslationEngine)? {
        switch kind {
        case .appleHighFidelity:
            retranslateHifiConfigTarget == target ? retranslateHifiSessionEngine : nil
        case .appleFast:
            retranslateConfigTarget == target ? retranslateSessionEngine : nil
        case .google, .deepl, .openrouter:
            nil
        }
    }

    /// Arms the kind's dedicated session on the first retry through it.
    /// Never pointlessly reassigns an armed config: reassignment is a path
    /// SwiftUI's `.translationTask` may not reliably re-fire on, and a
    /// timeout keeps the config armed so the next click is instant once the
    /// session (or its language-pack download) lands. An armed config does
    /// pin its target, though — a retry whose lane target differs (the
    /// settings target changed, or an archive carries a different stored
    /// target) rebuilds through the proven invalidate+reassign path.
    /// Arming also clears any stored engine for the kind: the wait that
    /// follows must be for THIS config's hand-over, never a stale engine an
    /// unknown path left behind.
    func armRetranslateSessionIfNeeded(for kind: TranslationEngineKind, target: String) {
        switch kind {
        case .appleFast:
            guard retranslateConfig == nil || retranslateConfigTarget != target else { return }
            retranslateSessionEngine = nil
            retranslateConfig = armedConfig(
                retranslateConfig, highFidelity: false, target: target
            )
            retranslateConfigTarget = target
        case .appleHighFidelity:
            guard retranslateHifiConfig == nil || retranslateHifiConfigTarget != target else { return }
            retranslateHifiSessionEngine = nil
            retranslateHifiConfig = armedConfig(
                retranslateHifiConfig, highFidelity: true, target: target
            )
            retranslateHifiConfigTarget = target
        case .google, .deepl, .openrouter:
            break // externals build their engine at click time; no session
        }
    }

    /// The settings-target spelling, for the app-model facade and tests.
    func armRetranslateSessionIfNeeded(for kind: TranslationEngineKind) {
        armRetranslateSessionIfNeeded(for: kind, target: settings.targetLanguage.code)
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
        // The rebuild preserves each armed config's target: the parked
        // successor session keeps running it, and a next arm for a
        // different target rebuilds again through the mismatch check.
        retranslateConfig = rebuiltConfig(
            retranslateConfig, highFidelity: false,
            target: retranslateConfigTarget ?? laneTargetLanguage.code
        )
        retranslateSessionEngine = nil
        retranslateHifiConfig = rebuiltConfig(
            retranslateHifiConfig, highFidelity: true,
            target: retranslateHifiConfigTarget ?? laneTargetLanguage.code
        )
        retranslateHifiSessionEngine = nil
    }

    /// The arm's successor of a lane config: a never-armed config (nil) is
    /// built fresh; an armed one for a different target is invalidated
    /// first. Invalidate + reassign is the proven `.translationTask`
    /// re-fire path (`refreshConfig` uses it), so a target change re-fires
    /// instead of gambling on a reassignment SwiftUI may ignore.
    private func armedConfig(
        _ config: TranslationSession.Configuration?, highFidelity: Bool, target: String
    ) -> TranslationSession.Configuration {
        if var existing = config {
            existing.invalidate()
        }
        return makeRetranslateConfig(highFidelity: highFidelity, target: target)
    }

    /// The teardown/arm successor of lane configs: invalidated, then
    /// rebuilt for the same kind and target so the host's `.translationTask`
    /// sees a change and re-fires. A nil config was never armed — it stays
    /// nil.
    private func rebuiltConfig(
        _ config: TranslationSession.Configuration?, highFidelity: Bool, target: String
    ) -> TranslationSession.Configuration? {
        guard var config else { return nil }
        config.invalidate()
        return makeRetranslateConfig(highFidelity: highFidelity, target: target)
    }

    // MARK: - Bulk job engine resolution

    /// Resolves the bulk archive-translation job's engine, mirroring the
    /// archive route's mapping: `.session` / `.appleFast` arm the dedicated
    /// fast session, a high-fidelity selection arms its session, and
    /// externals come from their stored key. The selection arrives already
    /// resolved against the run's target (the caller's archive-job mapping
    /// applied `effectiveAppleTier(_:targetCode:)`), so it is passed through
    /// verbatim — no settings-pair degrade is re-applied. The wait aborts on
    /// the run's own cancellation probe, so an archive boundary never
    /// discards a run.
    func resolveArchiveJobEngine(
        selection: RetranslateEngine, target: TargetLanguage,
        shouldAbort: @escaping @MainActor () -> Bool
    ) async -> ArchiveTranslationJob.EngineResolution {
        if let provider = selection.provider {
            return archiveExternalResolution(for: provider, target: target)
        }
        let kind: TranslationEngineKind = selection == .appleHighFidelity
            ? .appleHighFidelity
            : .appleFast
        return await resolveJobAppleEngine(
            kind: kind, target: target, shouldAbort: shouldAbort
        )
    }

    /// The external half of the job resolution: the provider's stored key
    /// supplies its lane engine over the run's target, or the run reports
    /// the missing key.
    private func archiveExternalResolution(
        for provider: TranslationProvider, target: TargetLanguage
    ) -> ArchiveTranslationJob.EngineResolution {
        guard let engine = laneExternalEngine(for: provider, target: target) else {
            return .unavailable(reason: "No API key stored for \(provider.displayName).")
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
    /// calls), then waits for the hand-over. Both waits abort on the run's
    /// own cancellation probe, so a close/swap releases the claim promptly
    /// only when the run itself was cancelled. A timeout reports the
    /// still-starting copy and keeps the config armed, so the next attempt is
    /// instant once the session (or its language pack) lands; an abort is a
    /// cancellation whose surface is already gone. A cancellation can land
    /// after the wait resolved — the storage read can adopt an engine handed
    /// over in the meantime — so the probe is re-checked before the engine is
    /// handed to the run.
    private func resolveJobAppleEngine(
        kind: TranslationEngineKind, target: TargetLanguage,
        shouldAbort: @escaping @MainActor () -> Bool
    ) async -> ArchiveTranslationJob.EngineResolution {
        let epoch = retranslateSessionEpoch
        armRetranslateSessionIfNeeded(for: kind, target: target.code)
        while !laneChainIdle {
            guard !shouldAbort() else { return .cancelled }
            try? await Task.sleep(for: .milliseconds(50))
        }
        switch await laneEngine(
            laneEngineStorage(for: kind, target: target.code),
            kind: kind, epoch: epoch, target: target.code, shouldAbort: shouldAbort
        ) {
        case let .ready(engine):
            guard !shouldAbort() else { return .cancelled }
            return .ready(engine: engine, kind: kind)
        case .timedOut:
            return .unavailable(
                reason: kind == .appleHighFidelity
                    ? "Apple Intelligence session is still starting — try again in a moment."
                    : "Apple (NMT) session is still starting — try again in a moment."
            )
        case .cancelled:
            return .cancelled
        }
    }

    /// Outcome of resolving a lane or job engine. `.timedOut` and
    /// `.cancelled` are distinct on purpose: the timeout reports a
    /// still-starting session, while a cancellation is a user-initiated
    /// stop/teardown whose toasts are already cleared, so reporting it would
    /// post a stray message.
    enum LaneEngineResolution {
        case ready(any TranslationEngine)
        case timedOut
        case cancelled
    }

    /// Resolves the lane's engine: a built engine passes through; nil (an
    /// Apple selection while its dedicated session is still arming) waits a
    /// bounded interval for the `.translationTask` host to hand one over —
    /// acquisition is sub-second once armed, the bound only catches
    /// pathological cases. Storage is read for `target` only: a config
    /// re-armed for another target never serves this wait. The deadline is
    /// monotonic (`ContinuousClock`) — wall-clock `Date` would skew on clock
    /// changes. A lane whose epoch turns over, or a job whose run is
    /// cancelled through its probe, exits promptly instead of polling its
    /// nilled storage out the whole arm window. Without a probe the epoch
    /// guard stays in force, so lane callers keep their existing contract.
    func laneEngine(
        _ engine: (any TranslationEngine)?, kind: TranslationEngineKind, epoch: Int, target: String,
        shouldAbort: (@MainActor () -> Bool)? = nil
    ) async -> LaneEngineResolution {
        if let engine {
            return .ready(engine)
        }
        let deadline = ContinuousClock.now + laneArmTimeout
        // Polls the storage the loop exits on and returns that same value: a
        // re-read after the loop would race a teardown and read nil as a
        // timeout.
        var resolved = laneEngineStorage(for: kind, target: target)
        while resolved == nil, ContinuousClock.now < deadline {
            let aborted = shouldAbort.map { probe in probe() }
                ?? !retranslateLaneCanDeliver(epoch: epoch)
            guard !aborted else { return .cancelled }
            do {
                try await Task.sleep(for: Duration.milliseconds(50))
            } catch {
                return .cancelled
            }
            resolved = laneEngineStorage(for: kind, target: target)
        }
        guard let resolved else { return .timedOut }
        return .ready(resolved)
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

    /// Lane work and markers only: cancels the in-flight lane generation,
    /// drops every marker, and bumps the epoch so nothing still airborne can
    /// deliver. The dedicated Apple configs and stored engines are left
    /// untouched — they are target-scoped, not archive-scoped.
    private func retireLaneWork() {
        pendingRetranslations.removeAll()
        lanePendingRetranslations.removeAll()
        retranslateLaneTask?.cancel()
        retranslateLaneTask = nil
        retranslateSessionEpoch += 1
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
