import Foundation

// The session surface of `AppModel`: starting a session and bringing it up to
// `.running`, pausing and resuming it, stopping it, the quit-time teardown, and
// the ASR model selection behind the start gate.
//
// **Seam rule:** a feature file that outgrows 600 **code** lines splits at the
// next feature boundary — never mid-feature, never because it grew more
// documentation.

/// Session-start surface of `AppModel`: starting a session and bringing it
/// up to `.running`.
extension AppModel {

    // MARK: - Session control

    func start() {
        // An open archive owns the pane: a session starting underneath it
        // would upsert live results into the opened archive's id, and closing
        // the archive would wipe the live transcript. The stop-confirmation's
        // confirm path closes the archive first.
        guard openArchive == nil else { return }
        guard !isCheckingModel else { return }
        // A failed session restarts like an idle one (the sidebar offers
        // Start from `.failed`, and the failure card clears on the
        // next Start); every other active phase refuses. The quit-time latch
        // is the machine's business too.
        guard reducePhase(.startRequested).isLegal else { return }
        // "Cleared on next Start": a previous session's failure card must
        // not outlive the user pressing Start again.
        toasts.dismiss(key: ToastKey.sessionFailed)
        // A bulk translation never outlives a session start: the open-archive
        // confirmation cancels a running one first, and a completed run's
        // card clears here so no stale retry survives into live capture.
        cancelArchiveTranslation()

        Task { @MainActor in
            do {
                try await self.ensureDictionaryReady()
                try await self.beginSession()
            } catch {
                // A raced teardown (quit-time shutdown, or a stop during
                // start) already moved the phase off `.starting` and cleared
                // the toasts: a failure landing after it must not resurrect
                // a failed phase or repost over the cleared stack.
                guard self.reducePhase(.beginFailed(error.localizedDescription)).isLegal
                else { return }
                // Freeze the SESSION duration at the failure: a capture that
                // died mid-start would otherwise leave the endedAt anchor nil
                // and the frozen path reading now − startedAt per render.
                self.sessionEndedAt = .now
                self.toasts.dismiss(key: ToastKey.noAudio)
                self.toasts.post(
                    key: ToastKey.sessionFailed, style: .redPersistent,
                    title: "Session failed", body: error.localizedDescription
                )
            }
        }
    }

    private func beginSession() async throws {
        let started = try await sessionController.begin(
            modelURL: modelURL,
            modelID: asrModelSettings.selected.modelID,
            targetLang: translationSettings.targetLanguage.code
        )
        // The session may have been cancelled (or its capture lost) while
        // `begin()` was in flight. Tear down whatever begin() brought up so
        // a stopped session cannot come up anyway. The machine owns the
        // decision: a refused transition means the phase is still `.starting`
        // and the session may come up.
        let interruption = reducePhase(.beginInterruptedByTeardown)
        if interruption.requiresTeardown {
            await sessionController.stop()
            // The wind-back lands **after** the teardown: a session left in
            // `.stopping` would keep the stop confirmation, the sidebar title,
            // the archive gate and the target-language card reading
            // "stopping" forever.
            reducePhase(.teardownCompleted)
            return
        }
        guard started else {
            reducePhase(.beginReturnedNoModel)
            return
        }

        reducePhase(.beginSucceeded)
        // A source-lost card cannot survive into the session it restarted
        // (the restart path also clears it; this covers a fresh start).
        toasts.dismiss(key: ToastKey.captureLost)

        // Activate translation: an external provider's worker is spawned
        // directly; Apple goes through the hidden `.translationTask` host
        // (prompting for the language pack the first time). Invalidate the
        // config first (mirroring retryTranslation) so SwiftUI reliably
        // re-fires the task even if a config survived.
        translationQueue.resetForRetry()
        activateTranslation()

        sessionController.startTimers()
        // The silence watchdog starts counting now, not at capture start: a
        // first-launch TCC prompt keeps the session `.starting` until access
        // is granted. TCC blocks the aggregate's first IO until the prompt
        // resolves (verified on device), so no callbacks — and no staged
        // silence — occur during the wait; the `.running` flip is the first
        // moment a genuinely silent capture can be observed.
        sessionController.armNoAudioWatchdog()
    }
}

