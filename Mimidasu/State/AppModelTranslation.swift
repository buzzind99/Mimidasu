import Foundation
import Translation

// Translation-engine façade of `AppModel`: forwarding accessors over
// `TranslationSessionCoordinator`, which owns the attach ritual, the
// manual retry, the one-way Apple fallback latch, the high-fidelity probe,
// and the provider-selection machinery. The app model keeps phase,
// entries, and toasts; the coordinator reaches them through
// `TranslationSessionPort`.

extension AppModel: TranslationSessionPort {
    // `phase` and `toasts` are stored on `AppModel`; the landing below is
    // the port's third member, and the archive checkpoints sit with it.

    /// The archived session open in the transcript pane, or nil.
    var archiveSessionID: Int64? {
        openArchive?.id
    }

    /// The language the opened archive's pane shows: the viewing-language
    /// override when one is selected, else the stored target. Read at route
    /// time, so a row retried after the viewing language switched (or after
    /// the archive closed) re-resolves against whatever is current then.
    var archiveViewingCode: String? {
        guard let archive = openArchive else { return nil }
        return archiveViewingLanguage ?? archive.summary.targetLang
    }

    /// True from the bulk job's synchronous claim (engine resolution
    /// included) until the run ends — the per-row retry guard.
    var archiveTranslationRunning: Bool {
        archiveTranslationJob.activity != .idle
    }

    /// Lands a delivered translation on its transcript row, writing the
    /// store through the one write-back seam. Internal (not private) so
    /// tests can exercise known/unknown indexes, and named exactly like the
    /// port requirement it satisfies. Routing is the entry's decision, not
    /// the caller's: it swaps the row's same-language translation in place
    /// and appends only a genuinely new language. So a repeat, an
    /// engine-swap replay, and a manual retry all land as the fresh text —
    /// none of them can grow an `" / "` pileup.
    /// Returns whether the row took the translation: false when the
    /// transcript no longer contains the index, or when an archive-mode
    /// write failed. A failed archive write leaves the row on its previous
    /// text, so the display never shows a translation the store lacks (the
    /// callers that must not act on a vanished row — the lane's cache
    /// seeding — check the return).
    @discardableResult
    func applyTranslation(index: Int, translation: SentenceTranslation) -> Bool {
        // Cleared before the row lookup: a result whose row is gone (the
        // transcript cleared underneath it) must still retire its marker,
        // or the row stays dimmed with its retry button dead.
        retranslate.clearMarkers(at: index)
        // Archive mode: the store is the durable home of the result — the
        // row update below renders it, and a reopen must find it again.
        // A live session's recording row is durable home too, but only
        // while its writes are trusted: once the per-session latch trips,
        // sentence appends stop, so a write-back would leave an orphan row.
        // Both branches funnel through the one write-back seam, which
        // precedes the row lookup so a result landing while the archive is
        // closing still persists (its marker is retired either way).
        if let archiveID = archiveSessionID {
            guard writeBackTranslation(translation, index: index, session: archiveID) else {
                // The row keeps its previous text: a displayed translation
                // the store lacks would make the next run's scope disagree
                // with the summary-derived counts.
                postArchiveWriteWarning(
                    body: Self.lostTranslationWriteWarning,
                    isClosable: true
                )
                return false
            }
        } else if let recordingID = recordingSessionID, !archiveWriteFailed {
            if !writeBackTranslation(translation, index: index, session: recordingID) {
                latchArchiveWriteFailure(
                    body: "The session store couldn't be written to. "
                        + "Sessions can't be saved or listed; transcription continues."
                )
            }
        }
        guard let at = entryPositionBySentence[index] else { return false }
        entries[at].replaceTranslation(translation)
        return true
    }
}

// MARK: - Forwarded state

extension AppModel {
    var translationConfig: TranslationSession.Configuration? {
        get { translationSession.translationConfig }
        set { translationSession.translationConfig = newValue }
    }

    var translationStatus: TranslationStatus {
        get { translationSession.translationStatus }
        set { translationSession.translationStatus = newValue }
    }

    var activeTranslationEngine: ActiveTranslationEngine {
        get { translationSession.activeTranslationEngine }
        set { translationSession.activeTranslationEngine = newValue }
    }

    var activeExternalProvider: TranslationProvider? {
        get { translationSession.activeExternalProvider }
        set { translationSession.activeExternalProvider = newValue }
    }

    var appleHighFidelityProbe: (installed: Bool, targetCode: String?) {
        get { translationSession.appleHighFidelityProbe }
        set { translationSession.appleHighFidelityProbe = newValue }
    }

    var translationFallbackActive: Bool {
        get { translationSession.translationFallbackActive }
        set { translationSession.translationFallbackActive = newValue }
    }

    var providerAwaitingDisclosure: PendingCloudDisclosure? {
        get { translationSession.providerAwaitingDisclosure }
        set { translationSession.providerAwaitingDisclosure = newValue }
    }

    /// High fidelity for the pair the labels display (see
    /// `TranslationSessionCoordinator.appleHighFidelity`).
    var appleHighFidelity: Bool {
        translationSession.appleHighFidelity
    }

    /// Whether the settings pair can offer high fidelity: the strategy API
    /// exists and no landing for this pair says it is unavailable.
    var offersAppleHighFidelity: Bool {
        translationSession.tierAvailability.offersHighFidelity(for: translationSettings.targetLanguage.code)
    }

    /// The spawned external-engine worker (`queue.run(with:)`); Apple runs
    /// belong to SwiftUI's `.translationTask` instead. Get-only by intent:
    /// the worker lifecycle (attach in `activate`, park in `sessionDidEnd`)
    /// stays inside the coordinator; outsiders only read or cancel the
    /// current task. Non-observed seam (`@ObservationIgnored` storage) —
    /// views read `translationWorkerActive` / `translationStatus` instead.
    /// The probe's supersede token lives inside `AppleTierAvailability`;
    /// no facade reaches it.
    var translationWorker: Task<Void, Never>? {
        translationSession.translationWorker
    }
}

// MARK: - Forwarded commands

extension AppModel {
    /// Retry after a translation failure (the toast's Reconnect action).
    func retryTranslation() {
        translationSession.retry()
    }

    /// Attaches the selected provider's engine to the queue — on session
    /// start, on `retryTranslation`, and on a live provider change.
    func activateTranslation() {
        translationSession.activate()
    }

    /// Applies a provider selection change while a session is live.
    func translationProviderDidChange() {
        translationSession.providerDidChange()
    }

    /// Verifies a provider's stored key, then applies the selection on
    /// success. Returns whether the key verified.
    func verifyAndSelectTranslationProvider(_ provider: TranslationProvider) async -> Bool {
        await translationSession.verifyAndSelect(provider)
    }

    /// Confirms the cloud disclosure for the sheet the user read.
    func confirmCloudDisclosure(_ presented: PendingCloudDisclosure) {
        translationSession.confirmDisclosure(presented)
    }

    /// Declines the pending cloud disclosure: nothing is recorded.
    func declineCloudDisclosure() {
        translationSession.declineDisclosure()
    }

    /// Routes queue status updates to the published state, reconciles the
    /// translation toasts, and drives the latched Apple fallback. Internal
    /// so tests can drive the queue's status callback directly.
    func handleTranslationStatus(_ status: TranslationStatus) {
        translationSession.handleStatus(status)
    }
}
