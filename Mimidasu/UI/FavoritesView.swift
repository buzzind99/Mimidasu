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
/// Fixed 460 × 608 with a `ScrollView` rather than a `List`: a fixed panel
/// plus a scrolling list means expanding a card *scrolls* instead of growing
/// the window, which a `List` cannot do without swallowing the expansion.
struct FavoritesView: View {
    var model: AppModel
    /// Hoisted to the host so a mode switch cannot take the query, the rows,
    /// or the expanded state with the view.
    let state: FavoritesWindowState
    /// Files the un-star question on the window's single alert slot — shared
    /// with the Dictionary mode, so the two can never stack two dialogs.
    var onFavoriteRemoval: (String) -> Void

    /// How far a row's trailing controls drop onto the headword's line: they
    /// are top-aligned to the row, and the 26pt headword is what sets the
    /// first line, so their 22pt boxes need half the difference. The row's
    /// type is fixed, so this does not drift with the UI scale.
    private static let trailingLineDrop: CGFloat = 4

    var body: some View {
        windowContent(state.results)
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

    private func favoriteCard(_ word: FavoriteWord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            favoriteHeader(word)
            if state.lookupState.isExpanded(word) {
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
                state.lookupState.toggle(word)
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
            .help(state.lookupState.isExpanded(word) ? "Hide definition" : "Show definition")
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
        let expanded = state.lookupState.isExpanded(word)
        return Button {
            state.lookupState.toggle(word)
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
            switch state.lookupState.phase(for: word) {
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
            onFavoriteRemoval(word.headword)
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
}
