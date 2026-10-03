import AppKit
import SwiftUI

/// Favorites window content: the user's starred words, searchable, each row
/// expanding into the same live JMDict entry view the popover renders.
///
/// Rows borrow the sidebar dictionary card's visual language (headword +
/// inline kana, mono romaji, trailing controls) — `DictionaryCardView`
/// already owns "a Japanese word, rendered" — so amber means exactly one
/// thing in this app: *this word is recolored in your transcript*. The
/// notice card is where that story is told.
///
/// Fixed 460 × 608 with a `ScrollView` rather than a `List`: a fixed panel
/// plus a scrolling list means expanding a card *scrolls* instead of growing
/// the window, which a `List` cannot do without swallowing the expansion.
struct FavoritesView: View {
    var model: AppModel

    @AppearanceSetting private var appearance
    @State private var query = ""
    /// The query the rows were built from; trails `query` by the debounce so
    /// a fast typist runs one query instead of one per keystroke.
    @State private var debouncedQuery = ""
    @State private var searchTask: Task<Void, Never>?
    /// The rows on screen — the whole list with no query, the SQLite matches
    /// with one. Held rather than computed so the query runs when its inputs
    /// change (the debounce landing, a favorites mutation, a close) and not on
    /// every body evaluation: a search active, each row expansion and each
    /// star pressed in a dictionary host re-runs `body`, and none of those
    /// needs to re-query the file.
    @State private var searchResults: [FavoriteWord]
    /// One instance for the whole window, so several rows can be expanded at
    /// once and each keeps its own in-flight lookup (§ `FavoritesLookupState`).
    @State private var lookupState: FavoritesLookupState
    /// The un-star awaiting confirmation. One slot for the whole window is
    /// enough — and sufficient: only the pressed control ever fills it, so a
    /// single alert is on screen no matter how many rows render a star.
    @State private var pendingRemoval: String?

    static let searchDebounce = Duration.milliseconds(150)
    /// How far a row's trailing controls drop onto the headword's line: they
    /// are top-aligned to the row, and the 26pt headword is what sets the
    /// first line, so their 22pt boxes need half the difference. The row's
    /// type is fixed, so this does not drift with the UI scale.
    private static let trailingLineDrop: CGFloat = 4

    init(model: AppModel) {
        self.model = model
        _lookupState = State(initialValue: FavoritesLookupState(lookup: model.jmDictLookup))
        _searchResults = State(initialValue: model.favorites.words)
    }

    var body: some View {
        windowContent(searchResults)
            // The whole window's size; `.top` keeps the empty state and a short
            // list pinned to the top instead of floating in the middle.
            .frame(width: 460, height: 608, alignment: .top)
            .background(Theme.window)
            .preferredColorScheme($appearance.resolvedColorScheme)
            .favoriteRemovalConfirmation(model, pendingRemoval: $pendingRemoval)
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { note in
                guard (note.object as? NSWindow)?.title == "Favorites" else { return }
                resetForClose()
            }
            .onChange(of: query) { _, newValue in
                searchTask?.cancel()
                // Nothing to debounce when the field already matches the query
                // the rows were built from. The close-time reset lands here —
                // its own `query = ""` write re-enters this handler — and must
                // not respawn the task it just cancelled.
                guard newValue != debouncedQuery else { return }
                searchTask = Task { @MainActor in
                    try? await Task.sleep(for: Self.searchDebounce)
                    guard !Task.isCancelled else { return }
                    debouncedQuery = newValue
                    searchResults = rows(for: newValue)
                }
            }
            // Removal is confirmed and then committed by the shared alert, so this
            // view no longer knows *which* control removed the word — the popover
            // and the card can remove one too. Pruning here covers all three, and
            // the rows follow: a search stays live over the surviving words, and
            // an unfiltered list picks up the store's new ordering.
            .onChange(of: model.favorites.words) { _, words in
                pruneLookupState(favorites: Set(words.map(\.headword)))
                searchResults = rows(for: debouncedQuery)
            }
    }

