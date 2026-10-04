import AppKit
import SwiftUI

@main
struct MimidasuApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        appDelegate.observeOverlayVisibility()
    }

    var body: some Scene {
        WindowGroup("Mimidasu") {
            ContentView(
                model: appDelegate.model,
                live: appDelegate.model.live,
                latency: appDelegate.model.latency
            )
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 700, height: 880)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Copy Transcript") {
                    appDelegate.model.copyTranscript()
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(!appDelegate.model.isExportable)
            }
        }

        Settings {
            SettingsView(model: appDelegate.model)
        }
        .windowStyle(.hiddenTitleBar)

        // The favorites list: a reference panel, not a preferences modal, so it
        // shares the Settings window's dismiss-on-outside-click path (see the
        // resign-key observer in `AppDelegate`). `.windowStyle(.hiddenTitleBar)`
        // is honored by this scene, and the view supplies its own header band
        // in place of a title bar. No `defaultSize`: the view fixes its own
        // frame, so `.contentSize` makes the window exactly that.
        Window("Favorites", id: "favorites") {
            FavoritesView(model: appDelegate.model)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
    }
}

/// Bridges AppKit (HUD panel) and the quit-time teardown handshake. Owns the
/// process-lifetime `AppModel`: a single instance by construction, so the
/// panels and scenes all observe the same model no matter how SwiftUI
/// re-initializes the `App` struct.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    let hud = HUDWindowController.shared
    let translationOverlay = TranslationOverlayWindowController.shared
    let translationSessionPanel = TranslationSessionPanelController.shared

    private var hudVisibilityTask: Task<Void, Never>?
    private var overlayVisibilityTask: Task<Void, Never>?

    /// Drives the overlay panels from `hudVisible` and
    /// `translationOverlayVisible` for the whole process lifetime. The
    /// flags' panel-borne mutation sites (the HUD's close and translate
    /// buttons, the translation overlay's close and subtitle buttons) sit
    /// on panels that outlive the main window, so the wiring cannot live
    /// in a scene's SwiftUI content.
    func observeOverlayVisibility() {
        hudVisibilityTask = Task { [hud] in
            for await notification in NotificationCenter.default.notifications(
                named: .mimidasuHUDVisibilityDidChange
            ) {
                guard let model = notification.object as? AppModel else { continue }
                if model.hudVisible {
                    hud.bind(model: model, live: model.live)
                }
                hud.setVisible(model.hudVisible)
            }
        }
        overlayVisibilityTask = Task { [translationOverlay] in
            for await notification in NotificationCenter.default.notifications(
                named: .mimidasuTranslationOverlayVisibilityDidChange
            ) {
                guard let model = notification.object as? AppModel else { continue }
                if model.translationOverlayVisible {
                    translationOverlay.bind(model: model)
                }
                translationOverlay.setVisible(model.translationOverlayVisible)
            }
        }
    }

    /// Upper bound on quit-time teardown: whichever arrives first — the
    /// teardown-complete notification or this watchdog — releases the quit.
    /// Sums the known drain budgets (the constants below — finish's job
    /// drain, the translation tail, and close's shorter grace) plus margin
    /// for the deliberately unbounded synchronous flush decode; a
    /// pathologically hung C call still trips the watchdog, and the user can
    /// always force-quit.
    private static let teardownWatchdogInterval: TimeInterval =
        CrispASREngine.drainTimeout + CrispASREngine.closeDrainTimeout
            + SessionController.translationDrainTimeout + 5

    private var repliedToTerminate = false
    private var teardownWatchdog: Timer?
    private var teardownCompleteObserver: NSObjectProtocol?
    private var keyWindowObserver: NSObjectProtocol?
    private var favoritesWindowObserver: NSObjectProtocol?
    private var auxiliaryCloseObserver: NSObjectProtocol?
    private var resignKeyObserver: NSObjectProtocol?
    /// The live favorites window, if any — tracks instance identity so a
    /// refocus never re-centers it, only a fresh window does.
    private weak var favoritesWindow: NSWindow?
    /// The live Settings window, if any — same instance-identity tracking as
    /// `favoritesWindow`: a sheet present/dismiss cycle re-keys the cached
    /// window without it being a fresh open.
    private weak var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The session panel is ordered here rather than at init: window
        // ordering is only guaranteed to be honored after launch completes.
        // The panel must outlive every window — with the Apple translation
        // session host in the main window's tree, closing that window
        // cancelled the translation run and stranded the queue's pending
        // sentences.
        translationSessionPanel.bind(model: model)
        keyWindowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { [weak self] note in
            let window = note.object as? NSWindow
            MainActor.assumeIsolated {
                guard let self, let window,
                      SettingsWindowController.isSettingsWindow(window)
                else { return }
                // SwiftUI's Settings scene ignores
                // `.windowStyle(.hiddenTitleBar)`, so the chrome is hidden at
                // the AppKit level when the lazily-created window becomes key
                // on open. The guard reads the post-hide state, so repeat
                // keys skip the redundant application.
                if window.titleVisibility != .hidden {
                    self.hideTitleChrome(of: window)
                }
                // Same placement contract as the favorites observer below:
                // the window belongs to the main window's Space — stationary
                // (exempt from Mission Control rearrangement), allowed to
                // coexist with the fullscreen main window's Space, and moved
                // to the active Space when activated (the opener lives in the
                // main window, so that is always the main window's Space)
                // instead of reopening where it was last closed — set at the
                // AppKit level because SwiftUI exposes no scene modifier for
                // collection behavior.
                window.collectionBehavior = [.stationary, .fullScreenAuxiliary, .moveToActiveSpace]
                // A fresh instance opens centered; rekeying an open one (a
                // sheet present/dismiss cycle) never moves it.
                if self.settingsWindow !== window {
                    self.settingsWindow = window
                    window.center()
                }
            }
        }
        // Settings and Favorites dismiss on any click outside them: losing
        // key status is exactly that — the click landed on the main window,
        // the desktop, or another app — so resign-key closes the window.
        // Favorites is matched by title: the scene has no controller to
        // register with `SettingsWindowController`, and it does not want one
        // (that type exists to tell the sidebar gear whether Settings is
        // open). A window with an attached sheet is exempt: presenting the
        // un-star confirmation moves key status to the sheet, and closing the
        // list the instant the question appeared would be its own bug.
        resignKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: nil, queue: .main
        ) { note in
            let window = note.object as? NSWindow
            MainActor.assumeIsolated {
                guard let window, window.isVisible, window.attachedSheet == nil,
                      window.title == "Favorites"
                      || SettingsWindowController.isSettingsWindow(window)
                else { return }
                window.performClose(nil)
            }
        }
        // The favorites list belongs to the main window's Space: it floats
        // over it (including fullscreen) and cannot be dragged to another
        // Space. SwiftUI exposes no scene modifier for collection behavior,
        // so it is set at the AppKit level on first key — the same bridge
        // as the settings chrome-hiding above. Title-matched: only the
        // favorites scene carries it. Stationary opts out of Mission
        // Control rearrangement; auxiliary lets the window coexist with the
        // fullscreen main window's Space; moveToActiveSpace moves it to the
        // active Space when activated (the opener lives in the main window,
        // so that is always the main window's Space) instead of reopening
        // where it was last closed. A fresh instance also opens centered;
        // refocusing the open window never moves it.
        favoritesWindowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { [weak self] note in
            let window = note.object as? NSWindow
            MainActor.assumeIsolated {
                guard let self, let window, window.title == "Favorites" else { return }
                window.collectionBehavior = [.stationary, .fullScreenAuxiliary, .moveToActiveSpace]
                if self.favoritesWindow !== window {
                    self.favoritesWindow = window
                    window.center()
                }
            }
        }
        // Both scenes cache their windows, so a reopen would restore the
        // last dragged spot. Centering on close resets it — the close and
        // the move land in the same tick, so no jump is visible.
        auxiliaryCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { note in
            let window = note.object as? NSWindow
            MainActor.assumeIsolated {
                guard let window, window.title == "Favorites"
                    || SettingsWindowController.isSettingsWindow(window)
                else { return }
                window.center()
            }
        }
    }

    private func hideTitleChrome(of window: NSWindow) {
        window.styleMask.insert(.fullSizeContentView)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        repliedToTerminate = false
        // `.common` mode: termination can land while the user is mid-gesture
        // (tracking mode), where a `.default`-mode timer would never fire.
        let interval = Self.teardownWatchdogInterval
        let watchdog = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.replyToTerminate() }
        }
        RunLoop.main.add(watchdog, forMode: .common)
        teardownWatchdog = watchdog
        teardownCompleteObserver = NotificationCenter.default.addObserver(
            forName: .mimidasuTerminationTeardownComplete, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.replyToTerminate() }
        }
        // AppModel winds the session down (flush + translation tail), then
        // releases the warm ASR engine, then posts …TeardownComplete.
        NotificationCenter.default.post(name: .mimidasuAppWillTerminate, object: nil)
        return .terminateLater
    }

    private func replyToTerminate() {
        guard !repliedToTerminate else { return }
        repliedToTerminate = true
        teardownWatchdog?.invalidate()
        teardownWatchdog = nil
        if let observer = teardownCompleteObserver {
            NotificationCenter.default.removeObserver(observer)
            teardownCompleteObserver = nil
        }
        NSApp.reply(toApplicationShouldTerminate: true)
    }
}
