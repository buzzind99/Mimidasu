import Foundation
import Translation

// The re-translate lane runner of `RetranslateCoordinator` — the retry
// entry point, route resolution, the serialized alternate-engine runner,
// the probe-deferral gate, and the marker bookkeeping — split from the main
// file to keep it under the lint file gate.

extension RetranslateCoordinator {

    // MARK: - Retry entry point

    /// Manual retry for one transcript row: routes through the configured
    /// engine. Idempotent: a click while this row already retranslates (the
    /// marker is still set), or while the sentence's translation is queued or
    /// airborne for any reason (the queue owns that check), is a no-op — both
    /// guards run before any marker insert so a no-op never dims the row.
    /// Gated on a live session; the session-path branch additionally requires
    /// an attached worker (`pending` outlives a run by design, so a request
    /// made with no engine to serve it would park indefinitely). The index
    /// rides the marker set(s) until the result lands — cleared by the
    /// landing result (`applyTranslation`), by a timeout/failure that engages
    /// no replay, by session stop, and by the next session's begin.
    ///
    /// `.sourceLost` counts as live: capture can die mid-session while
    /// translation keeps draining, and a line worth re-running is exactly
    /// what a user reaches for then. An open archive is the second gate: no
    /// live session, but the pane's rows are just as retryable.
    func retranslateSentence(_ sentence: Sentence) {
        let livePhase = sessionPhase == .running || sessionPhase == .sourceLost
            || sessionPhase == .paused
        guard livePhase || archiveOpen else { return }
        // The bulk job owns the archive's engines while a run is claimed
        // (resolution included): a session-backed Apple engine must never
        // see concurrent calls.
        guard host?.archiveTranslationRunning != true else { return }
        guard !pendingRetranslations.contains(sentence.index) else { return }
        // The queue's awaited-sentence check guards the queue route's
        // double-click case. In archive mode the queue has no bearing on
        // these rows (its ids restart at 0 in every session and can collide
        // with the archive's), so the check is skipped with the route.
        if !archiveOpen, queue.isAwaitingTranslation(sentence) {
            return
        }
        // The click-time lane target, captured once: the archive's viewing
        // language can switch while the lane arms or waits, and the result
        // must be stamped — and the engine built — for the language the
        // retry was clicked in, never a later reading.
        let target = laneTargetLanguage
        switch resolveRetranslateRoute(target: target) {
        case .session:
            // Today's path verbatim: the queue owns the retry (cache evicted,
            // re-enqueued) and the result lands unstamped — never marked.
            // No worker (the engine was released after a terminal failure):
            // report like the deferred hand-over does instead of a click
            // that does nothing. No marker is set, so nothing dangles.
            guard queue.hasWorker else {
                postRetranslateUnavailableToast(
                    "No translation engine attached — try again in a moment."
                )
                return
            }
            pendingRetranslations.insert(sentence.index)
            queue.retranslate(sentence)
        case let .alternate(kind, engine):
            // Both sets: `pendingRetranslations` is the row cue +
            // double-click guard every view reads; `lanePendingRetranslations`
            // records lane ownership so the queue's terminal `.unavailable`
            // clear can't drop a marker whose translation still has a
            // deliverer.
            pendingRetranslations.insert(sentence.index)
            lanePendingRetranslations.insert(sentence.index)
            // The lane owns this sentence now: if it sits in a failed-out
            // backlog, drop the queued copy so a later Reconnect replay
            // cannot re-translate it and overwrite the lane's stamped
            // result with an unstamped one. Archive mode never touches the
            // queue (see the gate above).
            if !archiveOpen {
                queue.dropPending(sentence)
            }
            runRetranslateLane(sentence, kind: kind, engine: engine, target: target)
        case let .unavailable(reason):
            // Toast + skip — no state touched, the row keeps its translation.
            postRetranslateUnavailableToast(reason)
        }
    }

    // MARK: - Route resolution

