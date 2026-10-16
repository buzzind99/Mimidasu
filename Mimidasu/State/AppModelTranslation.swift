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
    // the port's third member.

    /// Lands a delivered translation on its transcript row. Internal (not
    /// private) so tests can exercise known/unknown indexes, and named
    /// exactly like the port requirement it satisfies. Routing is the
    /// entry's decision, not the caller's: it swaps the row's
    /// same-language translation in place and appends only a genuinely new
    /// language. So a repeat, an engine-swap replay, and a manual retry all
    /// land as the fresh text — none of them can grow an `" / "` pileup.
    /// Returns whether the row was still present; a false return means the
    /// transcript no longer contains the index (the callers that must not
    /// act on a vanished row — the lane's cache seeding — check it).
    @discardableResult
    func applyTranslation(index: Int, translation: SentenceTranslation) -> Bool {
        // Cleared before the row lookup: a result whose row is gone (the
        // transcript cleared underneath it) must still retire its marker,
        // or the row stays dimmed with its retry button dead.
        retranslate.clearMarkers(at: index)
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

    /// The spawned external-engine worker (`queue.run(with:)`); Apple runs
    /// belong to SwiftUI's `.translationTask` instead. Get-only by intent:
    /// the worker lifecycle (attach in `activate`, park in `sessionDidEnd`)
    /// stays inside the coordinator; outsiders only read or cancel the
    /// current task. Non-observed seam (`@ObservationIgnored` storage) —
    /// views read `translationWorkerActive` / `translationStatus` instead.
    /// The probe sequence token (`highFidelitySequence`) stays
    /// coordinator-private with no facade: no test needs to reach it.
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

    /// The real high-fidelity probe: whether `LanguageAvailability` reports
    /// the Apple Intelligence strategy installed for ja→`targetCode`.
    nonisolated static func checkHighFidelityAvailability(targetCode: String) async -> Bool {
        await TranslationSessionCoordinator.checkHighFidelityAvailability(targetCode: targetCode)
    }
}
