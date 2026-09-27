import Foundation

/// Overlay-visibility surface of `AppModel` (file split for the lint gate):
/// the master switch behind the sidebar's overlay button and the highlight
/// state it renders.
extension AppModel {
    /// True while any floating overlay (the subtitle HUD or the
    /// translation-only overlay) is on screen — the sidebar overlay
    /// button's highlight.
    var anyOverlayVisible: Bool {
        hudVisible || translationOverlayVisible
    }

    /// Master switch behind the sidebar's overlay button: any overlay open
    /// counts as on, so pressing closes both; with everything closed,
    /// pressing reopens the subtitle overlay only.
    func toggleOverlays() {
        if anyOverlayVisible {
            hudVisible = false
            translationOverlayVisible = false
        } else {
            hudVisible = true
        }
    }
}
