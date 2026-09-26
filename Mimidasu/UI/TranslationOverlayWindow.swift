import AppKit
import SwiftUI

/// Floating translation-only overlay: always-on-top companion of the
/// subtitle HUD, listing every finalized translation in a scrollable,
/// bottom-pinned view. Click-through when locked; unlock (padlock button)
/// to move/resize.
@MainActor
final class TranslationOverlayWindowController {
    static let shared = TranslationOverlayWindowController()

    private var panel: TranslationOverlayPanel?
    private var model: AppModel?

    private init() {}

    func bind(model: AppModel) {
        self.model = model
        if let panel {
            installContent(in: panel)
        }
    }

    func setVisible(_ visible: Bool) {
        guard visible else {
            panel?.orderOut(nil)
            return
        }
        let panel: TranslationOverlayPanel = panel ?? makePanel()
        panel.orderFrontRegardless()
    }

    // MARK: - Panel

    private func makePanel() -> TranslationOverlayPanel {
        let panel = TranslationOverlayPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 480),
            styleMask: [.borderless, .resizable, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = false
        panel.isReleasedWhenClosed = false

        // Bottom-trailing of the visible screen, clear of the
        // bottom-centered subtitle HUD.
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        panel.setFrameOrigin(
            NSPoint(x: screen.maxX - panel.frame.width - 24, y: screen.minY + 90)
        )
        installContent(in: panel)
        self.panel = panel
        return panel
    }

    private func installContent(in panel: TranslationOverlayPanel) {
        guard let model else { return }
        panel.contentView = TranslationOverlayHostingView(
            rootView: TranslationOverlayView(model: model, panel: panel)
        )
    }
}

/// Non-activating panel that owns the overlay's lock state (click-through
/// vs interactive). Mirrors `HUDPanel` minus the auto-fit refit: this
/// panel's height is the scroll viewport, sized by the user.
final class TranslationOverlayPanel: NSPanel, ObservableObject {
    @Published var locked = false {
        didSet {
            guard oldValue != locked else { return }
            // `isMovable` gates AppKit's own move paths while locked; the
            // unlocked drag is performed explicitly by
            // `TranslationOverlayHostingView.mouseDown`.
            isMovable = !locked
            if locked {
                styleMask.remove(.resizable)
            } else {
                styleMask.insert(.resizable)
            }
        }
    }
}

/// Hosts the overlay content and implements click-through via
/// hit-testing: while locked, only the top-trailing button pair (padlock
/// + close) accepts mouse events; every other point returns nil so clicks
/// land on the window underneath.
final class TranslationOverlayHostingView: NSHostingView<TranslationOverlayView> {
    /// Must mirror `TranslationOverlayView.headerButtons`' layout: two
    /// 24×24 buttons with 6pt spacing and 6pt row padding, expanded by a
    /// 4pt margin for a comfortable hit target.
    private var buttonRegion: CGRect {
        let size: CGFloat = 24
        let pad: CGFloat = 6
        let margin: CGFloat = 4
        let row: CGFloat = 2 * size + 6
        return CGRect(
            x: bounds.width - pad - row - margin,
            y: pad - margin,
            width: row + 2 * margin,
            height: size + 2 * margin
        )
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let panel = window as? TranslationOverlayPanel, panel.locked else {
            return super.hitTest(point)
        }
        let local = convert(point, from: superview)
        return buttonRegion.contains(local) ? super.hitTest(point) : nil
    }

    override func mouseDown(with event: NSEvent) {
        guard let panel = window as? TranslationOverlayPanel, !panel.locked, let window else {
            return super.mouseDown(with: event)
        }
        // Resize borders stay with AppKit: only background clicks start a
        // drag, so the unlocked panel's edges keep resizing.
        let point = convert(event.locationInWindow, from: nil)
        let border: CGFloat = 5
        if point.x < border || point.x > bounds.width - border
            || point.y < border || point.y > bounds.height - border
        {
            return super.mouseDown(with: event)
        }
        // AppKit's background drag (isMovableByWindowBackground) doesn't
        // fire for SwiftUI-hosted borderless panels, so unlocked drags
        // start explicitly here.
        window.performDrag(with: event)
    }
}