    /// Where a retry goes, resolved at click time. The engine is nil only
    /// for an Apple selection while its dedicated session is still arming;
    /// the lane then waits for it (bounded).
    private enum RetranslateRoute {
        case session
        case alternate(TranslationEngineKind, engine: (any TranslationEngine)?)
        case unavailable(String)
    }

    private func resolveRetranslateRoute(target: TargetLanguage) -> RetranslateRoute {
        if archiveOpen {
            return resolveArchiveRoute(target: target)
        }
        let selection = effectiveRetranslateSelection(targetCode: target.code)
        switch selection {
        case .session:
            return .session
        case .appleFast:
            return resolveAppleModelRoute(.appleFast, target: target)
        case .appleHighFidelity:
            return resolveAppleModelRoute(.appleHighFidelity, target: target)
        case .google, .deepl, .openrouter:
            guard let provider = selection.provider else { return .session }
            // A selection naming the attached provider IS the session
            // engine — the queue path serves it (externals sample, so a
            // re-run can still differ, but it is no longer an alternate).
            // A gone live session never matches, so the lane serves it.
            if provider == live?.activeExternalProvider {
                return .session
            }
            let engine = laneExternalEngine(for: provider, target: target)
            guard let engine else {
                return .unavailable("No API key stored for \(provider.displayName).")
            }
            // The provider is external here, so the kind mapping is total
            // (only Apple maps to nil); the fallback mirrors the live-identity
            // read in `activeEngineKind`.
            return .alternate(TranslationEngineKind(provider: provider) ?? .appleFast, engine: engine)
        }
    }

    /// Archive mode route: every selection serves through a dedicated
    /// alternate — never the queue, which has no session to deliver into.
    /// `.session` ("whatever the live session ran") has no referent with no
    /// live session; it maps to Apple-fast, the plain on-device route. The
    /// selection resolves against the click-time lane target: probe evidence
    /// only counts for the pair it was probed for, so the settings pair must
    /// not degrade a foreign archive target's high-fidelity request.
    private func resolveArchiveRoute(target: TargetLanguage) -> RetranslateRoute {
        switch effectiveRetranslateSelection(targetCode: target.code) {
        case .session, .appleFast:
            return armedRoute(.appleFast, target: target)
        case .appleHighFidelity:
            return armedRoute(.appleHighFidelity, target: target)
        case let selection:
            guard let provider = selection.provider else { return armedRoute(.appleFast, target: target) }
            let engine = laneExternalEngine(for: provider, target: target)
            guard let engine else {
                return .unavailable("No API key stored for \(provider.displayName).")
            }
            return .alternate(TranslationEngineKind(provider: provider) ?? .appleFast, engine: engine)
        }
    }

