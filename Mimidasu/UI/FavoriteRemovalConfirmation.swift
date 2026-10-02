import SwiftUI

/// The un-star confirmation, attached once per window that can raise one — the
/// main window (whose single slot the dictionary popover and the sidebar card
/// share) and the Favorites window — so the wording and the buttons cannot
/// drift.
///
/// The question lives in the *window's* state, one slot, passed in as a
/// binding. The popover and the sidebar card are both mounted for the same
/// pinned lookup, which is why they share one slot rather than one each: a
/// slot per control is a slot that can raise two dialogs, and one window means
/// one alert by construction.
///
/// The main window is that window, and deliberately not the popover: a
/// `.popover` is a window of its own, so an alert inside it presents as a
/// sheet on the popover — and when the popover closes underneath it (the
/// selection is cleared, Escape, a retap, a session reset) that sheet's
/// dimming backdrop is orphaned over the window below. Presented by the window
/// that owns the popover, the question outlives the popover, which is what the
/// sidebar card's always did.
struct FavoriteRemovalConfirmation: ViewModifier {
    let model: AppModel
    /// The headword awaiting confirmation, or nil.
    @Binding var pendingRemoval: String?

    func body(content: Content) -> some View {
        content.alert(
            "Remove from favorites?",
            isPresented: isPresented,
            presenting: pendingRemoval
        ) { headword in
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
            Button("Remove", role: .destructive) {
                pendingRemoval = nil
                model.confirmFavoriteRemoval(headword: headword)
            }
        } message: { headword in
            Text("「\(headword)」 will no longer be highlighted in your transcript.")
        }
    }

    /// Dismissal — Escape, or the window going away — must clear the question
    /// too, or the next un-star would flash an already-populated alert.
    private var isPresented: Binding<Bool> {
        Binding(
            get: { pendingRemoval != nil },
            set: { isPresented in
                if !isPresented {
                    pendingRemoval = nil
                }
            }
        )
    }
}

extension View {
    func favoriteRemovalConfirmation(
        _ model: AppModel, pendingRemoval: Binding<String?>
    ) -> some View {
        modifier(FavoriteRemovalConfirmation(model: model, pendingRemoval: pendingRemoval))
    }
}
