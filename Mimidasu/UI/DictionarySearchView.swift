import SwiftUI

/// Full-dictionary search: one field that accepts Japanese, romaji, or an
/// English meaning, and a collapsible filter panel narrowing words from names
/// and rare entries.
///
/// The rows are favorites rows on purpose. A search result and a starred word
/// are the same object to this app — the dictionary is where a word is defined,
/// the favorite list is where the user decided to keep it — so a row that
/// looked like a different kind of result would teach the wrong gesture. What
/// a search adds is the *why*: the match badge names how the row was found and
/// the accent highlight shows exactly what matched, so a hit the user did not
/// type never passes for one they did.
struct DictionarySearchView: View {
    var model: AppModel
    let state: DictionarySearchState
    var onFavoriteRemoval: (String) -> Void
    /// The host's focus, shared with the Favorites field so only one of the
    /// two can hold the caret — see `ReferenceWindowView`.
    let searchFocus: FocusState<Bool>.Binding

    /// The field card's measured height; the funnel circle frames to this.
    @State private var fieldHeight: CGFloat = 34

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            searchField
            if state.filtersExpanded {
                filterPanel
            }
            results
        }
        .padding(14)
    }

    // MARK: - Chrome

    private var searchField: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondaryText)
                TextField("Search the dictionary", text: query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused(searchFocus, equals: true)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    // Claims the remainder, so the spinner sibling keeps its own
                    // slot: the stack lays children out sequentially, and the
                    // 8pt spacing is a minimum gap the typed text cannot cross.
                    // Clipped so a long query scrolls inside its own box rather
                    // than drawing past it toward the spinner.
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .clipped()
                // A layout sibling rather than an overlay: its slot is real
                // layout, so the text and the spinner can never share pixels —
                // an overlay would need a separately-reserved inset that can
                // race the spinner's own appearance.
                //
                // In the field rather than over the list: the list is not blocked
                // (it keeps showing the previous results) and the window never
                // flashes a spinner-sized hole in the middle of itself.
                if state.isSearching {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                        .frame(width: 14, height: 14)
                }
            }
            .padding(9)
            .cardSurface(radius: 9)
            .onHeightChange { height in
                if fieldHeight != height {
                    fieldHeight = height
                }
            }
            filterButton
        }
    }

    /// The funnel beside the field: badge-styled while open or filtered, framed a touch smaller than the field card.
    private var filterButton: some View {
        let expanded = state.filtersExpanded
        let hasActiveFilters = state.filters != DictionarySearchFilters()
        let highlighted = expanded || hasActiveFilters
        let help = expanded ? "Hide filters" : hasActiveFilters ? "Show filters (filters active)" : "Show filters"
        return Button {
            state.filtersExpanded.toggle()
        } label: {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.system(size: 18))
                .foregroundStyle(highlighted ? Theme.accentPink : Theme.secondaryText)
                .frame(width: max(fieldHeight - 4, 28), height: max(fieldHeight - 4, 28))
                .contentShape(Circle())
                .background {
                    if highlighted {
                        Circle().fill(Theme.accentPink.opacity(0.14))
                            .overlay(Circle().stroke(Theme.accentPink.opacity(0.55)))
                    }
                }
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .help(help)
        .accessibilityLabel(help) // names the state; SwiftUI has no expanded trait
    }

    private var query: Binding<String> {
        Binding(
            get: { state.query },
            set: { newValue in state.query = newValue }
        )
    }

    /// The collapsible filters live in `DictionaryFilterPanel`, split out so
    /// both types stay inside the body budget.
    private var filterPanel: some View {
        DictionaryFilterPanel(state: state)
    }

    // MARK: - Results

    @ViewBuilder
    private var results: some View {
        if state.unavailable {
            unavailableCard
        } else if state.fault != nil {
            faultCard
        } else if state.debouncedQuery.isEmpty {
            hintCard
        } else if state.outcome.isEmpty {
            // Gated on `isSearching`: while a search is in flight the outcome
            // still belongs to the previous query, so an empty outcome reads
            // as a wait — never as a denial of the new query.
            messageCard(state.isSearching ? "Searching…" : "No matches for “\(state.debouncedQuery)”.")
        } else {
            rowList
        }
    }

    private var rowList: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(state.visibleHits) { hit in
                    hitCard(hit)
                }
                footer
            }
            .animation(.easeOut(duration: 0.18), value: state.lookupState.expanded)
        }
    }

    /// One page deeper while a page can still be had, and only then the plain
    /// statement that the list is the *top* of a larger answer — so the ceiling
    /// reads as a ranking decision rather than as the dictionary's size. The
    /// header count says the same thing numerically; the wording says it in
    /// words.
    @ViewBuilder
    private var footer: some View {
        if state.canLoadMore {
            loadMoreButton
        } else if state.isAtCeiling {
            truncationFooter
        }
    }

    /// Reveals another `pageSize` rows. The rows above it never move, so this
    /// is the same list growing rather than a second page the user has to go
    /// find. Dimmed while the page is loading rather than gone: the control
    /// keeps its place, the same beat the field's spinner carries.
    ///
    /// The label carries no count on purpose — the header's `displayed /
    /// matched` is the one place a number belongs, and two of them on the same
    /// control is a number nobody reads. The help and the accessibility label
    /// keep it, where the count is the answer to a question the user asked.
    private var loadMoreButton: some View {
        let loading = state.isSearching
        let helpText = "Load \(DictionarySearchEngine.pageSize) more results"
        return Button {
            state.loadMore()
        } label: {
            Text("Load more")
                .font(.system(size: 12))
                .foregroundStyle(Theme.accentPink)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .hoverHighlight(Capsule(), isEnabled: !loading)
        .disabled(loading)
        .opacity(loading ? 0.45 : 1)
        .help(helpText)
        .accessibilityLabel(helpText)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }

    private var truncationFooter: some View {
        // Keyed off what is on screen: a filter press at the ceiling can leave
        // fewer survivors than the constant, and the footer must name those.
        Text("Showing top \(state.visibleHits.count) — refine your search")
            .font(.system(size: 11))
            .foregroundStyle(Theme.secondaryText)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 6)
    }

    private var hintCard: some View {
        messageCard("Search the dictionary — try 負ける · makeru · lose · mak")
    }

    /// Infrastructure failure — never "no matches", which would claim the
    /// dictionary was consulted. The typed error stays in the state (tests
    /// read `fault`); the card itself stays generic, so no raw SQLite text
    /// reaches the HUD.
    private var faultCard: some View {
        messageCard("The dictionary couldn't be searched. Try again — relaunch if it persists.")
    }

    /// The dictionary has not finished building: a wait, with the store
    /// re-kicking the build behind it.
    private var unavailableCard: some View {
        messageCard("The dictionary isn't ready yet — it downloads on first launch. Results appear as soon as it does.")
    }

    private func messageCard(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(Theme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 24)
    }
}