    private func resolveAppleModelRoute(
        _ kind: TranslationEngineKind, target: TargetLanguage
    ) -> RetranslateRoute {
        if #available(macOS 26.4, *) {
            // A live Apple session running the same model de facto would
            // return byte-identical text with no marker — a no-op that reads
            // as a broken button. The session engine serves instead. While
            // the probe is unlanded the identity is unknown (see
            // `liveSessionRunsKind`), so the click routes to the dedicated
            // session and the lane re-routes on the landing — a same-engine
            // retry is handed to the queue path there.
            if liveSessionRunsKind(kind) {
                return .session
            }
            return armedRoute(kind, target: target)
        }
        // Below 26.4 one Apple model exists (fast, no strategy API) and the
        // live Apple session already runs it. The high-fidelity arm is
        // unreachable via callers — `effectiveRetranslateSelection` degrades
        // below 26.4 first — and stays as defense in depth; do not simplify
        // it away with that degrade.
        return kind == .appleHighFidelity || liveSessionRunsKind(.appleFast)
            ? .session : armedRoute(kind, target: target)
    }

    private func armedRoute(_ kind: TranslationEngineKind, target: TargetLanguage) -> RetranslateRoute {
        // Arming is optimistic: if the dedicated session is still starting,
        // the lane waits for it (bounded) instead of blocking the click.
        // The armed config bakes in the click-time lane target — the
        // archive's viewing language in archive mode, the settings target
        // live.
        armRetranslateSessionIfNeeded(for: kind, target: target.code)
        return .alternate(kind, engine: laneEngineStorage(for: kind))
    }

    /// Builds the lane's external engine over `target` — the click-time lane
    /// target (the archive's viewing language in archive mode, the settings
    /// target live). The test factory is authoritative when set: a nil
    /// result means "unavailable" (no key), never a fall-through to the real
    /// engine. (Internal, not private: the bulk job's resolution in
    /// `+Sessions` reuses it.)
    func laneExternalEngine(
        for provider: TranslationProvider, target: TargetLanguage
    ) -> (any TranslationEngine)? {
        if let factory = retranslateEngineFactory {
            return factory(provider, target)
        }
        // A nil `live` is unreachable behind the caller's live-phase guard
        // (a live phase implies the host, which owns both coordinators); in
        // archive mode `live` exists with any app model.
        guard let live else { return nil }
        return live.makeExternalEngine(for: provider, target: target)
    }

    // MARK: - Lane runner

    /// Runs one alternate-engine translation through the serialized lane.
    /// Lane tasks chain on the previous one (`await previous?.value`), so a
    /// session-backed engine never sees concurrent `translate` calls —
    /// `TranslationSession` makes no reentrancy promise. Cancelling the
    /// stored task reaches only the newest link: earlier tasks are
    /// independent `Task`s awaited by value, so their in-flight engine call
    /// runs to completion and the post-await phase guards (not cancellation)
    /// drop their results.
    ///
    /// Apple-kind lanes first defer (bounded) to the activation probe:
    /// while it is unlanded the live identity is unknown, so flying would
    /// risk a duplicate of the live session (same-engine no-op) or a
    /// high-fidelity stamp over the framework's silent fast fallback. The
    /// landing re-resolves the kind; a same-engine retry is handed to the
    /// queue path there. External lanes skip the wait — the live session
    /// can never be (or turn into) a paid provider.
    private func runRetranslateLane(
        _ sentence: Sentence, kind: TranslationEngineKind,
        engine: (any TranslationEngine)?, target: TargetLanguage
    ) {
        let previous = retranslateLaneTask
        // The session this retry belongs to. See `retranslateSessionEpoch`: a
        // lane task outliving its session would otherwise land on an
        // unrelated row of the next one, whose indexes restart at 0.
        let epoch = retranslateSessionEpoch
        retranslateLaneTask = Task { [weak self] in
            await previous?.value
            // A deallocated coordinator has no markers left to retire, so
            // the weak unwrap is the only exit that skips `retireLaneMarker`.
            guard let self else { return }
            guard retranslateLaneCanDeliver(epoch: epoch) else {
                retireLaneMarker(sentence.index, epoch: epoch)
                return
            }
            // Probe deferral — Apple-kind lanes only (external lanes pass straight through; see doc above).
            let laneKind: TranslationEngineKind
            switch await probeGate(for: kind, epoch: epoch, sentence: sentence, target: target) {
            case .done:
                return
            case let .proceed(resolvedKind):
                laneKind = resolvedKind
            }
            await flyResolvedLane(
                sentence, laneKind: laneKind, engine: engine, epoch: epoch, target: target
            )
        }
    }

    /// The lane task's second half, split out at the function-length gate:
    /// resolves the engine for the (possibly probe-degraded) lane kind and
    /// flies it, or reports the resolution's outcome. An Apple kind re-reads
    /// its own storage — after a degrade, the click-time engine belongs to
    /// the abandoned kind (a stored hifi engine while the lane now flies
    /// fast). Externals keep their click-time engine.
    private func flyResolvedLane(
        _ sentence: Sentence, laneKind: TranslationEngineKind,
        engine: (any TranslationEngine)?, epoch: Int, target: TargetLanguage
    ) async {
        let laneEngineCandidate: (any TranslationEngine)? = switch laneKind {
        case .appleFast, .appleHighFidelity:
            laneEngineStorage(for: laneKind)
        case .google, .deepl, .openrouter:
            engine
        }
        let resolved = await laneEngine(laneEngineCandidate, kind: laneKind, epoch: epoch)
        switch resolved {
        case .cancelled:
            // The stop already cleared every toast; a "still starting"
            // message here would outlive it and misreport a cancellation.
            retireLaneMarker(sentence.index, epoch: epoch)
            return
        case .timedOut:
            // The dedicated Apple session is still starting (or a
            // first-use language-pack prompt is up). The config stays
            // armed, so the next click is instant once it lands. Only
            // Apple selections can arrive here — externals build their
            // engine (or fail) at resolve time.
            retireLaneMarker(sentence.index, epoch: epoch)
            // The wait consumed the whole arm window — the outcome most
            // likely to have crossed a stop (older links are not
            // cancelled), so the same delivery guard as `.ready` applies
            // before reporting; a stale expiry must not repost over the
            // cleared stack.
            guard retranslateLaneCanDeliver(epoch: epoch) else { return }
            postRetranslateUnavailableToast(
                laneKind == .appleHighFidelity
                    ? "Apple Intelligence session is still starting — try again in a moment."
                    : "Apple (NMT) session is still starting — try again in a moment."
            )
            return
        case let .ready(engine):
            // The wait may have consumed the stop window; re-check before
            // flying so a stopped session never issues an engine call.
            guard retranslateLaneCanDeliver(epoch: epoch) else {
                retireLaneMarker(sentence.index, epoch: epoch)
                return
            }
            await fly(sentence, through: engine, kind: laneKind, epoch: epoch, target: target)
        }
    }

    /// Outcome of the probe-deferral gate at the head of a lane task.
    private enum ProbeGateOutcome {
        /// Continue with the (possibly re-resolved) lane kind.
        case proceed(TranslationEngineKind)
        /// The lane has exited — markers and reporting were handled here.
        case done
    }

    /// The probe-deferral gate: Apple-kind lanes wait bounded for the
    /// activation probe to land (external lanes pass straight through),
    /// and the landing re-routes — session hand-over when the live session
    /// turns out to run the requested engine, degrade-to-fast when the
    /// pair cannot serve high fidelity, or a "still checking" toast on
    /// timeout. Archive mode skips the gate entirely: the probe describes
    /// the live session's identity, and there is no live session to
    /// duplicate.
    private func probeGate(
        for kind: TranslationEngineKind, epoch: Int, sentence: Sentence, target: TargetLanguage
    ) async -> ProbeGateOutcome {
        if archiveOpen {
            return .proceed(kind)
        }
        switch kind {
        case .appleFast, .appleHighFidelity:
            break // the landing decides duplicate-vs-alternate for both
        case .google, .deepl, .openrouter:
            return .proceed(kind)
        }
        guard #available(macOS 26.4, *) else { return .proceed(kind) }
        switch await probeLanding(epoch: epoch) {
        case .cancelled:
            // The stop already cleared every toast; reporting here
            // would outlive it and misreport a cancellation.
            retireLaneMarker(sentence.index, epoch: epoch)
            return .done
        case .timedOut:
            retireLaneMarker(sentence.index, epoch: epoch)
            // The wait may have crossed a stop; a stale expiry must
            // not repost over the cleared stack.
            guard retranslateLaneCanDeliver(epoch: epoch) else { return .done }
            postRetranslateUnavailableToast(
                "Still checking Apple Intelligence availability — try again in a moment."
            )
            return .done
        case .landed:
            return probeLandedOutcome(kind: kind, epoch: epoch, sentence: sentence, target: target)
        }
    }

    /// The gate's `.landed` successor: the landing can change the
    /// selection's resolution — a not-installed landing degrades a
    /// high-fidelity selection to the fast model, whose dedicated session
    /// this lane must then arm and wait on instead — and a same-engine
    /// resolution is handed to the queue path.
    private func probeLandedOutcome(
        kind: TranslationEngineKind, epoch: Int, sentence: Sentence, target: TargetLanguage
    ) -> ProbeGateOutcome {
        guard retranslateLaneCanDeliver(epoch: epoch) else {
            retireLaneMarker(sentence.index, epoch: epoch)
            return .done
        }
        let laneKind = kindAfterProbeLanding(kind)
        if liveSessionRunsKind(laneKind) {
            handRetranslateToSession(sentence)
            return .done
        }
        if laneKind != kind {
            armRetranslateSessionIfNeeded(for: laneKind, target: target.code)
        }
        return .proceed(laneKind)
    }

    /// Outcome of waiting for the activation probe to land. `.timedOut` and
    /// `.cancelled` are distinct on purpose, mirroring
    /// `LaneEngineResolution`: a timeout reports a probe that never landed,
    /// a cancellation is a stop/teardown whose toasts are already cleared.
    private enum ProbeLanding {
        case landed
        case timedOut
        case cancelled
    }

    /// Waits bounded for the activation probe to land. The probe is a fast
    /// async availability check fired by every activation; the bound only
    /// catches pathological cases. Monotonic deadline (`ContinuousClock`) —
    /// wall-clock `Date` would skew on clock changes.
    private func probeLanding(epoch: Int) async -> ProbeLanding {
        let deadline = ContinuousClock.now + probeSettleTimeout
        while !appleProbeLanded {
            guard ContinuousClock.now < deadline else { return .timedOut }
            do {
                try await Task.sleep(for: Duration.milliseconds(50))
            } catch {
                return .cancelled
            }
            guard retranslateLaneCanDeliver(epoch: epoch) else { return .cancelled }
        }
        return .landed
    }

    /// The lane's Apple kind once the probe has landed (the live session's
    /// identity, so the settings pair is the probed pair): the click-time
    /// kind, unless a not-installed landing degrades a high-fidelity
    /// selection to the fast model — the same resolution
    /// `effectiveRetranslateSelection` applies once the probe has landed.
    func kindAfterProbeLanding(_ kind: TranslationEngineKind) -> TranslationEngineKind {
        guard kind == .appleHighFidelity, highFidelityKnownUnavailable else { return kind }
        return .appleFast
    }

    /// Hands a deferred same-engine retry to the queue path — what the
    /// `.session` route would have done had the probe been landed at click
    /// time. The markers are already in place: `pendingRetranslations`
    /// stays (the queue's landing, failure, or stop clears it) while the
    /// lane-ownership record goes, so the queue's terminal `.unavailable`
    /// clear can drop the cue.
    private func handRetranslateToSession(_ sentence: Sentence) {
        lanePendingRetranslations.remove(sentence.index)
        guard queue.hasWorker else {
            pendingRetranslations.remove(sentence.index)
            postRetranslateUnavailableToast(
                "No translation engine attached — try again in a moment."
            )
            return
        }
        queue.retranslate(sentence)
    }

    /// Runs the engine call and lands (or reports) the result. Split out of
    /// the lane task so the `do`/`catch` stays legible next to the guards.
    /// `target` is the click-time lane target: an archive close (or a
    /// viewing-language switch) during the round-trip turns over the epoch
    /// and the delivery guard below retires the result, so the stamp
    /// describes the pane the retry was clicked in.
    private func fly(
        _ sentence: Sentence, through engine: any TranslationEngine,
        kind: TranslationEngineKind, epoch: Int, target: TargetLanguage
    ) async {
        do {
            let results = try await engine.translate([sentence.text])
            // Re-check after the flight: a stop during the round-trip already
            // cleared the markers, and the transcript stays visible after stop
            // — a late landing must not swap the row.
            guard retranslateLaneCanDeliver(epoch: epoch) else {
                retireLaneMarker(sentence.index, epoch: epoch)
                return
            }
            guard let text = results.first, !text.isEmpty else {
                // An empty result must not land: it would render the row's
                // provenance marker with no sentence attached to it.
                throw TranslationEngineError.badResponse("Expected 1 non-empty translation, got 0")
            }
            let pair = SentenceTranslation(
                lang: target.code,
                text: text,
                engine: kind
            )
            let landed = host?.applyTranslation(index: sentence.index, translation: pair) ?? false
            // Seed the repeat-sentence cache with the retried *text* unstamped:
            // a fresh row repeating the sentence serves through the normal
            // queue path without the lane's provenance marker. Seeded only
            // when the row actually took the result — `applyTranslation`
            // reports whether the row was still present, so a result whose
            // row vanished (transcript cleared underneath it) never leaves
            // the retried text in the cache. Archive mode never seeds: the
            // cache belongs to the live session's queue, and an archive
            // result must not leak into a later session's rows.
            if landed, !archiveOpen {
                queue.seedCache(sentence, pair)
            }
        } catch is CancellationError {
            retireLaneMarker(sentence.index, epoch: epoch)
        } catch {
            retireLaneMarker(sentence.index, epoch: epoch)
            // Stop already cleared all toasts; don't repost after it.
            guard retranslateLaneCanDeliver(epoch: epoch) else { return }
            postRetranslateFailedToast(error)
        }
    }

    /// Whether a lane result captured against `epoch` may still be applied.
    /// Live: the session must be live (so a stop, or a capture restart that
    /// parks the phase in `.starting`, refuses the delivery) and must be the
    /// one the retry was clicked in. Archive mode: no phase to read — the
    /// open archive is the delivery target — and the epoch carries the
    /// whole check, since open and close both turn the lane generation over.
    /// (Internal, not private: the lane wait in `+Sessions` polls it, for
    /// the lane and for the bulk job.)
    func retranslateLaneCanDeliver(epoch: Int) -> Bool {
        guard epoch == retranslateSessionEpoch else { return false }
        if archiveOpen {
            return true
        }
        return sessionPhase == .running || sessionPhase == .sourceLost || sessionPhase == .paused
    }

    /// Retires the dim cue for a lane-owned index. Every exit that will not
    /// deliver must call this: a marker with no deliverer left dims the row
    /// and disables its retry button until session stop. Stop and a new
    /// session's begin clear the sets wholesale, but neither covers a capture
    /// restart — the phase simply parks in `.starting` while the device
    /// reopens, and a lane task crossing that window has to retire its own
    /// marker. Accepted loss: a same-session result that crosses the restart
    /// window is dropped without a toast (the row keeps its translation) —
    /// delivering mid-restart would race the transcript swap, and the
    /// alternative (a toast per dropped result) reads as an error the user
    /// did not cause.
    ///
    /// Gated on the captured epoch: retirement is the one lane operation a
    /// *stale* task still performs after its own delivery guards fail, and a
    /// blind remove by index could clobber a marker a NEW session's retry
    /// just inserted for the same (restarted-at-0) index — undimming a row
    /// whose translation is still in flight and reopening the double-click
    /// guard. A stale task's own markers were already retired by whichever
    /// boundary bumped the epoch, so skipping is always correct; the one
    /// epoch-preserving boundary (capture restart) still retires.
    private func retireLaneMarker(_ index: Int, epoch: Int) {
        guard epoch == retranslateSessionEpoch else { return }
        pendingRetranslations.remove(index)
        lanePendingRetranslations.remove(index)
    }

    // MARK: - Lane toasts

    /// Yellow auto-dismiss toast for an unavailable retry engine; the row
    /// keeps its previous translation. Private: only the lane runner posts it.
    private func postRetranslateUnavailableToast(_ body: String) {
        toasts?.post(
            key: ToastKey.retranslate, style: .yellowAuto,
            title: "Re-translate unavailable", body: body
        )
    }

    /// Shares the queue's failure copy so the two surfaces never drift.
    private func postRetranslateFailedToast(_ error: Error) {
        toasts?.post(
            key: ToastKey.retranslate, style: .yellowAuto,
            title: "Re-translate failed", body: TranslationQueue.describe(error)
        )
    }
}
