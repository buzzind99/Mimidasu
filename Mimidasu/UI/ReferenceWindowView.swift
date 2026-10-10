import AppKit
import SwiftUI

/// The reference window's identity: the scene's title, its scene id, its fixed
/// size, and the one constant every AppKit title-match site compares against.
///
/// The window started life as the Favorites list, and two observers in two
/// files recognize it by `window.title`. Renaming the scene without routing
/// them through a constant is how one of them silently stops firing, with no
/// error anywhere.
enum ReferenceWindow {
    static let title = "Dictionary"
    static let sceneID = "dictionary"
    /// The fixed content size. Width is dictated by the row content; height is
    /// sized to six collapsed Favorites rows — a 73.6 pt row plus the 10 pt
    /// `LazyVStack` gap, in a slot that also holds the notice card, the search
    /// field, their gaps, and the content padding. Dictionary mode shares the
    /// frame deliberately: a mode switch must not resize the window under the
    /// pointer.
    static let width: CGFloat = 460
    static let height: CGFloat = 692
}

extension ReferenceWindow {
    /// Brings the window up showing `mode`. The mode is persisted
    /// (`ReferenceMode.storageKey`), so writing the key here retargets a window
    /// that is already open — `AppStorage` observes the defaults store — and
    /// seeds the default for one that is not. Skipping the write is how an
    /// opener lands on whichever mode the last visit left behind.
    @MainActor
    static func open(_ mode: ReferenceMode, with openWindow: OpenWindowAction) {
        UserDefaults.standard.set(mode.rawValue, forKey: ReferenceMode.storageKey)
        openWindow(id: sceneID)
    }
}

/// The two surfaces the reference window shows. One window rather than two
/// scenes (D1): they are two views of the same data — the dictionary everything
/// else looks words up in, and the words this user starred out of it — and a
/// second window would mean a second place to look for either.
enum ReferenceMode: String, CaseIterable, Identifiable {
    case dictionary
    case favorites

    static let storageKey = "ReferenceWindowMode"

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .dictionary: ReferenceWindow.title
        case .favorites: "Favorites"
        }
    }

    /// The brand mark's glyph and the switcher's selected button.
    var icon: String {
        switch self {
        case .dictionary: "book.fill"
        case .favorites: "star.fill"
        }
    }

    /// The floating opener's glyph tint. Keeps the two openers distinct at a
    /// glance by color as well as by shape, and reuses the tokens the mode's
    /// glyphs already wear elsewhere so neither icon reads as a new color.
    var openerTint: Color {
        switch self {
        case .dictionary: Theme.accentPink
        case .favorites: Theme.favoriteStarYellow
        }
    }

    /// What each floating opener promises. The title alone is ambiguous from a
    /// 34pt circle in the corner of the transcript pane, so each names the
    /// mode it opens and what that mode is for.
    var openerHelp: String {
        switch self {
        case .dictionary: "Open the dictionary"
        case .favorites: "Open favorites"
        }
    }
}

/// The reference window's content: the header band, the mode switcher, and
/// whichever mode is active.
///
/// The window owns the fixed frame (`ReferenceWindow.width` × `.height`) and
/// the surface color, so both modes size identically — a mode switch must not
/// resize the window under the pointer. The mode itself is persisted
/// (`@AppStorage`), defaulting to Dictionary: it is the more general of the
/// two, and the window now opens on the tool rather than on one user's saved
/// list. `ReferenceWindow.open` is what an opener writes before presenting, so
/// a button can land on the mode it names.
struct ReferenceWindowView: View {
    var model: AppModel

    @AppearanceSetting private var appearance
    @AppStorage(ReferenceMode.storageKey) private var modeRaw = ReferenceMode.dictionary.rawValue
    /// The un-star awaiting confirmation, in this window. One slot for both
    /// modes, for the same reason the main window has one: the alert is a
    /// sheet here, and a sheet whose window closes takes its own question with
    /// it while the slot would not.
    @State private var pendingRemoval: String?
    /// Files the un-star question on this window's single slot. One closure for
    /// both modes so neither can pass a different handler and quietly grow a
    /// second slot.
    private var fileFavoriteRemoval: (String) -> Void {
        { headword in pendingRemoval = headword }
    }