/// Pause/resume surface of `AppModel`: suspending capture while keeping the
/// session live, pause-time accounting for the displayed and stored
/// duration, and the resume path — including the deferred capture-lost
/// recovery.
extension AppModel {
    /// Suspends the running session: capture stops at the IOProc, the
    /// in-flight utterance flushes into a sentence, and the timeline and
    /// duration freeze (the duration math excludes paused spans, so the
    /// display freezes without any timer sleight of hand). Only `.running`
    /// may pause; the session controller's transition queue runs the pause
    /// and a later resume in request order, so a resume can never restart
    /// the IOProc before the pause's HAL stop landed.
    func pause() {
        guard reducePhase(.pauseRequested).isLegal else { return }
        pauseStartedAt = .now
        Task { @MainActor [weak self] in
            // The capture stop is the pause's deferred half: it runs after
            // the phase already flipped, and a stop that landed in between
            // wins the race (the machine owns the phase, this guard owns the
            // side effect).
            guard let self, phase == .paused else { return }
            await sessionController.pause()
            syncPausedToArchive()
        }
    }

    /// Resumes a paused session. A capture that died while paused is rebuilt
    /// through the capture-lost flow instead of resumed; only a failed
    /// resume/rebuild surfaces the capture-lost card. The phase stays
    /// `.paused` until the IOProc is actually back, with the machine's
    /// resume latch as the double-click guard.
    func resume() {
        guard reducePhase(.resumeRequested).isLegal else { return }
        if deferredCaptureError != nil {
            deferredCaptureError = nil
            Task { @MainActor [weak self] in
                // The rebuild waits for the controller's pause transition to
                // land: an airborne pause flush must not cut or clear the
                // freshly restarted stream's first sentence.
                await self?.sessionController.awaitPauseCompletion()
                guard let self else { return }
                guard phase == .paused else {
                    // A stop won the race: the resume is abandoned and the
                    // latch released without a phase write.
                    reducePhase(.resumeAbandoned)
                    return
                }
                finishPauseSpan()
                // The rebuild takes the session over: it moves the phase to
                // `.starting`, and the resume latch goes with it.
                performCaptureRestart()
                reducePhase(.resumeAbandoned)
            }
        } else {
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try await sessionController.resume()
                    guard reducePhase(.resumeSucceeded).isLegal else { return }
                    finishPauseSpan()
                    deferredCaptureError = nil
                    syncPausedToArchive()
                } catch {
                    let message = "Resume failed: \(error.localizedDescription)"
                    guard reducePhase(.resumeFailed(message)).isLegal else { return }
                    finishPauseSpan()
                    deferredCaptureError = nil
                    captureLostAt = .now
                    postCaptureLost(body: message)
                }
            }
        }
    }

    /// Closes the open pause span into `sessionPausedTotal` and syncs the
    /// stored paused time. Idempotent: a nil `pauseStartedAt` (already
    /// closed) only re-syncs.
    func finishPauseSpan() {
        if let pauseStartedAt {
            sessionPausedTotal += pauseStartedAt.duration(to: .now)
            self.pauseStartedAt = nil
        }
        syncPausedToArchive()
    }

    /// Persists the accumulated paused time on the live recording row (a
    /// no-op before the first sentence created it).
    func syncPausedToArchive() {
        guard let sessionID = recordingSessionID else { return }
        archiveRead.syncPaused(session: sessionID, pausedMS: Self.milliseconds(of: sessionPausedTotal))
    }

    /// The effective session start with paused spans excluded: advancing the
    /// session start by the paused time makes `durationText(from:to:)` read
    /// the active duration directly. Nil before the first session.
    func activeSessionStart(at end: ContinuousClock.Instant) -> ContinuousClock.Instant? {
        guard let sessionStartedAt else { return nil }
        var paused = sessionPausedTotal
        if let pauseStartedAt {
            paused += pauseStartedAt.duration(to: end)
        }
        return sessionStartedAt.advanced(by: paused)
    }

    /// The active (pause-excluded) session duration in milliseconds at
    /// `end`; nil before the first session. The stored `duration_ms`.
    func activeSessionDurationMS(to end: ContinuousClock.Instant) -> Int? {
        guard let start = activeSessionStart(at: end) else { return nil }
        return Self.milliseconds(of: end - start)
    }

    static func milliseconds(of duration: Duration) -> Int {
        let components = duration.components
        let fromSeconds = components.seconds * 1000
        let fromAttoseconds = components.attoseconds / 1_000_000_000_000_000
        return Int(fromSeconds + fromAttoseconds)
    }
}

