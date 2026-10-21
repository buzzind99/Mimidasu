import AppKit
import Foundation

// The presentation surface of `AppModel`: the floating-overlay switch, the
// session export (plain-text copy and the four file formats), and the
// capture-warning cards with their fix actions.
//
// **Seam rule:** a feature file that outgrows 600 **code** lines splits at the
// next feature boundary — never mid-feature, never because it grew more
// documentation.

/// Overlay-visibility surface of `AppModel`: the master switch behind the
/// sidebar's overlay button and the highlight state it renders.
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

/// Export surface of `AppModel` (plain-text copy + the four file formats
/// behind the export menu).
extension AppModel {
    var isExportable: Bool {
        !entries.isEmpty
    }

    func exportText() -> String {
        SessionExporter.plainText(entries: entries)
    }

    /// Shared by the ⌘⇧C command and the export menu.
    func copyTranscript() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(exportText(), forType: .string)
    }

    /// Backs the sidebar cursor-mode `.copy` behavior.
    func copySnippet(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        notices.post(message: "Text copied")
    }

    func export(format: SessionExporter.Format) throws -> Data {
        switch format {
        case .txt:
            return Data(SessionExporter.plainText(entries: entries).utf8)
        case .srt:
            return Data(SessionExporter.subtitles(entries: entries, format: .srt).utf8)
        case .vtt:
            return Data(SessionExporter.subtitles(entries: entries, format: .vtt).utf8)
        case .json:
            let results = snapshotTranslationResults()
            return try SessionExporter.json(
                entries: entries, metadata: exportMetadata, results: results
            )
        }
    }

    /// The fileExporter's suggested filename stem: the open archive's name
    /// when it has one — sanitized for the filesystem — else the shared
    /// default. The auto-title is deliberately not used: it embeds 「」 and a
    /// date, which reads as noise in a save dialog.
    var exportFilenameBase: String {
        guard let name = openArchive?.summary.name,
              let sanitized = SessionExporter.sanitizedFilenameStem(name)
        else { return "mimidasu-session" }
        return sanitized
    }

    /// The metadata the JSON export stamps: the open archive's stored
    /// session when one fills the pane — the live controller's metadata
    /// belongs to a session the archive replaced — else the live session's.
    /// Nil without either (the exporter's defaults apply).
    private var exportMetadata: SessionMetadata? {
        guard let summary = openArchive?.summary else {
            return sessionController.sessionMetadata
        }
        return SessionMetadata(
            startedAt: summary.startedAt,
            sourceLang: "ja",
            targetLang: summary.targetLang,
            model: summary.model,
            chunkMS: summary.chunkMS ?? 160
        )
    }

    private func snapshotTranslationResults() -> [Int: SentenceTranslation] {
        var snapshot: [Int: SentenceTranslation] = [:]
        for entry in entries {
            if let translation = entry.translations.last {
                snapshot[entry.sentence.index] = translation
            }
        }
        return snapshot
    }
}

/// The capture-warning cards (`audio.none`, `capture.lost`) and the System
/// Settings deep link their fix actions open. The session wiring that posts
/// them lives in `AppModel.wireSessionController`.
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
    private static let audioPrivacySettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
    )!

    private func openAudioPrivacySettings() {
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
    private func postPersistentCard(key: String, title: String, body: String, action: ToastCenter.Action) {
        toasts.post(key: key, style: .redPersistent, title: title, body: body, action: action)
    }
}
