import Foundation
import Translation

// Re-translate lane surface of `AppModel` (route resolution, the serialized
// alternate-engine runner, the dedicated fast-model and Apple Intelligence
// sessions, and the lane toasts), split out to keep `AppModel.swift` under
// the 600-line lint gate.

/// The intent held behind the cloud disclosure sheet: completing a provider
/// switch (the live translation engine) or a re-translate engine selection.
/// Both raise the same sheet with the same semantics — raised on every
/// selection, no persisted acknowledgment.
enum PendingCloudDisclosure: Equatable, Identifiable {
    case providerSwitch(TranslationProvider)
    case retranslateEngine(TranslationProvider)

    var id: String {
        switch self {
        case let .providerSwitch(provider): "switch.\(provider.rawValue)"
        case let .retranslateEngine(provider): "retranslate.\(provider.rawValue)"
        }
    }

    var provider: TranslationProvider {
        switch self {
        case let .providerSwitch(provider): provider
        case let .retranslateEngine(provider): provider
        }
    }
}

extension AppModel {

    // MARK: - Engine identity

    /// Engine identity of the live caption path — the row marker's
    /// comparison target. Externals map from the attached provider; the
    /// Apple branch reads the strategy probe (installed-for-pair semantics
    /// of `appleHighFidelityProbe`). Below 26.4 the fast model is the only
    /// model. Until a probe lands, every Apple activation holds the tuple at
    /// `(false, nil)`, so the Apple branch reads `.appleFast` *provisionally*
    /// — the marker rule compensates by not comparing against a provisional
    /// identity.
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

