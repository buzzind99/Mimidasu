import AppKit
import SwiftUI
import Translation

/// Hidden helper that acquires the `TranslationSession` from SwiftUI and
/// feeds it to the queue. This is also what surfaces the one-time OS
/// language-pack download prompt.
///
/// It is hosted in a process-lifetime panel rather than the main window's
/// view tree: `.translationTask` is bound to its host view's lifetime, and
/// with the host in the main window, closing that window cancelled the task
/// and stranded the queue's pending sentences until the window reopened.
struct TranslationSessionHost: View {
    var model: AppModel

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .translationTask(model.translationConfig) { session in
                await model.translationQueue.run(with: AppleSessionEngine(session))
            }
    }
}

/// Receives the low-latency (fast model) session for alternate-engine
/// re-translations. Fired lazily: the config stays nil until the first
/// Apple-fast retry arms it, so no second OS session exists for users who
/// never use the feature. Hosted in the same process-lifetime panel as
/// `TranslationSessionHost` — the config is armed outside a session boundary
/// too (a retry can only click while one is live, but a language-pack prompt
/// must survive window churn), and it shares the panel's fullscreen/Spaces
/// guarantees.
struct RetranslateSessionHost: View {
    var model: AppModel

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .translationTask(model.retranslateConfig) { session in
                model.retranslateSessionArrived(AppleSessionEngine(session))
            }
    }
}

/// Receives the high-fidelity (Apple Intelligence) session for
/// alternate-engine re-translations. Fired lazily: the config stays nil
/// until the first Apple-Intelligence retry arms it. Hosted in the same
/// process-lifetime panel as `RetranslateSessionHost` for the same reasons.
struct RetranslateHiFiSessionHost: View {
    var model: AppModel

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .translationTask(model.retranslateHifiConfig) { session in
                model.retranslateHifiSessionArrived(AppleSessionEngine(session))
            }
    }
}

/// Owns the always-installed panel hosting `TranslationSessionHost`.
/// Mirrors `HUDWindowController`/`TranslationOverlayWindowController` minus
/// visibility control: the panel is created and ordered at bind time and
/// stays up for the process lifetime.
@MainActor
final class TranslationSessionPanelController {
    static let shared = TranslationSessionPanelController()

    private var panel: NSPanel?
    private var didBind = false

    private init() {}

    /// One-time bind: installs the session host and orders its panel. The
    /// host must exist before the first session starts and outlive every
    /// window, so there is nothing to re-bind or hide afterwards.
    func bind(model: AppModel) {
        guard !didBind else { return }
        didBind = true
        let panel = makePanel(model: model)
        panel.orderFrontRegardless()
        self.panel = panel
    }

    /// A 1×1 nonactivating, click-through panel parked in the bottom-leading
    /// corner of the visible frame: imperceptible in normal use, but any
    /// system-anchored UI (the one-time language-pack download prompt) still
    /// lands on-screen instead of clipping off-screen. `.fullScreenAuxiliary`
    /// keeps the host installed across fullscreen Spaces, so a mid-session
    /// re-fire (`fallBackToApple` invalidating the config) cannot strand the
    /// queue's pending sentences while the user is in a fullscreen app.
    private func makePanel(model: AppModel) -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        panel.setFrameOrigin(NSPoint(x: screen.minX, y: screen.minY))
        // All three session hosts in one view tree: stacking multiple
        // `.translationTask` modifiers on a single view is not reliable, and
        // a second window would duplicate the panel lifecycle for no gain.
        panel.contentView = NSHostingView(
            rootView: ZStack {
                TranslationSessionHost(model: model)
                RetranslateSessionHost(model: model)
                RetranslateHiFiSessionHost(model: model)
            }
        )
        return panel
    }
}
