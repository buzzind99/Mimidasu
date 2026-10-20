import Foundation

/// Session-start surface of `AppModel` (file split for the lint gate):
/// starting a session and bringing it up to `.running`.
extension AppModel {

    // MARK: - Session control

    func start() {
        // An open archive owns the pane: a session starting underneath it
        // would upsert live results into the opened archive's id, and closing
        // the archive would wipe the live transcript. The stop-confirmation's
        // confirm path closes the archive first.
        guard openArchive == nil else { return }
        guard !isCheckingModel, !isTerminating else { return }
        // A failed session restarts like an idle one (the sidebar offers
        // Start from `.failed`, and the failure card clears on the
        // next Start); every other active phase refuses.
        switch phase {
        case .idle, .failed: break
        default: return
        }
        phase = .starting
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
                guard self.phase == .starting else { return }
                self.phase = .failed(error.localizedDescription)
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
        // a stopped session cannot come up anyway.
        guard phase == .starting else {
            await sessionController.stop()
            if phase == .stopping {
                phase = .idle
            }
            return
        }
        guard started else {
            phase = .needsModel
            return
        }

        phase = .running
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
