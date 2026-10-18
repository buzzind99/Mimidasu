import Foundation

/// Pause/resume surface of `AppModel` (file split for the lint gate):
/// suspending capture while keeping the session live, pause-time accounting
/// for the displayed and stored duration, and the resume path — including
/// the deferred capture-lost recovery.
extension AppModel {
    /// Suspends the running session: capture stops at the IOProc, the
    /// in-flight utterance flushes into a sentence, and the timeline and
    /// duration freeze (the duration math excludes paused spans, so the
    /// display freezes without any timer sleight of hand). Only `.running`
    /// may pause; the transition task is chained through
    /// `pauseTransitionTask` so a resume can never restart the IOProc before
    /// the pause's HAL stop landed.
    func pause() {
        guard phase == .running else { return }
        phase = .paused
        pauseStartedAt = .now
        let previous = pauseTransitionTask
        pauseTransitionTask = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, phase == .paused else { return }
            await sessionController.pause()
            syncPausedToArchive()
        }
    }

    /// Resumes a paused session. A capture that died while paused is rebuilt
    /// through the capture-lost flow instead of resumed; only a failed
    /// resume/rebuild surfaces the capture-lost card. The phase stays
    /// `.paused` until the IOProc is actually back, with `resumeInFlight`
    /// as the double-click guard.
    func resume() {
        guard phase == .paused, !resumeInFlight else { return }
        resumeInFlight = true
        let previous = pauseTransitionTask
        if deferredCaptureError != nil {
            deferredCaptureError = nil
            finishPauseSpan()
            performCaptureRestart()
            pauseTransitionTask = Task { @MainActor [weak self] in
                await previous?.value
                self?.resumeInFlight = false
            }
        } else {
            pauseTransitionTask = Task { @MainActor [weak self] in
                await previous?.value
                guard let self else { return }
                do {
                    try await sessionController.resume()
                    resumeInFlight = false
                    guard phase == .paused else { return }
                    finishPauseSpan()
                    phase = .running
                    syncPausedToArchive()
                } catch {
                    resumeInFlight = false
                    guard phase == .paused else { return }
                    finishPauseSpan()
                    phase = .sourceLost
                    captureLostAt = .now
                    postCaptureLost(body: "Resume failed: \(error.localizedDescription)")
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
        archive.syncPaused(session: sessionID, pausedMS: Self.milliseconds(of: sessionPausedTotal))
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
