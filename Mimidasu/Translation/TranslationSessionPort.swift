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

    /// Lands a delivered translation on its transcript row and retires the
    /// row's re-translation marker. Reports whether the row was still
    /// present (a result whose row vanished must not seed the queue cache).
    @discardableResult
    func applyTranslation(index: Int, translation: SentenceTranslation) -> Bool
}
