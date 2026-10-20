import SwiftUI

/// Window-local state for the archive window: the summary awaiting delete or
/// rename confirmation, the rename draft, the row whose add-language chooser
/// popover is open, and the row language whose translation picker is open.
/// One slot each, mirroring the `FavoriteRemovalConfirmation` pattern — the
/// presentation state lives window-level, so rows only attach the controls.
@Observable
@MainActor
final class ArchiveWindowState {
    /// The session and language whose row chip has its translation picker
    /// open, or nil. One slot for the window, like the chooser: two rows
    /// can't hold a picker at once.
    struct TranslationPickerTarget: Equatable {
        let sessionID: Int64
        let lang: String
    }

    /// The session awaiting the delete confirmation, or nil.
    var pendingDelete: ArchivedSessionSummary?
    /// The session awaiting rename, or nil; `renameDraft` is its in-field text.
    var pendingRename: ArchivedSessionSummary?
    var renameDraft = ""
    /// The session whose row `+` pill has its add-language chooser open, or
    /// nil. One slot for the window, like the confirmations: two rows can't
    /// hold a chooser at once.
    var chooserPopoverSession: Int64?
    /// The row language whose translate picker is open, or nil.
    var translationPicker: TranslationPickerTarget?

    func requestDelete(_ summary: ArchivedSessionSummary) {
        pendingDelete = summary
    }

    func requestChooser(_ summary: ArchivedSessionSummary) {
        chooserPopoverSession = summary.id
    }

    /// Clears the chooser slot only while this row still owns it.
    func clearChooser(_ summary: ArchivedSessionSummary) {
        if chooserPopoverSession == summary.id {
            chooserPopoverSession = nil
        }
    }

    func requestTranslationPicker(_ summary: ArchivedSessionSummary, lang: String) {
        translationPicker = TranslationPickerTarget(sessionID: summary.id, lang: lang)
    }

    /// Clears the translation-picker slot only while this (session, language)
    /// still owns it.
    func clearTranslationPicker(sessionID: Int64, lang: String) {
        if translationPicker == TranslationPickerTarget(sessionID: sessionID, lang: lang) {
            translationPicker = nil
        }
    }

    /// Opens the rename alert prefilled with the current name (empty for an
    /// auto-titled session).
    func requestRename(_ summary: ArchivedSessionSummary) {
        pendingRename = summary
        renameDraft = summary.name ?? ""
    }

    /// The draft as a store value: trimmed, nil when empty (clears back to
    /// the auto-title).
    var renameValue: String? {
        let trimmed = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