/// The row half of the search list: the favorites-shaped card, its badge line, the
/// accent highlight, and the two actions a row carries. Split from the window
/// chrome above so both halves stay inside the type-body budget.
private extension DictionarySearchView {

    // MARK: - Rows

    /// The row: the shared list row, with this mode's values. Search differs
    /// from Favorites in four places — the label spacing, the reading gate,
    /// the highlight spans, and the extras (the badge row and the gloss
    /// preview) — and every one of them is an argument here rather than a
    /// second copy of the row.
    private func hitCard(_ hit: DictionarySearchHit) -> some View {
        searchWordRow(
            hit: hit,
            bindings: DictionaryWordRowBindings(
                isExpanded: isExpanded(hit),
                phase: state.lookupState.phase(forKey: DictionarySearchState.lookupKey(for: hit)),
                trailingHeadword: hit.headword,
                isFavorite: isFavorite(hit),
                onToggle: { toggle(hit) },
                onToggleFavorite: { toggleFavorite(hit) },
                onCopy: { headword in model.copySnippet(headword) }
            ),
            extras: {
                badgeRow(hit)
                glossPreview(hit)
            },
            resolvedContent: { result in
                entryBlock(hit, result: result)
            }
        )
    }

    /// The match badge first, then the entry's own metadata. The match badge
    /// leads because it is the part with no counterpart on a Favorites row: it
    /// is what tells the user whether this row answered what they typed —
    /// which is why it wears the magnifying glass that marks a chip as the
    /// row's reason for being here.
    private func badgeRow(_ hit: DictionarySearchHit) -> some View {
        DictionaryBadgeRow(
            badges: dictionaryBadges(
                leading: DictionaryBadge(
                    text: hit.matchKind.badgeLabel,
                    color: Theme.accentPink,
                    icon: "magnifyingglass"
                ),
                common: hit.common,
                jlpt: hit.jlpt,
                // The real type badges, not a generic NAME chip: this row's
                // header is the only place a name's types appear now that the
                // expanded block drops its badge row, and `JMDictNameEntries`
                // maps them exactly as the entry view does. A name whose
                // senses carry no tags adds nothing rather than a chip that
                // claims what it does not know.
                namePosTokens: hit.isName ? hit.namePosTokens : []
            )
        )
    }