    /// Each mode's state, created once and kept alive across switches (D11).
    @State private var favoritesState: FavoritesWindowState
    @State private var dictionaryState: DictionarySearchState

    init(model: AppModel) {
        self.model = model
        _favoritesState = State(initialValue: FavoritesWindowState(model: model))
        _dictionaryState = State(initialValue: DictionarySearchState(model: model))
    }

    /// An unrecognized persisted value (or none yet) falls back to Dictionary
    /// rather than to whichever mode happened to sort first.
    private var mode: ReferenceMode {
        ReferenceMode(rawValue: modeRaw) ?? .dictionary
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.divider).frame(height: 1)
            switch mode {
            case .dictionary:
                DictionarySearchView(
                    model: model,
                    state: dictionaryState,
                    onFavoriteRemoval: fileFavoriteRemoval
                )
            case .favorites:
                FavoritesView(
                    model: model,
                    state: favoritesState,
                    onFavoriteRemoval: fileFavoriteRemoval
                )
            }
        }
        // The whole window's size; `.top` keeps a short list and the empty
        // states pinned to the top instead of floating in the middle.
        .frame(width: ReferenceWindow.width, height: ReferenceWindow.height, alignment: .top)
        .background(Theme.window)
        .preferredColorScheme($appearance.resolvedColorScheme)
        .favoriteRemovalConfirmation(model, pendingRemoval: $pendingRemoval)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { note in
            guard (note.object as? NSWindow)?.title == ReferenceWindow.title else { return }
            resetForClose()
        }
    }

    // MARK: - Chrome

    /// Settings-style header band, following the favorites header: brand mark,
    /// title, and a trailing count. The switcher sits between the title and
    /// the count — close to the mark it describes, and far from the count the
    /// two modes fill very differently.
    private var header: some View {
        HStack(spacing: 9) {
            ZStack {
                Circle().fill(Theme.Gradients.brand)
                Image(systemName: mode.icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 24, height: 24)
            Text(mode.title)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Theme.primaryText)
            modeSwitcher
            Spacer()
            countLabel
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
    }

    /// Two icon buttons rather than a segmented capsule: the modes are named by
    /// their glyph (a book, a star) and both icons already appear in the app's
    /// chrome, so the switcher needs no label to be legible. The selected one
    /// takes the accent fill; the other washes on hover, so the affordance is
    /// discoverable without a third state.
    private var modeSwitcher: some View {
        HStack(spacing: 2) {
            ForEach(ReferenceMode.allCases) { candidate in
                modeButton(candidate)
            }
        }
    }

    private func modeButton(_ candidate: ReferenceMode) -> some View {
        let selected = candidate == mode
        return Button {
            modeRaw = candidate.rawValue
        } label: {
            Image(systemName: candidate.icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(selected ? Color.white : Theme.secondaryText)
                .frame(width: 24, height: 24)
                .background {
                    if selected {
                        Circle().fill(Theme.accentPink)
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .hoverHighlight(Circle(), isEnabled: !selected)
        .help(candidate.title)
        .accessibilityLabel(candidate.title)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    /// The trailing count, following the active mode. Favorites keeps its
    /// capacity/filtered phrasing; Dictionary reads `displayed / matched`, the
    /// one number that says both "this is what you got" and "this is all there
    /// is" (D12). Its total carries a `+` when the search stopped short, so
    /// the two halves do not read as equal claims. Empty while the query is
    /// empty — `0 / 0` on an untouched field is noise.
    @ViewBuilder
    private var countLabel: some View {
        switch mode {
        case .favorites:
            countText(favoritesState.countText())
        case .dictionary:
            if !dictionaryState.debouncedQuery.isEmpty {
                countText(dictionaryState.countText)
            }
        }
    }

    private func countText(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(Theme.secondaryText)
            .monospacedDigit()
    }

    // MARK: - Close

    /// Routes the close to both modes. Each state object documents why the reset
    /// belongs here rather than on the next show; the host's only job is to not
    /// let one mode's rows survive into the next visit.
    private func resetForClose() {
        favoritesState.resetForClose()
        dictionaryState.resetForClose()
    }
}
