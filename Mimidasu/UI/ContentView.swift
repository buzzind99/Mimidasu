import AppKit
import SwiftUI

/// Shared hover flag for the floating reference-window openers. Hover delivery
/// is not exclusive, so without this the word surfaces below the buttons
/// would light up while the cursor is on one. A reference, not a value: every
/// reader must see the same instance for the flag to work across the
/// transcript tree. The HUD and the reference window are separate windows and
/// read the nil default, so neither is affected. One flag for both openers
/// rather than one each: it answers "is a floating opener under the pointer",
/// and two flags would let the gap between the two buttons light the
/// transcript. Each opener's own ghosting is local to that button.
@Observable
@MainActor
final class ReferenceButtonHover {
    var isHovering = false
}

extension EnvironmentValues {
    @Entry var referenceButtonHover: ReferenceButtonHover?
}

/// Button style with zero pressed-state feedback: the label renders
/// identically idle, hovered, and pressed. The floating openers manage their
/// own ghost opacity, so `.plain`'s mouse-down dimming would fight it.
private struct StaticButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}

/// One floating opener for the shared reference window. The two modes are
/// separate buttons rather than one that toggles, because the point of each is
/// to land on a named place: the book opens Dictionary, the star opens
/// Favorites, whichever mode the window was left in.
///
/// Each is its own leaf so its hover read stays local: `ReferenceButtonHover`
/// is observed by the word surfaces' stand-down, and a hover transition should
/// re-evaluate this button — not `ContentView.body`, which would re-diff the
/// sidebar, the transcript, and the live strip twice per hover. Same 34pt
/// circle chrome as the transcript jump buttons; the hit area is deliberately
/// the full square, not the circle — corner hovers must not fall through to
/// the word surfaces below.
private struct ReferenceOpenerButton: View {
    let mode: ReferenceMode
    let hover: ReferenceButtonHover

    @Environment(\.openWindow) private var openWindow
    /// Ghosting is per-button, unlike the stand-down: brightening the pair
    /// together would make the pointer crossing the gap between them flicker.
    @State private var isHovering = false

    var body: some View {
        Button {
            ReferenceWindow.open(mode, with: openWindow)
        } label: {
            Image(systemName: mode.icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(mode.openerTint)
                .frame(width: 34, height: 34)
                .background(
                    Circle()
                        .fill(Theme.jumpButtonBackground)
                        .overlay(Circle().stroke(Theme.jumpButtonStroke))
                        .shadow(color: .black.opacity(0.4), radius: 10, y: 4)
                )
        }
        .buttonStyle(StaticButtonStyle())
        .opacity(isHovering ? 1 : 0.4)
        .pointerStyle(.link)
        .help(mode.openerHelp)
        .accessibilityLabel(mode.openerHelp)
        .onHover { hovering in
            isHovering = hovering
            hover.isHovering = hovering
        }
    }
}

/// Toast stack and the two openers, one top-trailing column: toasts push the
/// openers down by layout, and they glide back when they clear. Dictionary
/// sits above Favorites — the more general tool first, the user's saved list
/// under it. Its own leaf so the toast-array read the conditional mount
/// performs registers against this column alone — in `ContentView.body` it
/// would re-diff the sidebar, the transcript, and the live strip on every
/// post, dismissal, and expiry.
private struct TranscriptOverlayColumn: View {
    let toasts: ToastCenter
    let hover: ReferenceButtonHover