    /// One or two lines of meaning, with the matched run lit up for a gloss
    /// hit. Rows that matched elsewhere get the same line unhighlighted, which
    /// keeps the card heights comparable while the eye is scanning the list.
    @ViewBuilder
    private func glossPreview(_ hit: DictionarySearchHit) -> some View {
        let glosses = hit.glossPreview
        if glosses.isEmpty {
            EmptyView()
        } else {
            glossText(hit, glosses)
                .font(.system(size: 12))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.disabled)
        }
    }

    private func glossText(_ hit: DictionarySearchHit, _ glosses: [String]) -> Text {
        guard hit.matchedField == .gloss, let first = glosses.first else {
            return Text(verbatim: glosses.joined(separator: "; "))
                .foregroundStyle(Theme.secondaryText)
        }
        let tail = glosses.count > 1 ? "; " + glosses.dropFirst().joined(separator: "; ") : ""
        return dictionaryHighlighted(first, range: hit.highlightRange, base: Theme.secondaryText)
            + Text(verbatim: tail).foregroundStyle(Theme.secondaryText)
    }

    @ViewBuilder
    private func entryBlock(
        _ hit: DictionarySearchHit, result: LookupResult
    ) -> some View {
        // Favorite-first: a starred entry leads the pager — reorders only,
        // the count unchanged. An unstepped row lands on its own entry.
        let promoted = FavoritesPromotion.promotingFavorites(
            in: result, identity: model.favorites.identity
        )
        let key = DictionarySearchState.lookupKey(for: hit)
        let fallback = DictionarySearchState.rowEntryIndex(for: hit, in: promoted)
        let index = state.validatedIndex(for: key, in: promoted, fallback: fallback)
        if let entry = promoted.entries[safe: index] {
            DictionaryEntryContentView(
                entry: entry,
                entryCount: promoted.entries.count,
                entryIndex: index,
                also: [],
                senseLimit: nil,
                glossLimit: nil,
                showsEntryPager: true,
                showsHeadword: false,
                // The collapsed header above already carries this row's badges —
                // match reason, commonness, level, and name types — so the
                // expanded block repeats none of them.
                showsBadges: false,
                onStepEntry: { step in
                    state.stepEntry(key, to: step, in: promoted)
                }
            )
        } else {
            dictionaryUnavailableText(surface: hit.headword ?? "")
        }
    }

    // MARK: - Actions

    /// The lookup candidate for an expandable row — nil when the hit has no
    /// headword, and there is nothing to look up. The expansion state is keyed
    /// by entry (`DictionarySearchState.lookupKey(for:)`), since several rows
    /// can share a headword; the star stays headword-keyed, so expanding
    /// 負ける here and starring it there are still the same word. `addedAt` is
    /// never read by the lookup path, so the transient value stays zero.
    private func lookupWord(for hit: DictionarySearchHit) -> FavoriteWord? {
        hit.headword.map { headword in
            FavoriteWord(headword: headword, reading: hit.reb, romaji: nil, addedAt: 0)
        }
    }

    private func isExpanded(_ hit: DictionarySearchHit) -> Bool {
        guard lookupWord(for: hit) != nil else { return false }
        return state.lookupState.isExpanded(key: DictionarySearchState.lookupKey(for: hit))
    }

    private func toggle(_ hit: DictionarySearchHit) {
        guard let word = lookupWord(for: hit) else { return }
        let candidate = LookupCandidate(text: word.headword, reading: word.reading)
        state.lookupState.toggle(key: DictionarySearchState.lookupKey(for: hit), candidate: candidate)
    }

    /// Stars the way every other star in the app does: the model decides, the
    /// window files the question. A word already starred answers with the
    /// removal question rather than un-starring, which is why an un-star here
    /// needs the window's alert — and an add, a refused press at the cap, and a
    /// broken store each report themselves, which is what calling the store
    /// directly from here threw away.
    private func toggleFavorite(_ hit: DictionarySearchHit) {
        forwardRemovalRequest(
            model.toggleFavorite(headword: hit.headword, reading: hit.reb),
            to: onFavoriteRemoval
        )
    }

    /// The row's star state, read only when the row has a headword to key it
    /// on — a hit with no headword carries neither the copy nor the star, so
    /// there is nothing to ask the store about.
    private func isFavorite(_ hit: DictionarySearchHit) -> Bool {
        guard let headword = hit.headword else { return false }
        return model.favorites.isFavorite(headword: headword)
    }
}

