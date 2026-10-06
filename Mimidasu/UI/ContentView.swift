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

/// Button style with zero pressed-state feedback: the label renders
/// identically idle, hovered, and pressed. The floating star manages its own
/// ghost opacity, so `.plain`'s mouse-down dimming would fight it.
private struct StaticButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}

/// The floating favorite-list opener, as its own leaf so its hover read stays
/// local: `FavoritesButtonHover` is observed by the glyph's opacity and by the
/// stand-down the word surfaces perform, and a hover transition should
/// re-evaluate this button — not `ContentView.body`, which would re-diff the
/// sidebar, the transcript, and the live strip twice per hover. The hover
/// reference is shared by design (every reader must see the same instance);
/// `closedAt` is the close stamp the reopen debounce reads. Same 34pt circle
/// chrome as the transcript jump buttons; the hit area is deliberately the
/// full square, not the circle — corner hovers must not fall through to the
/// word surfaces below.
private struct FavoritesOpenerButton: View {
    let hover: FavoritesButtonHover
    let closedAt: ContinuousClock.Instant?

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button {
            if let closedAt,
               closedAt.duration(to: .now) < .milliseconds(500)
            {
                return
            }
            openWindow(id: "favorites")
        } label: {
            Image(systemName: "star.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.favoriteStarYellow)
                .frame(width: 34, height: 34)
                .background(
                    Circle()
                        .fill(Theme.jumpButtonBackground)
                        .overlay(Circle().stroke(Theme.jumpButtonStroke))
                        .shadow(color: .black.opacity(0.4), radius: 10, y: 4)
                )
        }
        .buttonStyle(StaticButtonStyle())
        .opacity(hover.isHovering ? 1 : 0.4)
        .pointerStyle(.link)
        .help("Favorite list")
        .accessibilityLabel("Favorite list")
        .onHover { hovering in hover.isHovering = hovering }
    }
}

/// Toast stack and the favorites opener, one top-trailing column: toasts push
/// the star down by layout, and it glides back when they clear. Its own leaf
/// so the toast-array read the conditional mount performs registers against
/// this column alone — in `ContentView.body` it would re-diff the sidebar,
/// the transcript, and the live strip on every post, dismissal, and expiry.
private struct TranscriptOverlayColumn: View {
    let toasts: ToastCenter
    let hover: FavoritesButtonHover
    let closedAt: ContinuousClock.Instant?

    var body: some View {
        VStack(alignment: .trailing, spacing: 12) {
            if !toasts.toasts.isEmpty {
                ToastStackView(center: toasts)
            }
            FavoritesOpenerButton(hover: hover, closedAt: closedAt)
        }
        .padding(.trailing, 20)
        .padding(.top, 16)
    }
}

/// Root view: onboarding until the model resolves, then the main shell —
/// sidebar | 1pt divider | transcript pane with the live strip, the toast
/// stack overlaid top-trailing, and the notice pill overlaid top.
struct ContentView: View {
    var model: AppModel
    var live: LivePartialState
    var latency: LatencyState

    @AppearanceSetting private var appearance
    /// Backing state for the floating favorite-list button (ghosted until
    /// hovered) and the word-hover stand-down flag the surfaces read.
    @State private var favoritesButtonHover = FavoritesButtonHover()
    /// When the favorites window last closed — same shape as the Settings
    /// gear (`SidebarView.settingsClosedAt`): a star click is itself a click
    /// outside the window, so resign-key closes it before this button's
    /// mouse-up action runs, and a fresh close means the click already did
    /// the toggle-off and must not re-open. Continuous clock: monotonic, so
    /// a system-time step can't stretch or skip the guard.
    @State private var favoritesClosedAt: ContinuousClock.Instant?
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
        // the colors it painted before the last star press. Nothing consumes
        // the number — the strip's surfaces resolve membership through the
        // matcher — so the read is deliberately discarded.
        _ = model.favorites.revision
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
                    isFavorite: model.favoriteSegmentMatcher
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
            // Toast stack and favorites opener share one top-trailing
            // column (see `TranscriptOverlayColumn`); it is a leaf so its
            // toast observation stays local.
            .overlay(alignment: .topTrailing) {
                TranscriptOverlayColumn(
                    toasts: model.toasts,
                    hover: favoritesButtonHover,
                    closedAt: favoritesClosedAt
                )
            }
            .overlay(alignment: .top) {
                NoticePillView(center: model.notices)
            }
        }
        .background(Theme.window)
        .environment(\.favoritesButtonHover, favoritesButtonHover)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { note in
            guard (note.object as? NSWindow)?.title == "Favorites" else { return }
            favoritesClosedAt = .now
        }
    }
}
