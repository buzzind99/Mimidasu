import SwiftUI

/// The rename question for a stored session, attached once per surface that
/// can raise one — the archive window (whose single slot the rows share) and
/// the opened archive's banner — so the wording, the buttons and the stored
/// value cannot drift.
///
/// The question's *state* is window-level in both surfaces: the pending
/// session, the draft and the value to store live in an
/// `ArchiveWindowState` (the archive window's own, and the banner's), so the
/// modifier takes the slot and the draft as bindings and the surface's name
/// rule as a closure — read when Save runs, never captured at build time, so
/// a keystroke that lands after the alert was built still counts.
struct ArchiveRenameConfirmation: ViewModifier {
    let model: AppModel
    /// The session awaiting the rename, or nil.
    @Binding var pendingRename: ArchivedSessionSummary?
    /// The in-field text.
    @Binding var draft: String
    /// The name to store: trimmed, nil when the draft is empty (which
    /// clears the name back to the auto-title).
    let renamedName: () -> String?

    func body(content: Content) -> some View {
        content.alert("Rename session", isPresented: isPresented) {
            TextField("Name", text: $draft)
            Button("Cancel", role: .cancel) { pendingRename = nil }
            Button("Save") {
                if let summary = pendingRename {
                    model.renameArchive(id: summary.id, name: renamedName())
                }
                pendingRename = nil
            }
        }
    }

    /// Dismissal — Escape, or the window going away — must clear the slot
    /// too, or the next rename would flash an already-populated alert.
    private var isPresented: Binding<Bool> {
        Binding(
            get: { pendingRename != nil },
            set: { isPresented in
                if !isPresented {
                    pendingRename = nil
                }
            }
        )
    }
}

extension View {
    /// Attaches the archive rename question to a surface that owns a rename
    /// slot (the archive window's rows, the opened archive's banner).
    func archiveRenameConfirmation(
        _ model: AppModel,
        pendingRename: Binding<ArchivedSessionSummary?>,
        draft: Binding<String>,
        renamedName: @escaping () -> String?
    ) -> some View {
        modifier(ArchiveRenameConfirmation(
            model: model,
            pendingRename: pendingRename,
            draft: draft,
            renamedName: renamedName
        ))
    }
}
