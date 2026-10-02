import AppKit
import SwiftUI

/// Shared hover flag for the floating favorite-list button. Hover delivery
/// is not exclusive, so without this the word surfaces below the button
/// would light up while the cursor is on it. A reference, not a value: every
/// reader must see the same instance for the flag to work across the
/// transcript tree. The HUD and the Favorites window are separate windows and
/// read the nil default, so neither is affected.
@Observable
@MainActor
final class FavoritesButtonHover {
    var isHovering = false
}

extension EnvironmentValues {
    @Entry var favoritesButtonHover: FavoritesButtonHover?
}

/// Root view: onboarding until the model resolves, then the main shell —
/// sidebar | 1pt divider | transcript pane with the live strip, the toast
/// stack overlaid top-trailing, and the notice pill overlaid top.
struct ContentView: View {
    var model: AppModel
    var live: LivePartialState
    var latency: LatencyState

    @AppearanceSetting private var appearance
    /// The un-star awaiting confirmation, in the main window — one slot for
    /// both dictionary hosts. They are mounted together for a pinned lookup, so
    /// a slot per control could raise two dialogs; a slot per *window* cannot.
    /// Attached to the window root rather than to either host for a second
    /// reason: the popover is a window of its own, and an alert presented there
    /// is orphaned — backdrop and all — the moment the popover closes.
    @State private var pendingFavoriteRemoval: String?

    var body: some View {
        Group {
            if model.phase == .needsModel {
                OnboardingView(model: model)
            } else {
                mainContent
            }
        }
        .preferredColorScheme($appearance.resolvedColorScheme)
        .frame(minWidth: isOnboarding ? 800 : 1080, minHeight: isOnboarding ? 720 : 800)
        .onboardingWindowFootprint(isOnboarding)
        .favoriteRemovalConfirmation(model, pendingRemoval: $pendingFavoriteRemoval)
        .onAppear {
            Task { await model.refreshModelAvailability() }
        }
    }

    /// Onboarding owns the window until a model resolves; the conditional
    /// min size and the footprint modifier above give that span a compact
    /// welcome window instead of the main shell's footprint.
    private var isOnboarding: Bool {
        model.phase == .needsModel
    }

    /// Whether the live strip owns the app's single dictionary
    /// popover: true only while the selection is anchored to the strip.
    /// Dismissal clears the selection only when the strip still owns it.
    /// (Binding shape shared via `AppModel.lookupPopoverBinding`.)
    private var liveStripLookupPresented: Binding<Bool> {
        model.lookupPopoverBinding(for: .liveStrip)
    }

    /// Files the un-star question the shared window-level alert presents. Both
    /// dictionary hosts get this one closure, so which control was pressed is
    /// the only thing either of them contributes.
    private func requestFavoriteRemoval(_ headword: String) {
        pendingFavoriteRemoval = headword
    }

    private var mainContent: some View {
        // Read in this body, not inside a nested closure: the matcher accessor
        // builds a closure and observes nothing, so the live strip would keep
        // the colors it painted before the last star press.
        let favoriteRevision = model.favorites.revision
        return HStack(spacing: 0) {
            SidebarView(
                model: model,
                onFavoriteRemovalRequest: requestFavoriteRemoval
            )
            Rectangle()
                .fill(Theme.divider)
                .frame(width: 1)
                .ignoresSafeArea()
            VStack(spacing: 0) {
                TranscriptView(
                    model: model,
                    onFavoriteRemovalRequest: requestFavoriteRemoval
                )
                LiveStripView(
                    live: live,
                    onCopy: { text in model.copySnippet(text) },
                    onLookup: { token in model.handleLookupTap(token, source: .liveStrip) },
                    isFavorite: model.favoriteSegmentMatcher,
                    favoritesRevision: favoriteRevision
                )
                // Strip-anchored popover: single non-virtualized view, so
                // the strip owns it while the selection's anchor is the
                // live strip. Source-keyed so a strip retap swaps content
                // in place instead of a dismiss+replace.
                .popover(isPresented: liveStripLookupPresented) {
                    if let selected = model.selectedLookup?.popoverItem(for: .liveStrip) {
                        DictionaryPopoverView(
                            model: model,
                            selected: selected,
                            onFavoriteRemovalRequest: requestFavoriteRemoval
                        )
                    }
                }
            }
            .overlay(alignment: .topTrailing) {
                ToastStackView(center: model.toasts)
            }
            .overlay(alignment: .top) {
                NoticePillView(center: model.notices)
            }
        }
        .background(Theme.window)
    }
}
