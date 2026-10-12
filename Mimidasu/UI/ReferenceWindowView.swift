import AppKit
import SwiftUI

/// The reference window's identity: the scene's title, its scene id, its fixed
/// size, and the one constant every AppKit title-match site compares against.
///
/// The window started life as the Favorites list, and three observers in two
/// files recognize it by `window.title`. Renaming the scene without routing
/// them through a constant is how one of them silently stops firing, with no
/// error anywhere.
enum ReferenceWindow {
    static let title = "Dictionary"
    static let sceneID = "dictionary"
    /// The fixed content size. Width is dictated by the row content; height is
    /// sized to seven collapsed Favorites rows — a 73.6 pt row plus the 10 pt
    /// `LazyVStack` gap, in a slot that also holds the notice card, the search
    /// field, their gaps, and the content padding. Dictionary mode shares the
    /// frame deliberately: a mode switch must not resize the window under the
    /// pointer.
    static let width: CGFloat = 460
    static let height: CGFloat = 775.6
    /// The cadence both modes' search fields debounce at. It lives here, on the
    /// window that owns both modes, rather than on either mode's state type: one
    /// window has one feel, and a constant one mode defines for the other is a
    /// coupling that reads as an accident.
    static let searchDebounce = Duration.milliseconds(150)
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
enum ReferenceMode: String {
    case dictionary
    case favorites

    static let storageKey = "ReferenceWindowMode"

    var title: String {
        switch self {
        case .dictionary: ReferenceWindow.title
        case .favorites: "Favorites"
        }
    }

    /// The mode a header flip lands on.
    var other: ReferenceMode {
        switch self {
        case .dictionary: .favorites
        case .favorites: .dictionary
        }
    }

    /// The brand mark's glyph and the floating openers' glyph.
    var icon: String {
        switch self {
        case .dictionary: "book.fill"
        case .favorites: "star.fill"
        }
    }

