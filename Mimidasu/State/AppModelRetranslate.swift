import Foundation
import Translation

// Re-translate lane surface of `AppModel` (route resolution, the serialized
// alternate-engine runner, the dedicated fast-model and Apple Intelligence
// sessions, and the lane toasts), split out to keep `AppModel.swift` under
// the 600-line lint gate.

extension AppModel {

    // MARK: - Engine identity

    /// Engine identity of the live caption path — the row marker's
    /// comparison target. Externals map from the attached provider; the
    /// Apple branch reads the strategy probe (installed-for-pair semantics
    /// of `appleHighFidelityProbe`). Below 26.4 the fast model is the only
    /// model. Until a probe lands, every Apple activation holds the tuple at
    /// `(false, nil)`, so the Apple branch reads `.appleFast` *provisionally*
    /// — the marker rule compensates by not comparing against a provisional
    /// identity, and `liveSessionRunsKind` refuses the provisional read
    /// outright so routing never acts on it.
    var activeEngineKind: TranslationEngineKind {
        if activeTranslationEngine == .external, let provider = activeExternalProvider {
            // The attached provider is external by construction; only Apple
            // maps to nil.
            return TranslationEngineKind(provider: provider) ?? .appleFast
        }
        if #available(macOS 26.4, *),
           appleHighFidelityProbe.installed,
           appleHighFidelityProbe.targetCode == translationSettings.targetLanguage.code
        {
            return .appleHighFidelity
        }
        return .appleFast
    }