    /// True when the live Apple session runs the given Apple kind — the
    /// marker's provisional-identity caveat applies until the probe lands
    /// (every Apple activation holds the tuple at `(false, nil)`, so the
    /// branch reads `.appleFast` provisionally).
    func liveSessionRunsKind(_ kind: TranslationEngineKind) -> Bool {
        activeTranslationEngine == .apple && activeEngineKind == kind
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
            // session.
            return kind == .appleHighFidelity || liveSessionRunsKind(.appleFast)
                ? .session : armedRoute(kind)
        }
        // A live Apple session running the same model de facto would return
        // byte-identical text with no marker — a no-op that reads as a
        // broken button. The session engine serves instead.
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
                retireLaneMarker(sentence.index)
                return
            }
            let resolved = await laneEngine(engine, kind: kind)
            switch resolved {
            case .cancelled:
                // The stop already cleared every toast; a "still starting"
                // message here would outlive it and misreport a cancellation.
                retireLaneMarker(sentence.index)
                return
            case .timedOut:
                // The dedicated Apple session is still starting (or a
                // first-use language-pack prompt is up). The config stays
                // armed, so the next click is instant once it lands. Only
                // Apple selections can arrive here — externals build their
                // engine (or fail) at resolve time.
                retireLaneMarker(sentence.index)
                postRetranslateUnavailableToast(
                    kind == .appleHighFidelity
                        ? "Apple Intelligence session is still starting — try again in a moment."
                        : "Apple (MTL) session is still starting — try again in a moment."
                )
                return
            case let .ready(engine):
                // The wait may have consumed the stop window; re-check before
                // flying so a stopped session never issues an engine call.
                guard retranslateLaneCanDeliver(epoch: epoch) else {
                    retireLaneMarker(sentence.index)
                    return
                }
                await fly(sentence, through: engine, kind: kind, epoch: epoch)
            }
        }
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
                retireLaneMarker(sentence.index)
                return
            }
            guard let text = results.first else {
                throw TranslationEngineError.badResponse("Expected 1 translation, got 0")
            }
            let pair = SentenceTranslation(
                lang: translationSettings.targetLanguage.code,
                text: text,
                engine: kind
            )
            applyTranslation(index: sentence.index, translation: pair)
            // Seed the repeat-sentence cache with the retried *text* unstamped:
            // a fresh row repeating the sentence serves through the normal
            // queue path without the lane's provenance marker. Seeded AFTER the
            // row lands, so a result whose row vanished (transcript cleared
            // underneath it) never leaves the retried text in the cache.
            translationQueue.seedCache(sentence, pair)
        } catch is CancellationError {
            retireLaneMarker(sentence.index)
        } catch {
            retireLaneMarker(sentence.index)
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
    /// marker.
    private func retireLaneMarker(_ index: Int) {
        pendingRetranslations.remove(index)
        lanePendingRetranslations.remove(index)
    }

    /// Resolves the lane's engine: a built engine passes through; nil (an
    /// Apple selection while its dedicated session is still arming) waits a
    /// bounded interval for the `.translationTask` host to hand one over —
    /// acquisition is sub-second once armed, the bound only catches
    /// pathological cases. The deadline is monotonic (`ContinuousClock`) —
    /// wall-clock `Date` would skew on clock changes.
    private func laneEngine(
        _ engine: (any TranslationEngine)?, kind: TranslationEngineKind
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

    // MARK: - Dedicated Apple sessions

    /// ja→target configuration for one of the dedicated re-translate
    /// sessions. Mirrors `makeTranslationConfig` except the strategy, which
    /// is set EXPLICITLY on 26.4+ — the property's default follows the SDK
    /// the app was built against, which would hand both lanes the same
    /// model as the live session and return byte-identical text, defeating
    /// the feature. Below 26.4 the config stays plain (the session is the
    /// fast model by definition).
    func makeRetranslateConfig(highFidelity: Bool) -> TranslationSession.Configuration {
        var config = TranslationSession.Configuration(
            source: Locale.Language(identifier: "ja"),
            target: Locale.Language(identifier: translationSettings.targetLanguage.code)
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
    private func laneEngineStorage(
        for kind: TranslationEngineKind
    ) -> (any TranslationEngine)? {
        kind == .appleHighFidelity ? retranslateHifiSessionEngine : retranslateSessionEngine
    }

    /// Arms the kind's dedicated session on the first retry through it.
    /// Never reassigns an armed config: reassignment is a path SwiftUI's
    /// `.translationTask` may not reliably re-fire on, and a timeout keeps
    /// the config armed so the next click is instant once the session (or
    /// its language-pack download) lands.
    func armRetranslateSessionIfNeeded(for kind: TranslationEngineKind) {
        switch kind {
        case .appleFast:
            guard retranslateConfig == nil else { return }
            retranslateConfig = makeRetranslateConfig(highFidelity: false)
        case .appleHighFidelity:
            guard retranslateHifiConfig == nil else { return }
            retranslateHifiConfig = makeRetranslateConfig(highFidelity: true)
        case .google, .deepl, .openrouter:
            break // externals build their engine at click time; no session
        }
    }

    /// Stores the fast-model session handed over by the second
    /// `.translationTask` host. Does not run the queue — the lane is the
    /// only consumer. Takes the engine existential (the host passes the
    /// `AppleSessionEngine` wrapper) so tests can hand over a mock.
    func retranslateSessionArrived(_ engine: any TranslationEngine) {
        retranslateSessionEngine = engine
    }

    /// Stores the Apple Intelligence session handed over by the third
    /// `.translationTask` host. Does not run the queue.
    func retranslateHifiSessionArrived(_ engine: any TranslationEngine) {
        retranslateHifiSessionEngine = engine
    }

    /// Drops both armed-session states (configs + stored engines). Called
    /// from every Apple activation and from `performStop`. Within a session
    /// an armed config is always current — target changes are restart-only
    /// — so the reset covers the session boundary: a next session on an
    /// external provider never takes the Apple branch, and a config armed
    /// for a prior target must not survive to serve it.
    func teardownRetranslateSession() {
        retranslateConfig?.invalidate()
        retranslateConfig = nil
        retranslateSessionEngine = nil
        retranslateHifiConfig?.invalidate()
        retranslateHifiConfig = nil
        retranslateHifiSessionEngine = nil
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
