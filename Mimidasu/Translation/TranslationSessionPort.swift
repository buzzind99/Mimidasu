import Foundation

/// The app-model state the translation coordinators act through — the port
/// side of the coordination seam. `TranslationSessionCoordinator` owns every
/// engine, fallback, and probe field and `RetranslateCoordinator` owns the
/// lane; phase, transcript entries, and toasts stay with the host, which the
/// coordinators reach through this port.
@MainActor
protocol TranslationSessionPort: AnyObject {
    /// The session phase gating provider re-attachment and lane delivery:
    /// both act only while a session is live (`.running` / `.sourceLost`).
    var phase: SessionPhase { get }

    /// The visible toast stack — translation retry/degraded/unavailable
    /// cards and the lane's notifications are posted and dismissed here.
    var toasts: ToastCenter { get }

    /// The archived session open in the transcript pane, or nil. Non-nil
    /// widens the lane's gate beyond the live phases and switches its route
    /// to dedicated alternates (the archive pane's retry buttons).
    var archiveSessionID: Int64? { get }

    /// The language the opened archive's pane shows: the viewing-language
    /// override when one is selected, else the archive's stored target (nil
    /// with no archive, or one stored without a target). One language at a
    /// time in archive mode — this is the lane's target and the rows'
    /// display language.
    var archiveViewingCode: String? { get }

    /// True while the bulk archive-translation job is claimed — engine
    /// resolution included — until the run ends. Per-row retries are refused
    /// then (a session-backed Apple engine must never see concurrent calls).
    var archiveTranslationRunning: Bool { get }

    /// Lands a delivered translation on its transcript row and retires the
    /// row's re-translation marker. Reports whether the row was still
    /// present (a result whose row vanished must not seed the queue cache).
    @discardableResult
    func applyTranslation(index: Int, translation: SentenceTranslation) -> Bool

    /// Starts the bulk archive-translation run the cloud disclosure just
    /// confirmed (the held external selection, mapped to its engine). A no-op
    /// while a run is claimed or no archive is open.
    func beginArchiveTranslation(engine: RetranslateEngine, lang: String)
}
