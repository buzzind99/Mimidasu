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
        panel.contentView = NSHostingView(rootView: TranslationSessionHost(model: model))
        return panel
    }
}
