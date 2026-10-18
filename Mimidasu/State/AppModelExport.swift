import AppKit
import Foundation

/// Export surface of `AppModel` (plain-text copy + the four file formats
/// behind the export menu), split out to keep the main file focused on
/// session lifecycle.
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