    /// The floating opener's glyph tint. Keeps the two openers distinct at a
    /// glance by color as well as by shape. Favorites reuses the token its
    /// star already wears elsewhere; the dictionary gets its own because its
    /// dark appearance matches the sidebar card's kicker instead.
    var openerTint: Color {
        switch self {
        case .dictionary: Theme.dictionaryOpenerGlyph
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
///
/// The host also owns the search field's focus: it claims the caret for the
/// active mode on open and on every mode switch, so arriving at the window — or
/// switching between its two surfaces — starts from the field the user is
/// about to type into rather than from nothing.
struct ReferenceWindowView: View {
    var model: AppModel

    @AppearanceSetting private var appearance
    @AppStorage(ReferenceMode.storageKey) private var modeRaw = ReferenceMode.dictionary.rawValue
    /// The un-star awaiting confirmation, in this window. One slot for both
    /// modes, for the same reason the main window has one: the alert is a
    /// sheet here, and a sheet whose window closes takes its own question with
    /// it while the slot would not.
    @State private var pendingRemoval: String?
    /// Which of the two mutually-exclusive search fields holds the caret. Held
    /// here rather than by each mode's view so a switch has somewhere to hand
    /// the caret *to* — a field that owns its own focus would leave the window
    /// with none when its view is torn down. Two values rather than one keyed
    /// by `ReferenceMode`: `@FocusState` ships initializers for `Bool` and for
    /// an `Optional<Hashable>` only — no `init(wrappedValue:)` — so a mode-keyed
    /// property is unspellable and every `.focused(_:equals:)` call would have
    /// to carry `.some(...)`. Splitting the pair also makes the hand-off
    /// explicit instead of depending on the outgoing field writing `false` back
    /// as it is torn down.
    @FocusState private var dictionarySearchFocused: Bool
    @FocusState private var favoritesSearchFocused: Bool
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

    /// The active mode's surface. Its own view so the notice pill can overlay
    /// it directly — attaching the overlay to the whole window would put it
    /// over the header instead of over the list the press came from.
    @ViewBuilder
    private var modeContent: some View {
        switch mode {
        case .dictionary:
            DictionarySearchView(
                model: model,
                state: dictionaryState,
                onFavoriteRemoval: fileFavoriteRemoval,
                searchFocus: $dictionarySearchFocused
            )
        case .favorites:
            FavoritesView(
                model: model,
                state: favoritesState,
                onFavoriteRemoval: fileFavoriteRemoval,
                searchFocus: $favoritesSearchFocused
            )
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.divider).frame(height: 1)
            modeContent
                // Below the header, not over it: the pill would otherwise cover
                // the title and the mode flip for the two seconds it lives.
                .overlay(alignment: .top) {
                    NoticePillView(center: model.notices)
                }
        }
        // The whole window's size; `.top` keeps a short list and the empty
        // states pinned to the top instead of floating in the middle.
        .frame(width: ReferenceWindow.width, height: ReferenceWindow.height, alignment: .top)
        .background(Theme.window)
        .preferredColorScheme($appearance.resolvedColorScheme)
        .favoriteRemovalConfirmation(model, pendingRemoval: $pendingRemoval)
        .onChange(of: mode) { _, _ in
            focusActiveSearch()
        }
        // Focus is set from `didBecomeKey` rather than `onAppear`: a focus
        // request only lands once the window has a first responder to hand it
        // to, and this scene caches its window, so `onAppear` is not a
        // reliable stand-in for "on screen and taking input". It also fires on
        // every reopen, which is exactly the set of moments to claim focus.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            guard (note.object as? NSWindow)?.title == ReferenceWindow.title else { return }
            focusActiveSearch()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { note in
            guard (note.object as? NSWindow)?.title == ReferenceWindow.title else { return }
            resetForClose()
        }
    }

    // MARK: - Chrome

    /// Settings-style header band, following the favorites header: brand mark,
    /// title, and a trailing count. The flip sits between the title and the
    /// count — close to the mark it retargets, and far from the count the two
    /// modes fill very differently.
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
            modeFlipButton
            Spacer()
            countLabel
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
    }

    /// One flip button rather than a two-button switcher: the mark and the
    /// title already name the active mode, so a selected switcher glyph
    /// repeated it — two identical pink circles on either side of the title.
    /// The double arrow reads as "swap", wears the same 24pt tile-filled
    /// circle as the entry pager's buttons, and the help text names where a
    /// press lands.
    private var modeFlipButton: some View {
        Button {
            modeRaw = mode.other.rawValue
        } label: {
            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 24, height: 24)
                .background(Theme.tileFill.clipShape(Circle()))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .hoverHighlight(Circle())
        .help("Switch to \(mode.other.title)")
        .accessibilityLabel("Switch to \(mode.other.title)")
    }

    /// The trailing count, following the active mode. Favorites keeps its
    /// capacity/filtered phrasing; Dictionary reads `displayed / matched`, the
    /// one number that says both "this is what you got" and "this is all there
    /// is" (D12). Its total carries a `+` when the search stopped short, so
    /// the two halves do not read as equal claims. Empty while the query is
    /// empty — `0 / 0` on an untouched field is noise — while a search is in
    /// flight, when the outcome still belongs to the previous query, and
    /// whenever the card beside it says the dictionary was never consulted
    /// (a missing database or a fault), where `0 / 0` would be that same
    /// denial in numbers.
    @ViewBuilder
    private var countLabel: some View {
        switch mode {
        case .favorites:
            countText(favoritesState.countText())
        case .dictionary:
            if !dictionaryState.debouncedQuery.isEmpty,
               !dictionaryState.isSearching,
               !dictionaryState.unavailable,
               dictionaryState.fault == nil
            {
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
    /// let one mode's rows survive into the next visit. The un-star slot dies
    /// with the window too: the alert is a sheet on this window, so a close
    /// with the sheet up would otherwise reopen onto a stale question.
    private func resetForClose() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            pendingRemoval = nil
        }
        favoritesState.resetForClose()
        dictionaryState.resetForClose()
    }

    // MARK: - Focus

    /// Puts the caret in the active mode's search field and takes it from the
    /// other. Both triggers route through here so a switch and a reopen cannot
    /// drift apart, and the incoming field is claimed only after the outgoing
    /// one is released — the order a hand-off needs, since a torn-down view
    /// cannot hold focus.
    private func focusActiveSearch() {
        switch mode {
        case .dictionary:
            favoritesSearchFocused = false
            dictionarySearchFocused = true
        case .favorites:
            dictionarySearchFocused = false
            favoritesSearchFocused = true
        }
    }
}