// MARK: - The search row's values

/// The search row for a hit — the shared row with this mode's values.
///
/// Split from the view so the mapping can be read, and pinned by a test,
/// without a window: the values below are the whole difference between the
/// two modes, and the owner reviews them as a table.
@MainActor
func searchWordRow<Extras: View, ResolvedContent: View>(
    hit: DictionarySearchHit,
    bindings: DictionaryWordRowBindings,
    @ViewBuilder extras: @escaping () -> Extras,
    @ViewBuilder resolvedContent: @escaping (LookupResult) -> ResolvedContent
) -> DictionaryWordRow<Extras, ResolvedContent> {
    DictionaryWordRow(
        headword: hit.rowHeadword,
        reading: hit.rowReading,
        romaji: hit.rowRomaji,
        headwordHighlightRange: hit.rowHeadwordHighlight,
        readingHighlightRange: hit.rowReadingHighlight,
        labelSpacing: DictionaryWordRowLayout.searchLabelSpacing,
        accessibilityHeadword: hit.rowHeadword,
        isExpanded: bindings.isExpanded,
        onToggle: bindings.onToggle,
        trailingHeadword: bindings.trailingHeadword,
        isFavorite: bindings.isFavorite,
        onToggleFavorite: bindings.onToggleFavorite,
        onCopy: bindings.onCopy,
        phase: bindings.phase,
        surface: hit.headword ?? "",
        extras: extras,
        resolvedContent: resolvedContent
    )
}

/// The search row's readings of a hit — the divergences from the Favorites
/// row, spelled out once and shared by the view and its tests.
///
/// The Favorites row reads a *stored* word; the search row reads the entry
/// the engine ranked, so every one of these is a derivation rather than a
/// stored snapshot.
extension DictionarySearchHit {
    /// The word the row shows: the entry's kanji writing, else its reading,
    /// else a dash for an entry that carries neither.
    var rowHeadword: String {
        headword ?? reb ?? "—"
    }

    /// The reading the row shows, or nil when it shows no reading line: a
    /// kanji-written entry carries one, a kana-only entry does not — its
    /// reading *is* the headword, and showing it twice would read as two
    /// different words. This gate is the caller's, and the Favorites row
    /// keeps its own.
    var rowReading: String? {
        keb != nil ? reb : nil
    }

    /// The romaji line, derived live from the entry's reading — the reason a
    /// romaji query and a kana query land on a row that looks the same. The
    /// Favorites row renders a stored snapshot instead.
    var rowRomaji: String? {
        reb.flatMap { reading in KanaRomaji.romaji(fromKana: reading) }
    }

    /// The span lit up in the headword: the kanji writing when the kanji
    /// matched, or the reading when a kana-only entry matched on it. The span
    /// is **scalar**-indexed into the rendered string (see `MatchHighlight`),
    /// so a katakana headword reached through its hiragana candidate lights up
    /// the right morae rather than the same offsets of a different script.
    var rowHeadwordHighlight: Range<Int>? {
        (matchedField == .keb || (matchedField == .reb && keb == nil)) ? highlightRange : nil
    }

    /// The span lit up in the reading line: the reading when the reading
    /// matched.
    var rowReadingHighlight: Range<Int>? {
        matchedField == .reb ? highlightRange : nil
    }
}