    var body: some View {
        VStack(alignment: .trailing, spacing: 12) {
            if !toasts.toasts.isEmpty {
                ToastStackView(center: toasts)
            }
            ReferenceOpenerButton(mode: .dictionary, hover: hover)
            ReferenceOpenerButton(mode: .favorites, hover: hover)
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
    /// Backing state for the floating reference openers (ghosted until
    /// hovered) and the word-hover stand-down flag the surfaces read.
    @State private var referenceButtonHover = ReferenceButtonHover()
    /// The un-star awaiting confirmation, in the main window — one slot for
    /// both dictionary hosts. They are mounted together for a pinned lookup, so
    /// a slot per control could raise two dialogs; a slot per *window* cannot.
    /// Attached to the window root rather than to either host for a second
    /// reason: the popover is a window of its own, and an alert presented there
    /// is orphaned — backdrop and all — the moment the popover closes.
    @State private var pendingFavoriteRemoval: String?
    /// The stop awaiting confirmation, and the close-the-archive-and-start
    /// question. Window-level slots (the sidebar capsule files the request,
    /// the window presents), one each per `FavoriteRemovalConfirmation`'s
    /// pattern.
    @State private var pendingStop = false
    @State private var pendingArchiveStart = false

    @Environment(\.openWindow) private var openWindow

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
        .stopConfirmation(model, isPresented: $pendingStop)
        .archiveStartConfirmation(model, isPresented: $pendingArchiveStart)
        // The bulk archive translation's cloud disclosure: the intent slot is
        // shared with the settings sheet, each window presenting only its own
        // intents (see `archiveDisclosure`).
        .sheet(item: archiveDisclosure) { disclosure in
            CloudDisclosureSheet(
                intent: disclosure,
                sentenceCount: disclosureSentenceCount(disclosure),
                onConfirm: { model.confirmCloudDisclosure(disclosure) },
                onDecline: { model.declineCloudDisclosure() }
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: .mimidasuOpenArchiveWindow)) { _ in
            openWindow(id: ArchiveWindow.sceneID)
        }
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

    /// The shared disclosure slot, filtered to the main window's archive
    /// bulk-run intent: the settings intents present in the Settings scene's
    /// own sheet and the archive window presents its own intents, so this
    /// one never sees them. Writing nil — the sheet's dismissal — declines
    /// the held slot; decline is idempotent, so a dismissal after an
    /// explicit Decline's clear changes nothing.
    private var archiveDisclosure: Binding<PendingCloudDisclosure?> {
        Binding(
            get: {
                guard let pending = model.providerAwaitingDisclosure,
                      case .archiveTranslation(_, _, _, .mainWindow) = pending
                else { return nil }
                return pending
            },
            set: { newValue in
                if newValue == nil {
                    model.declineCloudDisclosure()
                }
            }
        )
    }

    /// The sentences the intent's run would send — the disclosure body's
    /// count line. Nil for the settings intents and the archive window's
    /// intents (their copy carries none here).
    private func disclosureSentenceCount(_ disclosure: PendingCloudDisclosure) -> Int? {
        if case let .archiveTranslation(_, lang, _, .mainWindow) = disclosure {
            return model.archiveTranslationSendCount(lang: lang)
        }
        return nil
    }

    /// Files the un-star question the shared window-level alert presents. Both
    /// dictionary hosts get this one closure, so which control was pressed is
    /// the only thing either of them contributes.
    private func requestFavoriteRemoval(_ headword: String) {
        pendingFavoriteRemoval = headword
    }

    /// The capsule's Stop path: the policy decides whether the window asks
    /// first; quiet phases (empty transcript, cancel-during-start, unavailable
    /// store) stop directly.
    private func requestStop() {
        if model.shouldConfirmStop {
            pendingStop = true
        } else {
            model.stop()
        }
    }

    /// The capsule's Start path: an open archive or a running bulk
    /// translation never refuses outright — it asks first; otherwise start
    /// is direct.
    private func requestStart() {
        if model.openArchive != nil || model.archiveTranslationRunning {
            pendingArchiveStart = true
        } else {
            model.start()
        }
    }

    private var mainContent: some View {
        // Read in this body, not inside a nested closure: the matcher accessor
        // builds a closure and observes nothing. The read is discarded — the
        // strip's surfaces resolve membership and observe the store
        // themselves — but it keeps the dependence on favorite state visible
        // at the surface that hands the matcher down.
        _ = model.favorites.revision
        return HStack(spacing: 0) {
            SidebarView(
                model: model,
                onFavoriteRemovalRequest: requestFavoriteRemoval,
                onStopRequest: requestStop,
                onStartRequest: requestStart
            )
            Rectangle()
                .fill(Theme.divider)
                .frame(width: 1)
                .ignoresSafeArea()
            VStack(spacing: 0) {
                if model.openArchive != nil {
                    ArchiveBannerView(model: model)
                }
                transcriptArea
            }
        }
        .background(Theme.window)
        .environment(\.referenceButtonHover, referenceButtonHover)
    }

    /// The transcript column below the banner (the whole pane live): the
    /// transcript list, its live strip, and both top overlays. The overlays
    /// attach here rather than to the banner's column so neither the toast
    /// stack nor the notice pill covers the banner's trailing controls in
    /// archive mode.
    private var transcriptArea: some View {
        VStack(spacing: 0) {
            TranscriptView(
                model: model,
                onFavoriteRemovalRequest: requestFavoriteRemoval
            )
            // Archive mode: the live strip hides entirely (nothing is
            // live; the banner carries the archived stats) and its
            // strip-anchored popover has no anchor to mount on.
            if model.openArchive == nil {
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
        }
        // Toast stack and the reference openers share one top-trailing
        // column (see `TranscriptOverlayColumn`); it is a leaf so its
        // toast observation stays local.
        .overlay(alignment: .topTrailing) {
            TranscriptOverlayColumn(
                toasts: model.toasts,
                hover: referenceButtonHover
            )
        }
        .overlay(alignment: .top) {
            NoticePillView(center: model.notices)
        }
    }
}