/// Session-stop and quit-time teardown surface of `AppModel`: stopping a live
/// session and releasing the warm ASR engine.
extension AppModel {
    func stop() {
        // `.starting` is stoppable too: begin() is a multi-await operation
        // (TCC prompt, capture, engine), and a session the user cancels
        // mid-start must never come up afterwards. `.paused` is live: stop
        // from paused finalizes normally. The machine owns the legal-from
        // set; a refused request is a no-op, not a second teardown.
        guard reducePhase(.stopRequested).isLegal else { return }

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
        return SessionPhaseMachine.isLive(phase)
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
        // Close any open pause span first: the span folds into the session's
        // paused total (and its stored paused time) while the recording row
        // is still addressable, before the teardown nils it. Idempotent, so
        // the quit path and a resume that already closed the span are safe.
        finishPauseSpan()
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
        reducePhase(.stopCompleted)
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
        // a broadcast, so any second waiter is served by it; the machine's
        // terminating latch also keeps `start()` refused for good.
        let transition = reducePhase(.terminationStarted)
        guard transition.isLegal else { return }
        if let stopTask {
            await stopTask.value
        } else if transition.phase == .stopping {
            // The machine wound a live session down to `.stopping` (or found
            // one already winding down): the teardown runs here.
            await performStop()
        }
        retireWarmEngine()
        NotificationCenter.default.post(name: .mimidasuTerminationTeardownComplete, object: nil)
    }
}

/// ASR model-selection surface of `AppModel`: availability refresh, switching
/// the active choice, and adopting a freshly downloaded model.
extension AppModel {

    // MARK: - Availability

    /// Re-checks both model choices and moves `idle`↔`needsModel` by the
    /// active choice's result. The resolve (existence + SHA-256 verify,
    /// hashing up to ~1.2 GB) runs off-main and the result is hopped back
    /// here; `isCheckingModel` gates Start while the check is in flight.
    /// `resolve` overrides the stored resolver for tests; by default the
    /// resolver injected at init drives the lookup. The active choice's URL
    /// also lands in `modelURL` and every choice's result in
    /// `modelAvailability` (Settings rows).
    func refreshModelAvailability(
        resolve: (@Sendable (ASRModelChoice) -> URL?)? = nil
    ) async {
        let resolve = resolve ?? modelResolve
        isCheckingModel = true
        let selected = asrModelSettings.selected
        let resolved = await Task.detached(priority: .userInitiated) { () -> [ASRModelChoice: URL] in
            // Both choices resolve concurrently: each verify hashes up to
            // ~1.2 GB, and parallel keeps the wall time at the slower one
            // instead of the sum.
            await withTaskGroup(of: (ASRModelChoice, URL?).self) { group in
                for choice in ASRModelChoice.allCases {
                    group.addTask { (choice, resolve(choice)) }
                }
                var availability: [ASRModelChoice: URL] = [:]
                for await (choice, url) in group {
                    availability[choice] = url
                }
                return availability
            }
        }.value
        modelAvailability = resolved
        let url = resolved[selected]
        modelURL = url
        // The machine owns the idle↔needsModel move; the warm-up runs either
        // way — it is not gated on the phase.
        reducePhase(.modelResolved(resolved: url != nil))
        sessionController.warmUpIfNeeded(modelURL: url)
        isCheckingModel = false
    }

    // MARK: - Selection

    /// Switches the active ASR model. Only a downloaded + verified model can
    /// be selected (its resolve result must be cached), and a running or
    /// starting session must never be re-modelled mid-flight — the change
    /// applies at the next session start, like the translation provider.
    /// Persisting re-resolves (updating `modelURL` and `phase`) and re-warms
    /// the new engine in the background (`warmUpIfNeeded` re-arms on the new
    /// path).
    func selectModel(_ choice: ASRModelChoice) {
        guard phase != .running, phase != .paused, phase != .starting else { return }
        guard modelAvailability[choice] != nil else { return }
        asrModelSettings.select(choice)
        modelSelectionRefresh = Task { await refreshModelAvailability() }
    }

    /// Called after a Settings download of `choice` completes (the download
    /// button is explicit intent): re-resolves availability so the new file
    /// is hashed + verified, then auto-selects it.
    func adoptDownloadedModel(_ choice: ASRModelChoice) async {
        await refreshModelAvailability()
        selectModel(choice)
        // `selectModel` re-resolves in a tracked task; awaiting it here (one
        // extra pass, never overlapping `refreshModelAvailability`) means the
        // new model is live (modelURL + warm-up) before we return.
        await modelSelectionRefresh?.value
    }
}
