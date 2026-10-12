import SwiftUI

/// Full-dictionary search: one field that accepts Japanese, romaji, or an
/// English meaning, and a filter row narrowing words from names and rare
/// entries.
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

    /// How far a row's trailing controls drop onto the headword's line — the
    /// same 26pt headword the Favorites rows use, so the same offset. The
    /// row's type is fixed, so this cannot drift with the UI scale.
    private static let trailingLineDrop: CGFloat = 4

    /// One chip in a row's badge line. `isMatch` chips carry the leading
    /// magnifier that marks them as the row's *reason for being here*, rather
    /// than as one more fact about the word.
    private struct Badge {
        let text: String
        let color: Color
        var isMatch = false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            searchField
            filterRow
            results
        }
        .padding(14)
    }

    // MARK: - Chrome

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondaryText)
            TextField("Search the dictionary", text: query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused(searchFocus, equals: true)
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
    }

    private var query: Binding<String> {
        Binding(
            get: { state.query },
            set: { newValue in state.query = newValue }
        )
    }

    private var filterRow: some View {
        HStack(spacing: 8) {
            ModePicker(
                help: "Which entries to search",
                modes: DictionarySearchFilters.Scope.allCases,
                selection: scope,
                label: \.label
            )
            commonOnlyToggle
            Spacer(minLength: 0)
        }
    }

    private var scope: Binding<DictionarySearchFilters.Scope> {
        Binding(
            get: { state.filters.scope },
            set: { newValue in
                var filters = state.filters
                filters.scope = newValue
                // Nothing to clear here: `DictionarySearchState.filters`
                // normalizes COMMON away under Names on the way in, for every
                // writer, so the chip below can never be left reading live
                // over a scope that can never satisfy it.
                state.filters = filters
            }
        )
    }

    /// Names are never common in the source data, so "Common only" over Names
    /// is structurally zero rows. `DictionarySearchState` clears the flag on the
    /// way into that scope, so none is left behind reading as a live filter the
    /// user could switch back off.
    private var commonOnlyToggle: some View {
        let disabled = state.filters.scope == .names
        let selected = state.filters.commonOnly && !disabled
        return Button {
            var filters = state.filters
            filters.commonOnly.toggle()
            state.filters = filters
        } label: {
            DictionaryBadgeView(
                text: "COMMON", color: selected ? Theme.accentPink : Theme.secondaryText
            )
            .opacity(disabled ? 0.4 : 1)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .hoverHighlight(Capsule(), isEnabled: !selected && !disabled)
        .help(disabled
            ? "Name entries are never marked common"
            : "Only entries the dictionary marks common")
        .accessibilityLabel("Common entries only")
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
        .help("Show \(DictionarySearchEngine.pageSize) more results")
        .accessibilityLabel("Load \(DictionarySearchEngine.pageSize) more results")
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

    private func hitCard(_ hit: DictionarySearchHit) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            hitHeader(hit)
            if isExpanded(hit) {
                expandedEntry(hit)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    /// Card header: headword + inline kana, the romaji line, the badge row, and
    /// the gloss preview. The label is greedy so it claims every pixel the
    /// trailing controls do not — which both keeps them trailing and makes the
    /// whole header width the expand button. The controls are siblings rather
    /// than part of that button, so the chevron can read last.
    private func hitHeader(_ hit: DictionarySearchHit) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Button {
                toggle(hit)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    headwordBlock(hit)
                    romajiLine(hit)
                    badgeRow(hit)
                    glossPreview(hit)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            .help(isExpanded(hit) ? "Hide definition" : "Show definition")
            trailingControls(hit)
        }
    }

    /// The headword and its kana: inline while the pair fits the row, stacked
    /// with the kana above the word when it does not. Both texts are
    /// `fixedSize` inline, so a long entry would otherwise draw past the card's
    /// stroke on a window that cannot resize.
    private func headwordBlock(_ hit: DictionarySearchHit) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                headwordText(hit)
                    .fixedSize(horizontal: true, vertical: false)
                if hit.keb != nil, let reading = hit.reb {
                    readingText(hit, reading, size: 14)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                if hit.keb != nil, let reading = hit.reb {
                    readingText(hit, reading, size: 12)
                }
                headwordText(hit)
            }
        }
    }

    /// The 26pt headword, highlighted when it is the field that matched. The
    /// span is **scalar**-indexed into the rendered string (see
    /// `MatchHighlight`), so a katakana headword reached through its hiragana
    /// candidate lights up the right morae rather than the same offsets of a
    /// different script.
    private func headwordText(_ hit: DictionarySearchHit) -> some View {
        highlighted(
            hit.headword ?? hit.reb ?? "—",
            range: (hit.matchedField == .keb || (hit.matchedField == .reb && hit.keb == nil)) ? hit.highlightRange : nil,
            base: Theme.primaryText
        )
        .font(.system(size: 26))
        .lineLimit(1)
        .textSelection(.disabled)
    }

    private func readingText(
        _ hit: DictionarySearchHit, _ reading: String, size: CGFloat
    ) -> some View {
        highlighted(
            reading,
            range: hit.matchedField == .reb ? hit.highlightRange : nil,
            base: Theme.annotationPink
        )
        .font(.system(size: size, weight: .medium))
        .lineLimit(1)
        .textSelection(.disabled)
    }

    /// The reading transliterated — the same mono line every Favorites row
    /// carries, and the reason a romaji query and a kana query land on a row
    /// that looks the same.
    @ViewBuilder
    private func romajiLine(_ hit: DictionarySearchHit) -> some View {
        if let romaji = hit.reb.flatMap({ reb in KanaRomaji.romaji(fromKana: reb) }) {
            Text(verbatim: romaji)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(1)
                .textSelection(.disabled)
        }
    }

    /// The match badge first, then the entry's own metadata. The match badge
    /// leads because it is the part with no counterpart on a Favorites row: it
    /// is what tells the user whether this row answered what they typed.
    private func badgeRow(_ hit: DictionarySearchHit) -> some View {
        let rowBadges = badges(for: hit)
        return FlowLayout(
            spacing: 6, lineSpacing: 6, fingerprint: rowBadges.map(\.text).joined(separator: "\n")
        ) {
            ForEach(Array(rowBadges.enumerated()), id: \.offset) { _, badge in
                DictionaryBadgeView(
                    text: badge.text,
                    color: badge.color,
                    icon: badge.isMatch ? "magnifyingglass" : nil
                )
            }
        }
    }

    private func badges(for hit: DictionarySearchHit) -> [Badge] {
        var badges = [Badge(text: hit.matchKind.badgeLabel, color: Theme.accentPink, isMatch: true)]
        if hit.common {
            badges.append(Badge(text: "COMMON", color: Theme.dotGreen))
        }
        if let jlpt = DictionaryContent.jlptBadge(hit.jlpt) {
            badges.append(Badge(text: jlpt, color: Theme.brandViolet))
        }
        if hit.isName {
            // The real type badges, not a generic NAME chip: this row's header is
            // the only place a name's types appear now that the expanded block
            // drops its badge row, and `DictionaryContent` maps them exactly as
            // the entry view does. A name whose senses carry no tags adds
            // nothing rather than a chip that claims what it does not know.
            for label in DictionaryContent.nameTypeBadges(posTokens: hit.namePosTokens) {
                badges.append(Badge(text: label, color: Theme.brandViolet))
            }
        }
        return badges
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
        return highlighted(first, range: hit.highlightRange, base: Theme.secondaryText)
            + Text(verbatim: tail).foregroundStyle(Theme.secondaryText)
    }

    /// Copy, star, and the disclosure chevron — the same control order the
    /// Favorites rows use, so the two lists share one gesture vocabulary. One
    /// drop for the whole group: all three boxes are 22pt and centered on each
    /// other here, so a single offset puts them on the headword's line.
    private func trailingControls(_ hit: DictionarySearchHit) -> some View {
        HStack(alignment: .center, spacing: 4) {
            DictionaryCopyButton(
                placement: .icon, help: "Copy the headword",
                action: { model.copySnippet(hit.headword ?? "") }
            )
            starButton(hit)
            chevronButton(hit)
        }
        .padding(.top, Self.trailingLineDrop)
    }

    private func starButton(_ hit: DictionarySearchHit) -> some View {
        let headword = hit.headword ?? ""
        let starred = model.favorites.isFavorite(headword: headword)
        return Button {
            toggleFavorite(hit)
        } label: {
            Image(systemName: starred ? "star.fill" : "star")
                .font(.system(size: 18))
                .foregroundStyle(starred ? Theme.favoriteStarYellow : Theme.secondaryText)
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .help(starred
            ? "Remove “\(headword)” from favorites"
            : "Add “\(headword)” to favorites")
        .accessibilityLabel(starred
            ? "Remove “\(headword)” from favorites"
            : "Add “\(headword)” to favorites")
    }

    private func chevronButton(_ hit: DictionarySearchHit) -> some View {
        let isExpanded = isExpanded(hit)
        return Button {
            toggle(hit)
        } label: {
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .help(isExpanded ? "Hide definition" : "Show definition")
        .accessibilityLabel(isExpanded ? "Hide definition" : "Show definition")
    }

    /// Expanded block: a divider over the shared entry view, so a row's full
    /// entry is pixel-identical to the popover's and the sidebar card's. The
    /// headword block is suppressed — this row already shows the word, its
    /// kana, its romaji, and its badges two lines above.
    @ViewBuilder
    private func expandedEntry(_ hit: DictionarySearchHit) -> some View {
        // A hit with no headword at all cannot be expanded — nothing to key the
        // shared expansion state on, and nothing to look up.
        if let word = lookupWord(for: hit) {
            VStack(alignment: .leading, spacing: 8) {
                Rectangle().fill(Theme.divider).frame(height: 1)
                switch state.lookupState.phase(for: word) {
                case .idle, .loading:
                    ProgressView()
                        .controlSize(.small)
                case let .resolved(result):
                    entryBlock(hit, word: word, result: result)
                case .notFound:
                    DictionaryNotFoundView(
                        surface: hit.headword ?? "", related: [], copyPlacement: .icon,
                        onCopy: { model.copySnippet(hit.headword ?? "") }
                    )
                case let .failed(message):
                    lookupUnavailable(hit, message: message)
                }
            }
        }
    }

    @ViewBuilder
    private func entryBlock(
        _ hit: DictionarySearchHit, word: FavoriteWord, result: LookupResult
    ) -> some View {
        let index = state.entryIndex(for: word.headword)
        if let entry = result.entries[safe: index] {
            DictionaryEntryContentView(
                entry: entry,
                entryCount: result.entries.count,
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
                    state.stepEntry(word.headword, delta: step, count: result.entries.count)
                }
            )
        } else {
            lookupUnavailable(hit)
        }
    }

    private func lookupUnavailable(_ hit: DictionarySearchHit, message: String = "") -> some View {
        let headword = hit.headword ?? ""
        return Text(message.isEmpty ? "No definition for “\(headword)”." : message)
            .font(.system(size: 12))
            .foregroundStyle(Theme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Actions

    /// The row key the shared expansion state uses. A search hit has no
    /// `FavoriteWord` of its own and does not need one: that state is keyed by
    /// headword, and the headword is exactly what `FavoritesView` keys its rows
    /// by — so expanding 負ける here and starring it there are the same row as
    /// far as the window is concerned. `addedAt` is never read by the lookup
    /// path, so the transient value stays zero.
    private func lookupWord(for hit: DictionarySearchHit) -> FavoriteWord? {
        hit.headword.map { headword in
            FavoriteWord(headword: headword, reading: hit.reb, romaji: nil, addedAt: 0)
        }
    }

    private func isExpanded(_ hit: DictionarySearchHit) -> Bool {
        guard let word = lookupWord(for: hit) else { return false }
        return state.lookupState.isExpanded(word)
    }

    private func toggle(_ hit: DictionarySearchHit) {
        guard let word = lookupWord(for: hit) else { return }
        state.lookupState.toggle(word)
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

    // MARK: - Highlight

    /// Splits a field into before/match/after and tints the match. Nothing is
    /// emitted for a nil range — a lemma row, or a field that did not match —
    /// which is exactly the "no highlight" the badge then has to explain.
    ///
    /// The base color is applied *per part* rather than to the composed text:
    /// a `foregroundStyle` on the whole concatenation would override the
    /// accent on the middle segment and the highlight would simply not show.
    private func highlighted(_ text: String, range: Range<Int>?, base: Color) -> Text {
        guard let range else { return Text(verbatim: text).foregroundStyle(base) }
        let parts = MatchHighlight.split(text, at: range)
        return Text(verbatim: parts.before).foregroundStyle(base)
            + Text(verbatim: parts.match).foregroundStyle(Theme.accentPink)
            + Text(verbatim: parts.after).foregroundStyle(base)
    }
}
