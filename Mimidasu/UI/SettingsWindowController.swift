import AppKit

/// Settings-window detection for AppKit-level tweaks — SwiftUI owns the
/// Settings scene's window, this only recognizes it. SwiftUI keeps the closed
/// Settings window cached in `NSApp.windows`, so the identifier — not mere
/// existence — is the stable signal.
@MainActor
enum SettingsWindowController {
    /// SwiftUI's Settings scene window identifier prefix.
    private static let windowID = "com_apple_SwiftUI_Settings_window"

    /// Whether a notification object is the SwiftUI Settings window. The
    /// sheet-parent guard keeps a window hosted on it (a `.sheet`) from ever
    /// matching — none borrows the prefix today, but an identifier collision
    /// would corrupt the placement tracking keyed on this matcher.
    static func isSettingsWindow(_ object: Any?) -> Bool {
        guard let window = object as? NSWindow, window.sheetParent == nil else { return false }
        return window.identifier?.rawValue.hasPrefix(windowID) == true
    }
}
