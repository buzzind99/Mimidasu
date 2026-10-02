import AppKit

/// The capture-warning cards (`audio.none`, `capture.lost`) and the System
/// Settings deep link their fix actions open. Split out of `AppModel` for the
/// file-length gate; the session wiring that posts them lives in
/// `AppModel.wireSessionController`.
extension AppModel {
    /// The `audio.none` red card with the System Settings fix action. Posted
    /// when a session's capture stays silent through its grace window —
    /// denied system-audio permission or a muted source. The first audible
    /// chunk dismisses it (`sessionController.onAudioDetected`).
    func postNoAudioWarning() {
        postPersistentCard(
            key: ToastKey.noAudio, title: "No audio detected",
            body: "No audio has been detected since the session started. "
                + "Check that audio is playing and that system audio recording "
                + "is enabled for Mimidasu in System Settings.",
            action: .init(label: "Open System Settings", handler: { [weak self] in self?.openAudioPrivacySettings() })
        )
    }

    /// Deep link into the Privacy & Security pane that owns Mimidasu's
    /// system-audio recording permission (the "Screen & System Audio
    /// Recording" list).
    static let audioPrivacySettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
    )!

    func openAudioPrivacySettings() {
        NSWorkspace.shared.open(Self.audioPrivacySettingsURL)
    }

    /// The `capture.lost` red card with the Restart-capture fix action;
    /// re-posted (deduped in place) when a restart fails.
    func postCaptureLost(body: String) {
        postPersistentCard(
            key: ToastKey.captureLost, title: "Capture lost", body: body,
            action: .init(label: "Restart capture", handler: { [weak self] in self?.restartCapture() })
        )
    }

    /// Shares red-persistent card construction between the two capture cards.
    func postPersistentCard(key: String, title: String, body: String, action: ToastCenter.Action) {
        toasts.post(key: key, style: .redPersistent, title: title, body: body, action: action)
    }
}