    /// The window's whole content, in its own builder: `body` is this tree
    /// plus seven modifiers, and the two together overrun the type-checker's
    /// budget for one expression.
    private func windowContent(_ rows: [FavoriteWord]) -> some View {
        VStack(spacing: 0) {
            header(rows.count)
            Rectangle().fill(Theme.divider).frame(height: 1)
            VStack(alignment: .leading, spacing: 10) {
                noticeCard
                searchField
                if rows.isEmpty {
                    emptyState
                } else {
                    rowList(rows)
                }
            }
            .padding(14)
        }
    }

    /// Wipes everything this window remembers between visits, at the moment it
    /// closes. The scene caches this view, so without this the search query and
    /// every expanded row would still be there on the next open — and a reset
    /// on the next *show* instead is what the user saw: `didBecomeKey` fires
    /// with the window already on screen, so the row animation replayed the
    /// whole list's collapse in front of them on every open.
    ///
    /// Animations are off for the reset itself. `willClose` is the only close
    /// notification AppKit posts (there is no `didClose`), and it arrives while
    /// the window is still on screen — mid close-animation — so an animated
    /// reset would just relocate the flash from opening to closing. Snapping
    /// instead puts it behind the closing window where it cannot be read.
    private func resetForClose() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            query = ""
            debouncedQuery = ""
            // The two writes above re-enter the query handler; its equality
            // guard turns both into early returns, so no debounce task can
            // land its captured query after this reset and filter a list the
            // field no longer shows a term for.
            searchTask?.cancel()
            searchTask = nil
            searchResults = model.favorites.words
            // The alert is a sheet on this window, so it dies with the window
            // while the slot would not: the next un-star would flash a question
            // the user already answered or dismissed.
            pendingRemoval = nil
            lookupState.reset()
        }
    }

    /// The scrolling list. The animation is keyed on the open-row list, so a
    /// toggle animates the row it belongs to; it is not what makes a reopen
    /// clean — `resetForClose()` runs at close, and explicitly un-animated.
    private func rowList(_ rows: [FavoriteWord]) -> some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(rows) { word in
                    favoriteCard(word)
                }
            }
            .animation(.easeOut(duration: 0.18), value: lookupState.expanded)
        }
    }

    /// Drops lookup state for rows that are no longer favorites, so an
    /// in-flight query can never land on a row that has been deleted here or
    /// unstarred from a dictionary host.
    private func pruneLookupState(favorites: Set<String>) {
        for headword in lookupState.expanded where !favorites.contains(headword) {
            lookupState.remove(headword: headword)
        }
    }

    // MARK: - Chrome

    /// Settings-style header band: brand-mark star, title, trailing count.
    ///
    /// The leading inset matches the content below rather than clearing the
    /// traffic lights. A hidden title bar still reserves its strip, which
    /// puts this band roughly 47pt below the window's top edge — the lights
    /// end around 20pt — so clearance padding bought nothing and only
    /// pushed the title out of line with the notice card and search field.
    private func header(_ rowCount: Int) -> some View {
        HStack(spacing: 9) {
            ZStack {
                Circle().fill(Theme.Gradients.brand)
                Image(systemName: "star.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 24, height: 24)
            Text("Favorites")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Theme.primaryText)
            Spacer()
            Text(countText(rowCount))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.secondaryText)
                .monospacedDigit()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
    }

    /// Explainer pinned above the list: starred words render amber in the
    /// transcription text, inflected forms included. Chrome, not a row — it
    /// never expands and is never filtered.
    private var noticeCard: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "star.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.favoriteStarYellow)
                .padding(.top, 1)
            Text("Favorite words appear amber-colored in the transcript — including "
                + "their inflected forms, so 見る includes 見た and 見ます. Keep an eye "
                + "out for your favorite words in the transcript!")
                .font(.system(size: 12))
                .foregroundStyle(Theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(
            radius: 12,
            fill: Theme.favoriteAccent.opacity(0.14),
            stroke: Theme.favoriteAccent.opacity(0.55)
        )
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondaryText)
            TextField("Search favorites", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
        }
        .padding(9)
        .cardSurface(radius: 9)
    }

    /// The list is empty for two different reasons, and naming the search for a
    /// window nobody searched in reads as a bug: an empty field with nothing
    /// under it needs to say so. The text follows the query the rows were built
    /// from, so it never names a term the list has not applied yet.
    private var emptyState: some View {
        let trimmed = debouncedQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = trimmed.isEmpty
            ? "No favorites yet. Star a word from the dictionary popover."
            : "No favorites match “\(trimmed)”."
        return Text(message)
            .font(.system(size: 13))
            .foregroundStyle(Theme.secondaryText)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 24)
    }

    // MARK: - Rows

    private func favoriteCard(_ word: FavoriteWord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            favoriteHeader(word)
            if lookupState.isExpanded(word) {
                favoriteDefinition(word)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    /// Card header block: headword + inline kana with the romaji below — one
    /// button down to the divider, so the whole block toggles. The label is
    /// greedy (`maxWidth: .infinity`) so that button claims every pixel the
    /// three trailing controls do not, which is both what keeps the controls
    /// trailing and what makes the full header width tappable. The controls
    /// are siblings rather than part of that button, so the chevron can read
    /// last.
    private func favoriteHeader(_ word: FavoriteWord) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Button {
                lookupState.toggle(word)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    headwordBlock(word)
                    if let romaji = word.romaji {
                        Text(verbatim: romaji)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Theme.secondaryText)
                            .lineLimit(1)
                            .textSelection(.disabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            .help(lookupState.isExpanded(word) ? "Hide definition" : "Show definition")
            trailingControls(word)
        }
    }

    /// The headword and its kana: inline while the pair fits the row, stacked
    /// with the kana above the word when it does not. Both texts are
    /// `fixedSize` inline, so a long entry would otherwise draw past the card's
    /// stroke and push the trailing controls off a window that cannot resize —
    /// the same reason the shared dictionary header carries this fallback.
    /// The stacked form drops `fixedSize` from the headword, so it truncates on
    /// its own line rather than competing with the kana.
    private func headwordBlock(_ word: FavoriteWord) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                headwordText(word.headword)
                    .fixedSize(horizontal: true, vertical: false)
                if let reading = word.reading {
                    readingText(reading, size: 14)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                if let reading = word.reading {
                    readingText(reading, size: 12)
                }
                headwordText(word.headword)
            }
        }
    }

    private func headwordText(_ headword: String) -> some View {
        Text(verbatim: headword)
            .font(.system(size: 26))
            .foregroundStyle(Theme.primaryText)
            .lineLimit(1)
            .textSelection(.disabled)
    }

    private func readingText(_ reading: String, size: CGFloat) -> some View {
        Text(verbatim: reading)
            .font(.system(size: size, weight: .medium))
            .foregroundStyle(Theme.annotationPink)
            .lineLimit(1)
            .textSelection(.disabled)
    }

    /// Copy, unstar, and the disclosure chevron — the same order the shared
    /// dictionary header row leads with (copy, then the star), with the
    /// chevron last because it belongs to the row rather than to the word.
    ///
    /// One drop for the whole group, not per control: the boxes are all 22pt
    /// and centered on each other here, so a single offset puts all three on
    /// the headword's line. The row's type is fixed, so this cannot drift
    /// with the UI scale.
    private func trailingControls(_ word: FavoriteWord) -> some View {
        HStack(alignment: .center, spacing: 4) {
            DictionaryCopyButton(
                placement: .icon, help: "Copy the headword",
                action: { model.copySnippet(word.headword) }
            )
            unstarButton(word)
            chevronButton(word)
        }
        .padding(.top, Self.trailingLineDrop)
    }

    private func chevronButton(_ word: FavoriteWord) -> some View {
        let expanded = lookupState.isExpanded(word)
        return Button {
            lookupState.toggle(word)
        } label: {
            Image(systemName: expanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .help(expanded ? "Hide definition" : "Show definition")
        .accessibilityLabel(expanded ? "Hide definition" : "Show definition")
    }

    /// Expanded definition block: 1pt divider over the shared entry view, so
    /// a row's definition is pixel-identical to the popover's. The headword
    /// block is suppressed — this row already shows the word, its kana, and
    /// its romaji two lines above — leaving badges, pitch, and senses. No
    /// sense viewport (this is a scrolling column) and no pager: nothing
    /// pages a window row.
    private func favoriteDefinition(_ word: FavoriteWord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Rectangle().fill(Theme.divider).frame(height: 1)
            switch lookupState.phase(for: word) {
            case .idle, .loading:
                ProgressView()
                    .controlSize(.small)
            case let .resolved(result):
                if let entry = result.entries.first {
                    // No favorite or copy arguments: `showsHeadword: false`
                    // drops the header row, which is the only place either is
                    // rendered, so passing them would assert a control the
                    // expanded block cannot show. The row's own header above
                    // carries both. `also: []` is the same kind of empty: the
                    // pager and the "also:" pills both live in the header row,
                    // and nothing may promote a window row's lookup — threading
                    // real hits through would render pills whose taps do
                    // nothing.
                    DictionaryEntryContentView(
                        entry: entry,
                        entryCount: result.entries.count,
                        entryIndex: 0,
                        also: [],
                        senseLimit: nil,
                        glossLimit: nil,
                        showsEntryPager: false,
                        showsHeadword: false
                    )
                } else {
                    lookupUnavailable(word)
                }
            case .notFound:
                DictionaryNotFoundView(
                    surface: word.headword, related: [], copyPlacement: .icon,
                    onCopy: { model.copySnippet(word.headword) }
                )
            case let .failed(message):
                lookupUnavailable(word, message: message)
            }
        }
    }

    private func lookupUnavailable(_ word: FavoriteWord, message: String = "") -> some View {
        Text(message.isEmpty ? "No definition for “\(word.headword)”." : message)
            .font(.system(size: 12))
            .foregroundStyle(Theme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Unboxed star: 18pt glyph in a 22×22 frame, no tile. Asks first — the
    /// shared alert commits the removal. Same action string as the dictionary
    /// header's starred state, so the two never drift.
    private func unstarButton(_ word: FavoriteWord) -> some View {
        Button {
            askToRemove(word.headword)
        } label: {
            Image(systemName: "star.fill")
                .font(.system(size: 18))
                .foregroundStyle(Theme.favoriteStarYellow)
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .help("Remove “\(word.headword)” from favorites")
        .accessibilityLabel("Remove “\(word.headword)” from favorites")
    }

    /// Raises the question. Both star sites come through here so the slot is
    /// the only way in; nothing else needs an exemption, because the window
    /// resets on close and not on show — Cancel therefore leaves the query and
    /// every expanded row exactly as they were.
    private func askToRemove(_ headword: String) {
        pendingRemoval = headword
    }

    // MARK: - Data

    /// The rows a query means: everything with no query, the database's
    /// matches with one. Called only from the events that change its inputs —
    /// the debounce landing, a favorites mutation, a close — never per body
    /// evaluation; each call is a synchronous query.
    private func rows(for query: String) -> [FavoriteWord] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return model.favorites.words }
        return model.favorites.search(trimmed)
    }

    private func countText(_ rowCount: Int) -> String {
        let trimmed = debouncedQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "\(model.favorites.count) / \(FavoritesStore.limit)"
        }
        return rowCount == 1 ? "1 entry" : "\(rowCount) entries"
    }
}