    /// True when the live Apple session runs the given Apple kind. On 26.4+
    /// the identity is UNKNOWN until the activation probe lands (every
    /// activation resets the tuple to `(false, nil)`), and an unlanded
    /// identity must not route: a provisional `.appleFast` read would send a
    /// fast retry to a live high-fidelity session (unstamped wrong-engine
    /// text) and a high-fidelity retry to a duplicate of the live session —
    /// the byte-identical no-op that reads as a broken button. Callers
    /// treat `false` as "not provably the same engine": the click defers to
    /// the dedicated session and the lane re-routes on the landing. Below
    /// 26.4 the identity never depends on the probe.
    func liveSessionRunsKind(_ kind: TranslationEngineKind) -> Bool {
        guard activeTranslationEngine == .apple else { return false }
        if #available(macOS 26.4, *) {
            guard appleProbeLanded else { return false }
        }
        return activeEngineKind == kind
    }

    /// Whether the activation probe has landed FOR THE CURRENT TARGET — the
    /// live Apple session's model identity is only knowable once it has.
    private var appleProbeLanded: Bool {
        appleHighFidelityProbe.targetCode == translationSettings.targetLanguage.code
    }

    /// High fidelity is *known* unavailable when the last probe landed for the
    /// current target and reported it not installed. Deliberately narrower
    /// than `appleHighFidelity == false`: a probe that never landed
    /// (`targetCode == nil`) or one run for a different target is not evidence
    /// of unavailability, and treating it as such would hide the feature on a
    /// capable machine for the whole probe window.
    var highFidelityKnownUnavailable: Bool {
        appleHighFidelityProbe.targetCode == translationSettings.targetLanguage.code
            && !appleHighFidelityProbe.installed
    }

    /// The Apple model the re-translate selection can actually deliver, which
    /// is not always the selected one. `.appleHighFidelity` names a strategy
    /// the OS may not be able to serve: where the ja→target pair is not
    /// `.installed` for it, `makeRetranslateConfig` still requests high
    /// fidelity and the framework silently falls back to the fast model (the
    /// same caveat `makeTranslationConfig` documents). Requesting it anyway
    /// would return text byte-identical to a live fast session while stamping
    /// the row `.appleHighFidelity` — a "· via Apple Intelligence" marker over
    /// fast-model output. So a *known*-unavailable high-fidelity route degrades
    /// to the fast model, which is a genuine alternate.
    ///
    /// Below 26.4 there is no strategy API at all, so high fidelity cannot be
    /// requested and the selection always degrades. Every consumer switches on
    /// the effective selection, so the persisted `.appleHighFidelity` is never
    /// rewritten; only its resolution degrades.
    var effectiveRetranslateSelection: RetranslateEngine {
        let selection = translationSettings.retranslateEngine
        guard selection == .appleHighFidelity else { return selection }
        guard #available(macOS 26.4, *) else { return .appleFast }
        return highFidelityKnownUnavailable ? .appleFast : .appleHighFidelity
    }

    /// True when the configured retry engine resolves to an engine *other
    /// than* the live session engine — the transcript's retry button drops
    /// its worker/status requirements in that case (a dead session engine is
    /// exactly when routing the retry elsewhere is useful). A selection that
    /// names the live session's own engine is not an alternate: the lane
    /// would run the identical engine (for Apple, a deterministic one) and
    /// show no marker.
    var alternateRetranslateEngineActive: Bool {
        switch effectiveRetranslateSelection {
        case .session:
            return false
        case .appleFast:
            return !liveSessionRunsKind(.appleFast)
        case .appleHighFidelity:
            return !liveSessionRunsKind(.appleHighFidelity)
        case let selection:
            guard let provider = selection.provider,
                  provider != activeExternalProvider
            else { return false }
            return translationSettings.hasKey(for: provider)
        }
    }

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
    /// what a user reaches for then.
    func retranslateSentence(_ sentence: Sentence) {
        guard phase == .running || phase == .sourceLost else { return }
        guard !pendingRetranslations.contains(sentence.index),
              !translationQueue.isAwaitingTranslation(sentence)
        else { return }
        switch resolveRetranslateRoute() {
        case .session:
            // Today's path verbatim: the queue owns the retry (cache evicted,
            // re-enqueued) and the result lands unstamped — never marked.
            guard translationQueue.hasWorker else { return }
            pendingRetranslations.insert(sentence.index)
            translationQueue.retranslate(sentence)
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
            // result with an unstamped one.
            translationQueue.dropPending(sentence)
            runRetranslateLane(sentence, kind: kind, engine: engine)
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

    /// Outcome of resolving the lane's engine. `.timedOut` and `.cancelled`
    /// are distinct on purpose: the timeout reports a still-starting session,
    /// while a cancellation is a user-initiated stop whose toasts are already
    /// cleared, so reporting it would post a stray message.
    private enum LaneEngineResolution {
        case ready(any TranslationEngine)
        case timedOut
        case cancelled
    }

    private func resolveRetranslateRoute() -> RetranslateRoute {
        let selection = effectiveRetranslateSelection
        switch selection {
        case .session:
            return .session
        case .appleFast:
            return resolveAppleModelRoute(.appleFast)
        case .appleHighFidelity:
            return resolveAppleModelRoute(.appleHighFidelity)
        case .google, .deepl, .openrouter:
            guard let provider = selection.provider else { return .session }
            // A selection naming the attached provider IS the session
            // engine — the queue path serves it (externals sample, so a
            // re-run can still differ, but it is no longer an alternate).
            if provider == activeExternalProvider {
                return .session
            }
            let engine = laneExternalEngine(for: provider)
            guard let engine else {
                return .unavailable("No API key stored for \(provider.displayName).")
            }
            // The provider is external here, so the kind mapping is total
            // (only Apple maps to nil); the fallback mirrors the live-identity
            // read in `activeEngineKind`.
            return .alternate(TranslationEngineKind(provider: provider) ?? .appleFast, engine: engine)
        }
    }

    private func resolveAppleModelRoute(_ kind: TranslationEngineKind) -> RetranslateRoute {
        guard #available(macOS 26.4, *) else {
            // Below 26.4 there is one Apple model (fast, no strategy API):
            // high fidelity does not exist, and a live Apple session already
            // runs the fast model. With an external live session the fast
            // model is a genuine alternate via a plain (fast-by-definition)
            // session. The `kind == .appleHighFidelity` test here is
            // unreachable via callers — `effectiveRetranslateSelection`
            // already degrades the selection below 26.4 — and exists only as
            // defense in depth; do not "simplify" it away together with that
            // degrade.
            return kind == .appleHighFidelity || liveSessionRunsKind(.appleFast)
                ? .session : armedRoute(kind)
        }
        // A live Apple session running the same model de facto would return
        // byte-identical text with no marker — a no-op that reads as a
        // broken button. The session engine serves instead. While the probe
        // is unlanded the identity is unknown (see `liveSessionRunsKind`),
        // so the click routes to the dedicated session and the lane
        // re-routes on the landing — a same-engine retry is handed to the
        // queue path there.
        if liveSessionRunsKind(kind) {
            return .session
        }
        return armedRoute(kind)
    }

    private func armedRoute(_ kind: TranslationEngineKind) -> RetranslateRoute {
        // Arming is optimistic: if the dedicated session is still starting,
        // the lane waits for it (bounded) instead of blocking the click.
        armRetranslateSessionIfNeeded(for: kind)
        return .alternate(kind, engine: laneEngineStorage(for: kind))
    }

    /// Builds the lane's external engine. The test factory is authoritative
    /// when set: a nil result means "unavailable" (no key), never a
    /// fall-through to the real engine.
    private func laneExternalEngine(for provider: TranslationProvider) -> (any TranslationEngine)? {
        if let factory = retranslateEngineFactory {
            return factory(provider)
        }
        return makeExternalEngine(for: provider)
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
        _ sentence: Sentence, kind: TranslationEngineKind, engine: (any TranslationEngine)?
    ) {
        let previous = retranslateLaneTask
        // The session this retry belongs to. See `retranslateSessionEpoch`: a
        // lane task outliving its session would otherwise land on an
        // unrelated row of the next one, whose indexes restart at 0.
        let epoch = retranslateSessionEpoch
        retranslateLaneTask = Task { [weak self] in
            await previous?.value
            // A deallocated model has no markers left to retire, so the weak
            // unwrap is the only exit that skips `retireLaneMarker`.
            guard let self else { return }
            guard retranslateLaneCanDeliver(epoch: epoch) else {
                retireLaneMarker(sentence.index, epoch: epoch)
                return
            }
            // Probe deferral — high-fidelity lanes only (see doc above).
            let laneKind: TranslationEngineKind
            switch await probeGate(for: kind, epoch: epoch, sentence: sentence) {
            case .done:
                return
            case let .proceed(resolvedKind):
                laneKind = resolvedKind
            }
            let resolved = await laneEngine(engine, kind: laneKind, epoch: epoch)
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
                        : "Apple (MTL) session is still starting — try again in a moment."
                )
                return
            case let .ready(engine):
                // The wait may have consumed the stop window; re-check before
                // flying so a stopped session never issues an engine call.
                guard retranslateLaneCanDeliver(epoch: epoch) else {
                    retireLaneMarker(sentence.index, epoch: epoch)
                    return
                }
                await fly(sentence, through: engine, kind: laneKind, epoch: epoch)
            }
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
    /// timeout.
    private func probeGate(
        for kind: TranslationEngineKind, epoch: Int, sentence: Sentence
    ) async -> ProbeGateOutcome {
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
            guard retranslateLaneCanDeliver(epoch: epoch) else {
                retireLaneMarker(sentence.index, epoch: epoch)
                return .done
            }
            // The landing can change the selection's resolution — a
            // not-installed landing degrades a high-fidelity
            // selection to the fast model, whose dedicated session
            // this lane must then arm and wait on instead.
            let laneKind = kindAfterProbeLanding(kind)
            if liveSessionRunsKind(laneKind) {
                handRetranslateToSession(sentence)
                return .done
            }
            if laneKind != kind {
                armRetranslateSessionIfNeeded(for: laneKind)
            }
            return .proceed(laneKind)
        }
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

    /// The lane's Apple kind once the probe has landed: the click-time kind,
    /// unless a not-installed landing degrades a high-fidelity selection to
    /// the fast model — the same resolution `effectiveRetranslateSelection`
    /// applies once the probe has landed.
    private func kindAfterProbeLanding(_ kind: TranslationEngineKind) -> TranslationEngineKind {
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
        guard translationQueue.hasWorker else {
            pendingRetranslations.remove(sentence.index)
            postRetranslateUnavailableToast(
                "No translation engine attached — try again in a moment."
            )
            return
        }
        translationQueue.retranslate(sentence)
    }

    /// Runs the engine call and lands (or reports) the result. Split out of
    /// the lane task so the `do`/`catch` stays legible next to the guards.
    private func fly(
        _ sentence: Sentence, through engine: any TranslationEngine,
        kind: TranslationEngineKind, epoch: Int
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
                lang: translationSettings.targetLanguage.code,
                text: text,
                engine: kind
            )
            let landed = applyTranslation(index: sentence.index, translation: pair)
            // Seed the repeat-sentence cache with the retried *text* unstamped:
            // a fresh row repeating the sentence serves through the normal
            // queue path without the lane's provenance marker. Seeded only
            // when the row actually took the result — `applyTranslation`
            // reports whether the row was still present, so a result whose
            // row vanished (transcript cleared underneath it) never leaves
            // the retried text in the cache.
            if landed {
                translationQueue.seedCache(sentence, pair)
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

    /// Whether a lane result captured against `epoch` may still be applied:
    /// the session must be live (so a stop, or a capture restart that parks
    /// the phase in `.starting`, refuses the delivery) and must be the one
    /// the retry was clicked in.
    private func retranslateLaneCanDeliver(epoch: Int) -> Bool {
        (phase == .running || phase == .sourceLost) && epoch == retranslateSessionEpoch
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

    /// Resolves the lane's engine: a built engine passes through; nil (an
    /// Apple selection while its dedicated session is still arming) waits a
    /// bounded interval for the `.translationTask` host to hand one over —
    /// acquisition is sub-second once armed, the bound only catches
    /// pathological cases. The deadline is monotonic (`ContinuousClock`) —
    /// wall-clock `Date` would skew on clock changes. A lane that dies
    /// mid-wait (stop, teardown) exits promptly instead of polling its
    /// nilled storage out the whole arm window.
    private func laneEngine(
        _ engine: (any TranslationEngine)?, kind: TranslationEngineKind, epoch: Int
    ) async -> LaneEngineResolution {
        if let engine {
            return .ready(engine)
        }
        let deadline = ContinuousClock.now + laneArmTimeout
        // Polls the storage the loop exits on and returns that same value: a
        // re-read after the loop would race a teardown and read nil as a
        // timeout.
        var resolved = laneEngineStorage(for: kind)
        while resolved == nil, ContinuousClock.now < deadline {
            guard retranslateLaneCanDeliver(epoch: epoch) else { return .cancelled }
            do {
                try await Task.sleep(for: Duration.milliseconds(50))
            } catch {
                return .cancelled
            }
            resolved = laneEngineStorage(for: kind)
        }
        guard let resolved else { return .timedOut }
        return .ready(resolved)
    }

    // MARK: - Settings selection

    /// Settings card selection. The on-device rows complete immediately; an
    /// external row holds its intent behind the cloud disclosure sheet —
    /// same semantics as provider switching, no persisted acknowledgment.
    func selectRetranslateEngine(_ engine: RetranslateEngine) {
        switch engine {
        case .session, .appleFast, .appleHighFidelity:
            translationSettings.selectRetranslate(engine)
        case .google, .deepl, .openrouter:
            guard let provider = engine.provider else { return }
            providerAwaitingDisclosure = .retranslateEngine(provider)
        }
    }

    // MARK: - Lane toasts

    /// Yellow auto-dismiss toast for an unavailable retry engine; the row
    /// keeps its previous translation.
    func postRetranslateUnavailableToast(_ body: String) {
        toasts.post(
            key: ToastKey.retranslate, style: .yellowAuto,
            title: "Re-translate unavailable", body: body
        )
    }

    /// Shares the queue's failure copy so the two surfaces never drift.
    private func postRetranslateFailedToast(_ error: Error) {
        toasts.post(
            key: ToastKey.retranslate, style: .yellowAuto,
            title: "Re-translate failed", body: TranslationQueue.describe(error)
        )
    }
}
