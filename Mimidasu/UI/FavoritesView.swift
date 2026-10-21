import SwiftUI

/// Favorites mode content: the user's starred words, searchable, each row
/// expanding into the same live JMDict entry view the popover renders.
///
/// Rows borrow the sidebar dictionary card's visual language (headword +
/// inline kana, mono romaji, trailing controls) — `DictionaryCardView`
/// already owns "a Japanese word, rendered" — so amber means exactly one
/// thing in this app: *this word is recolored in your transcript*. The
/// notice card is where that story is told.
///
/// This is one mode of the reference window, so the frame, the surface, the
/// header band, and the window-close reset live in `ReferenceWindowView` /
/// `FavoritesWindowState`; what is left here is the mode's own content.
/// Fixed-size panel (`ReferenceWindow.width` × `.height`) with a `ScrollView`
/// rather than a `List`: a fixed panel plus a scrolling list means expanding a
/// card *scrolls* instead of growing the window, which a `List` cannot do
/// without swallowing the expansion.
struct FavoritesView: View {
    var model: AppModel
    /// Hoisted to the host so a mode switch cannot take the query, the rows,
    /// or the expanded state with the view.
    let state: FavoritesWindowState
    /// Files the un-star question on the window's single alert slot — shared
    /// with the Dictionary mode, so the two can never stack two dialogs.
    var onFavoriteRemoval: (String) -> Void
    /// The host's focus, shared with the Dictionary field so only one of the
    /// two can hold the caret — see `ReferenceWindowView`.
    let searchFocus: FocusState<Bool>.Binding

    var body: some View {
        windowContent(state.results)
            // Reconcile on activation. The `onChange` below is dead while this
            // mode is unmounted — a mode switch tears the view out of the
            // hierarchy — so a word removed elsewhere in that span (a search
            // row's star, the popover) would otherwise stay listed until the
            // next mutation landed here. Idempotent: it recomputes from the
            // store and prunes expansions.
            .onAppear {
                state.favoritesChanged()
            }
            .onChange(of: model.favorites.words) { _, _ in
                state.favoritesChanged()
            }
    }

    /// The window's whole content, in its own builder: `body` is this tree
    /// plus a modifier, and the two together overrun the type-checker's budget
    /// for one expression.
    private func windowContent(_ rows: [FavoriteWord]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            noticeCard
            if model.favorites.isDegraded {
                degradedState
            } else {
                searchField
                if rows.isEmpty {
                    emptyState
                } else {
                    rowList(rows)
                }
            }
        }
        // The host's header band and its divider replace the padding this
        // content used to draw for itself, so the top inset is all that is
        // left between the rule and the notice card.
        .padding(14)
    }

    /// The scrolling list. The animation is keyed on the open-row list, so a
    /// toggle animates the row it belongs to; it is not what makes a reopen
    /// clean — `FavoritesWindowState.resetForClose()` runs at close, and
    /// explicitly un-animated.
    private func rowList(_ rows: [FavoriteWord]) -> some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(rows) { word in
                    favoriteCard(word)
                }
            }
            .animation(.easeOut(duration: 0.18), value: state.lookupState.expanded)
        }
    }

    // MARK: - Chrome

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
            TextField("Search favorites", text: query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused(searchFocus, equals: true)
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

    /// The list is empty for two different reasons, and naming the search for a
    /// window nobody searched in reads as a bug: an empty field with nothing
    /// under it needs to say so. The text follows the query the rows were built
    /// from, so it never names a term the list has not applied yet.
    private var emptyState: some View {
        let trimmed = state.debouncedQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = trimmed.isEmpty
            ? "No favorites yet. Star a word from the dictionary popover."
            : "No favorites match “\(trimmed)”."
        return Text(message)
            .font(.system(size: 13))
            .foregroundStyle(Theme.secondaryText)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 24)
    }

    /// A store whose database failed to open. The read paths answer from
    /// empty memory, so without this branch the window renders that stub as
    /// "No favorites yet" — a lie about data the file may still hold. Nothing
    /// is lost: a healthy reopen serves the same file, which is what the
    /// search field is hidden for — querying a stub could only ever answer
    /// empty.
    private var degradedState: some View {
        Text("Favorites are unavailable — the store couldn't be opened. Your "
            + "starred words are untouched; restarting Mimidasu may help.")
            .font(.system(size: 13))
            .foregroundStyle(Theme.secondaryText)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 24)
    }

    // MARK: - Rows

    /// The row: the shared list row, with this mode's values. Favorites
    /// differs from search in four places — the label spacing, the reading
    /// gate, the romaji's source, and the star's meaning — and every one of
    /// them is an argument here rather than a second copy of the row.
    private func favoriteCard(_ word: FavoriteWord) -> some View {
        favoritesWordRow(
            word: word,
            bindings: DictionaryWordRowBindings(
                isExpanded: state.lookupState.isExpanded(word),
                phase: state.lookupState.phase(for: word),
                trailingHeadword: word.headword,
                isFavorite: true,
                onToggle: { state.lookupState.toggle(word) },
                onToggleFavorite: { unstar(word) },
                onCopy: { headword in model.copySnippet(headword) }
            ),
            extras: { EmptyView() },
            resolvedContent: { result in
                favoriteEntry(word, result: result)
            }
        )
    }

    /// What a resolved lookup shows under an open Favorites row: 1pt divider
    /// over the shared entry view, so a row's definition is pixel-identical to
    /// the popover's. The headword block is suppressed — this row already
    /// shows the word, its kana, and its romaji two lines above — leaving
    /// badges, pitch, and senses. No sense viewport (this is a scrolling
    /// column) and no pager: nothing pages a window row.
    @ViewBuilder
    private func favoriteEntry(_ word: FavoriteWord, result: LookupResult) -> some View {
        // Favorite-first: a starred entry leads, so the row opens on the word
        // the user kept. Entry order only — the pager stays off and the
        // "also:" pills stay empty, as below.
        let promoted = FavoritesPromotion.promotingFavorites(
            in: result, identity: model.favorites.identity
        )
        if let entry = promoted.entries.first {
            // No favorite or copy arguments: `showsHeadword: false` drops the
            // header row, which is the only place either is rendered, so
            // passing them would assert a control the expanded block cannot
            // show. The row's own header above carries both. `also: []` is the
            // same kind of empty: the pager and the "also:" pills both live in
            // the header row, and nothing may promote a window row's lookup —
            // threading real hits through would render pills whose taps do
            // nothing.
            DictionaryEntryContentView(
                entry: entry,
                entryCount: promoted.entries.count,
                entryIndex: 0,
                also: [],
                senseLimit: nil,
                glossLimit: nil,
                showsEntryPager: false,
                showsHeadword: false
            )
        } else {
            dictionaryUnavailableText(surface: word.headword)
        }
    }

    /// Unstar control: the shared favorite star, always filled here — every
    /// row in this list is starred by construction. Asks first — the shared
    /// alert commits the removal.
    private func unstar(_ word: FavoriteWord) {
        // A filled star asserts membership; re-check so a row that vanished cannot be re-added by the removal press.
        guard model.favorites.isFavorite(headword: word.headword) else { return }
        forwardRemovalRequest(
            model.toggleFavorite(headword: word.headword, reading: word.reading),
            to: onFavoriteRemoval
        )
    }
}

