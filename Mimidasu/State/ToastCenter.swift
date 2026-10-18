import Foundation
import Observation

/// Toast keys, one per error surface.
enum ToastKey {
    static let translationRetry = "translation.retry"
    static let translationFallback = "translation.fallback"
    static let translationUnavailable = "translation.unavailable"
    static let retranslate = "translation.retranslate"
    static let captureLost = "capture.lost"
    static let noAudio = "audio.none"
    static let sessionFailed = "session.failed"
    static let asrWarning = "asr.warning"
    static let exportFailed = "export.failed"
    static let dictionaryLookup = "dictionary.lookup"
    static let favorites = "favorites.unavailable"
    /// The archive store could not be opened or written to.
    static let archiveUnavailable = "archive.unavailable"
    /// Post-stop confirmation that the session landed as a Recent.
    static let archiveRecent = "archive.recent"
    /// The bulk archive-translation job: one card that morphs from progress
    /// into the run's summary.
    static let archiveTranslation = "archive.translation"
}

/// State behind the toast stack. Posts are deduped by key — a repeat event
/// replaces the existing card in place and resets its auto-dismiss timer
/// instead of stacking a duplicate (retry progress and ASR warnings fire
/// repeatedly) — and the stack is capped at `maxVisible` cards, dropping the
/// oldest. Owned by `AppModel`; cleared on session stop/teardown.
@Observable
@MainActor
final class ToastCenter {
    /// The toast classes: transient warnings auto-dismiss after 3 s (delay
    /// is per-center); persistent cards stay until dismissed — by their
    /// condition clearing, a fix action, or session teardown. `.info` is the
    /// neutral card (bulk-job progress and its summary): no severity tint,
    /// and whether it auto-dismisses follows its payload, not the style.
    enum Style: Equatable, Sendable {
        case yellowAuto
        case yellowPersistent
        case redPersistent
        case info

        var autoDismisses: Bool {
            switch self {
            case .yellowAuto: true
            case .yellowPersistent, .redPersistent, .info: false
            }
        }
    }

    /// A card's progress payload (the bulk job's done/total sentences).
    struct ToastProgress: Equatable, Sendable {
        var done: Int
        var total: Int
    }

    struct Action: Equatable {
        let label: String
        let handler: @MainActor () -> Void

        /// Actions compare by label only; handlers are closures.
        static func == (lhs: Action, rhs: Action) -> Bool {
            lhs.label == rhs.label
        }
    }

    struct Toast: Identifiable, Equatable {
        /// Memberwise-settable so `post`'s dedup path can preserve the
        /// replaced card's identity: with a stable id, SwiftUI updates the
        /// existing card in place instead of playing a remove+insert
        /// transition for what is a content refresh of the same toast.
        var id = UUID()
        let key: String
        let style: Style
        let title: String
        let body: String
        let action: Action?
        /// The card's progress bar payload, when it has one.
        var progress: ToastProgress?
        /// Whether the card renders its × affordance.
        var isClosable = false

        /// Whether the card auto-dismisses on the standard delay: a
        /// yellow-auto card always; an info card only as a plain summary
        /// (no progress to finish, no action to take — the all-success
        /// variant); the persistent classes never.
        var autoDismisses: Bool {
            switch style {
            case .yellowAuto: true
            case .yellowPersistent, .redPersistent: false
            case .info: progress == nil && action == nil
            }
        }
    }

    private(set) var toasts: [Toast] = []

    /// Auto-dismiss delay for `.yellowAuto` cards (timer resets when the
    /// same key re-fires).
    static let autoDismissDelay: Duration = .seconds(3)
    /// Stack cap; the oldest card is dropped beyond this.
    static let maxVisible = 3

    private let autoDismissAfter: Duration
    private let scheduler: AutoDismissScheduler
    /// Live auto-dismiss timers by toast key (cancel closures).
    private var timers: [String: @Sendable () -> Void] = [:]

    init(
        autoDismissAfter: Duration = ToastCenter.autoDismissDelay,
        scheduler: @escaping AutoDismissScheduler = AutoDismiss.timerScheduler
    ) {
        self.autoDismissAfter = autoDismissAfter
        self.scheduler = scheduler
    }

    /// Adds a toast (newest first), deduping by `key`: an existing card with
    /// the same key is replaced in place — keeping its `id` so SwiftUI treats
    /// it as a content update rather than a remove+insert — and its
    /// auto-dismiss timer reset. `isClosable` nil resolves per style and
    /// payload (`defaultIsClosable`).
    func post(
        key: String, style: Style, title: String, body: String, action: Action? = nil,
        progress: ToastProgress? = nil, isClosable: Bool? = nil
    ) {
        let closable = isClosable ?? Self.defaultIsClosable(style: style, progress: progress)
        let toast: Toast
        if let at = toasts.firstIndex(where: { toast in toast.key == key }) {
            toast = Toast(
                id: toasts[at].id, key: key, style: style,
                title: title, body: body, action: action,
                progress: progress, isClosable: closable
            )
            toasts[at] = toast
        } else {
            toast = Toast(
                key: key, style: style, title: title, body: body, action: action,
                progress: progress, isClosable: closable
            )
            toasts.insert(toast, at: 0)
        }
        if toasts.count > Self.maxVisible {
            for overflow in toasts[Self.maxVisible...] {
                timers.removeValue(forKey: overflow.key)?()
            }
            toasts.removeSubrange(Self.maxVisible...)
        }
        scheduleAutoDismiss(of: toast)
    }

    /// The × affordance's default: transient cards carry one; a persistent
    /// warning does not; an info card carries one except while it reports
    /// progress (its Cancel action is the exit there).
    static func defaultIsClosable(style: Style, progress: ToastProgress?) -> Bool {
        switch style {
        case .yellowAuto: true
        case .yellowPersistent, .redPersistent: false
        case .info: progress == nil
        }
    }

    /// Removes the card with the given key (condition cleared).
    func dismiss(key: String) {
        timers.removeValue(forKey: key)?()
        toasts.removeAll { toast in toast.key == key }
    }

    /// Clears the whole stack (session stop/teardown).
    func clearAll() {
        for cancel in timers.values {
            cancel()
        }
        timers.removeAll()
        toasts.removeAll()
    }

    /// Arms the auto-dismiss timer for transient cards. Dismissal is keyed
    /// on the toast's `id`; the guard is defense-in-depth — the timer is
    /// always cancelled before a replacement is scheduled, so a stale firing
    /// should not occur, and with the replaced card's id preserved a late
    /// fire would simply be a correct dismissal.
    private func scheduleAutoDismiss(of toast: Toast) {
        timers.removeValue(forKey: toast.key)?()
        guard toast.autoDismisses else { return }
        timers[toast.key] = scheduler(autoDismissAfter) { [weak self] in
            self?.dismiss(id: toast.id)
        }
    }

    private func dismiss(id: UUID) {
        guard let toast = toasts.first(where: { candidate in candidate.id == id }) else { return }
        dismiss(key: toast.key)
    }
}