// MARK: - The favorites row's values

/// The Favorites row for a starred word — the shared row with this mode's
/// values.
///
/// Split from the view so the mapping can be read, and pinned by a test,
/// without a window: the values below are the whole difference between the
/// two modes, and the owner reviews them as a table.
@MainActor
func favoritesWordRow<Extras: View, ResolvedContent: View>(
    word: FavoriteWord,
    bindings: DictionaryWordRowBindings,
    @ViewBuilder extras: @escaping () -> Extras,
    @ViewBuilder resolvedContent: @escaping (LookupResult) -> ResolvedContent
) -> DictionaryWordRow<Extras, ResolvedContent> {
    DictionaryWordRow(
        headword: word.headword,
        reading: word.rowReading,
        romaji: word.rowRomaji,
        // A starred word carries no match to light up.
        headwordHighlightRange: nil,
        readingHighlightRange: nil,
        labelSpacing: DictionaryWordRowLayout.favoritesLabelSpacing,
        accessibilityHeadword: word.headword,
        isExpanded: bindings.isExpanded,
        onToggle: bindings.onToggle,
        trailingHeadword: bindings.trailingHeadword,
        // Every row in this list is starred by construction, and the
        // bindings say so.
        isFavorite: bindings.isFavorite,
        onToggleFavorite: bindings.onToggleFavorite,
        onCopy: bindings.onCopy,
        phase: bindings.phase,
        surface: word.headword,
        extras: extras,
        resolvedContent: resolvedContent
    )
}

/// The Favorites row's readings of a starred word — the divergences from the
/// search row, spelled out once and shared by the view and its tests.
///
/// The Favorites row reads a *stored* word, so every one of these is the
/// stored truth rather than a derivation: the romaji is the snapshot taken
/// when the word was starred, not a live transliteration.
extension FavoriteWord {
    /// The reading the row shows, or nil when the word carries none. There
    /// is **no** kanji gate here: a kana-only favorite stores its reading as
    /// its headword, and the row shows both — the stored truth. The search
    /// row keeps its own gate, and sharing the rule would render a kana-only
    /// favorite's kana twice.
    var rowReading: String? {
        reading
    }

    /// The romaji line the row shows: the snapshot stored when the word was
    /// starred. The search row derives its romaji live instead.
    var rowRomaji: String? {
        romaji
    }
}
