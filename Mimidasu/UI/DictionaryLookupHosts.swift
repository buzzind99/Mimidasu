import SwiftUI

// MARK: - Shared popover binding

extension AppModel {
    /// The "get: source match / set: dismiss" binding behind every
    /// dictionary-popover presentation (the live strip and each transcript
    /// word anchor): true only while the selection's anchor is `source`;
    /// dismissal (and Escape) clears the selection only when this surface
    /// owns it, so a stale binding from a virtualized-off-screen row can
    /// never clobber a newer selection.
    func lookupPopoverBinding(for source: SelectedLookup.Source) -> Binding<Bool> {
        Binding(
            get: { self.selectedLookup?.source == source },
            set: { isPresented in
                if !isPresented {
                    self.dismissLookupPopover(source: source)
                }
            }
        )
    }
}

// MARK: - Shared row strings

/// The disclosure help both row kinds carry — the collapsed header button and
/// the chevron — shared so the search list and the favorites list name the
/// same gesture with the same words.
func expansionHelp(_ isExpanded: Bool) -> String {
    isExpanded ? "Hide definition" : "Show definition"
}

// MARK: - Shared row text

/// Splits a field into before/match/after and tints the match. Nothing is
/// emitted for a nil range — a lemma row, or a field that did not match —
/// which is exactly the "no highlight" the badge then has to explain.
///
/// The base color is applied *per part* rather than to the composed text:
/// a `foregroundStyle` on the whole concatenation would override the accent
/// on the middle segment and the highlight would simply not show.
func dictionaryHighlighted(_ text: String, range: Range<Int>?, base: Color) -> Text {
    guard let range else { return Text(verbatim: text).foregroundStyle(base) }
    let parts = MatchHighlight.split(text, at: range)
    return Text(verbatim: parts.before).foregroundStyle(base)
        + Text(verbatim: parts.match).foregroundStyle(Theme.accentPink)
        + Text(verbatim: parts.after).foregroundStyle(base)
}

/// The "no definition" line an expanded row falls back to: the word's own
/// surface when the lookup simply found nothing, or the failure's own
/// message when it could not answer.
func dictionaryUnavailableText(surface: String, message: String = "") -> some View {
    Text(message.isEmpty ? "No definition for “\(surface)”." : message)
        .font(.system(size: 12))
        .foregroundStyle(Theme.secondaryText)
        .fixedSize(horizontal: false, vertical: true)
}

// MARK: - Shared list row

/// A dictionary row's state and its controls: what the row knows about its
/// own expansion and lookup, and what its buttons do.
///
/// The two modes hand the row the same shape of state and differ only in the
/// values — which is what makes the difference between them a table rather
/// than a second row.
struct DictionaryWordRowBindings {
    /// Whether the row is open.
    var isExpanded: Bool
    /// The lookup phase behind the expanded block.
    var phase: FavoritesLookupState.Phase
    /// The headword the trailing controls act on; nil hides the copy and the
    /// star — a search hit with no headword has nothing to key them on. The
    /// row reads this value; the caller does not re-derive it.
    var trailingHeadword: String?
    /// Whether the trailing star reads as filled. The Favorites mode hands
    /// over `true` — every row in that list is starred by construction.
    var isFavorite: Bool
    /// Opens or closes the row.
    var onToggle: () -> Void
    /// The trailing star's action. The Favorites mode's un-star-with-recheck
    /// lives in the caller's closure, not in the row.
    var onToggleFavorite: () -> Void
    /// Copies a headword.
    var onCopy: (String) -> Void
}

/// One dictionary list row, shared by the reference window's two modes: the
/// search results and the favorites. A search result and a starred word are
/// the same object to this app — the dictionary is where a word is defined,
/// the favorite list is where the user decided to keep it — so the two modes
/// render through one row, and every difference between them is an explicit
/// parameter here rather than a copy.
///
/// The row owns the chrome: the card frame, the header, the headword block,
/// the romaji line, the trailing controls, the chevron, and the expansion
/// frame. What the two modes disagree about is *content*, and content
/// arrives through two closures — `extras` adds what search adds under the
/// headword (its badge row and gloss preview), and `resolvedContent` renders
/// what the row expanded into (the two modes pick different entries and show
/// different chrome there).
///
/// The row reads no store and no model: the star's filled state and the
/// lookup's phase are handed in, so the same row serves a mode whose star is
/// live and a mode whose star is always filled.
struct DictionaryWordRow<Extras: View, ResolvedContent: View>: View {
    /// The word the row shows.
    let headword: String
    /// The kana reading, or nil when the row shows no reading line. *Whether*
    /// a word has one is the caller's decision: search shows a reading only
    /// for a kanji-written entry, Favorites shows the one it stored —
    /// sharing the rule would render a kana-only favorite's kana twice.
    let reading: String?
    /// The romaji line's text, or nil for no line. Search derives it live
    /// from the entry's reading; Favorites renders the snapshot it stored
    /// when the word was starred.
    let romaji: String?
    /// The span lit up in the headword, or nil for none.
    let headwordHighlightRange: Range<Int>?
    /// The span lit up in the reading, or nil for none.
    let readingHighlightRange: Range<Int>?
    /// The gap between the header label's lines.
    let labelSpacing: CGFloat
    /// What the header's expand button reads as.
    let accessibilityHeadword: String
    /// Whether the row is open.
    let isExpanded: Bool
    /// Opens or closes the row.
    let onToggle: () -> Void
    /// The headword the trailing controls act on; nil hides the copy and the
    /// star — a search hit with no headword has nothing to key them on.
    let trailingHeadword: String?
    /// Whether the trailing star reads as filled.
    let isFavorite: Bool
    /// The trailing star's action. The Favorites mode's un-star-with-recheck
    /// lives in the caller's closure, not here.
    let onToggleFavorite: () -> Void
    /// Copies a headword.
    let onCopy: (String) -> Void
    /// The lookup phase behind the expanded block.
    let phase: FavoritesLookupState.Phase
    /// The word the expanded block's not-found state names.
    let surface: String
    /// What the row adds under the headword and the romaji.
    @ViewBuilder let extras: () -> Extras
    /// What the row shows once its lookup resolved.
    @ViewBuilder let resolvedContent: (LookupResult) -> ResolvedContent

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if isExpanded {
                expandedBlock
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    /// The header: the headword block, the romaji line, and whatever the
    /// mode adds below them, all one button down to the divider. The label
    /// is greedy so it claims every pixel the trailing controls do not —
    /// which both keeps them trailing and makes the whole header width the
    /// expand button. The controls are siblings rather than part of that
    /// button, so the chevron can read last.
    private var header: some View {
        let helpText = expansionHelp(isExpanded)
        return HStack(alignment: .top, spacing: 8) {
            Button {
                onToggle()
            } label: {
                VStack(alignment: .leading, spacing: labelSpacing) {
                    headwordBlock
                    romajiLine
                    extras()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            .help(helpText)
            .accessibilityLabel("\(accessibilityHeadword), \(helpText)")
            trailingControls
        }
    }

    /// The headword and its kana: inline while the pair fits the row, stacked
    /// with the kana above the word when it does not. Both texts are
    /// `fixedSize` inline, so a long entry would otherwise draw past the
    /// card's stroke on a window that cannot resize.
    private var headwordBlock: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                headwordText
                    .fixedSize(horizontal: true, vertical: false)
                if let reading {
                    readingText(reading, size: 14)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                if let reading {
                    readingText(reading, size: 12)
                }
                headwordText
            }
        }
    }

    /// The 26pt headword, highlighted when it is the field that matched. The
    /// span is **scalar**-indexed into the rendered string (see
    /// `MatchHighlight`), so a katakana headword reached through its hiragana
    /// candidate lights up the right morae rather than the same offsets of a
    /// different script.
    private var headwordText: some View {
        dictionaryHighlighted(headword, range: headwordHighlightRange, base: Theme.primaryText)
            .font(.system(size: 26))
            .lineLimit(1)
            .textSelection(.disabled)
    }

    private func readingText(_ reading: String, size: CGFloat) -> some View {
        dictionaryHighlighted(reading, range: readingHighlightRange, base: Theme.annotationPink)
            .font(.system(size: size, weight: .medium))
            .lineLimit(1)
            .textSelection(.disabled)
    }

    /// The reading transliterated — the same mono line every Favorites row
    /// carries, and the reason a romaji query and a kana query land on a row
    /// that looks the same.
    @ViewBuilder
    private var romajiLine: some View {
        if let romaji {
            Text(verbatim: romaji)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(1)
                .textSelection(.disabled)
        }
    }

    /// Copy, star, and the disclosure chevron — the same control order both
    /// modes use, so the two lists share one gesture vocabulary. One drop for
    /// the whole group: all three boxes are 22pt and centered on each other
    /// here, so a single offset puts them on the headword's line.
    private var trailingControls: some View {
        HStack(alignment: .center, spacing: 4) {
            if let trailingHeadword {
                DictionaryCopyButton(
                    placement: .icon, help: "Copy the headword",
                    action: { onCopy(trailingHeadword) }
                )
                DictionaryFavoriteButton(
                    isFavorite: isFavorite,
                    subject: trailingHeadword,
                    style: .popover,
                    action: onToggleFavorite
                )
            }
            chevronButton
        }
        .padding(.top, Theme.dictionaryTrailingLineDrop)
    }

    private var chevronButton: some View {
        let helpText = expansionHelp(isExpanded)
        return Button {
            onToggle()
        } label: {
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .help(helpText)
        .accessibilityLabel(helpText)
    }

    /// Expanded block: a divider over the row's own lookup, so a row's full
    /// entry is pixel-identical to the popover's and the sidebar card's. The
    /// headword block is suppressed — this row already shows the word, its
    /// kana, its romaji, and (in search) its badges two lines above.
    ///
    /// The frame is shared; what a resolved lookup *shows* is not, and stays
    /// with the caller.
    private var expandedBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Rectangle().fill(Theme.divider).frame(height: 1)
            switch phase {
            case .idle, .loading:
                ProgressView()
                    .controlSize(.small)
            case let .resolved(result):
                resolvedContent(result)
            case .notFound:
                DictionaryNotFoundView(
                    surface: surface, related: [], copyPlacement: .icon,
                    onCopy: { onCopy(surface) }
                )
            case let .failed(message):
                dictionaryUnavailableText(surface: surface, message: message)
            }
        }
    }
}

// MARK: - Row spacing

/// The shared row's per-mode constants: the header label's line spacing,
/// which differs between the two modes — the search label carries a badge
/// row and a gloss preview under the headword and the romaji, the Favorites
/// label carries nothing else.
enum DictionaryWordRowLayout {
    /// The search mode's spacing: the badge row and the gloss preview sit
    /// under the headword and the romaji with a wider gap than those two
    /// lines alone need.
    static let searchLabelSpacing: CGFloat = 4
    /// The Favorites mode's spacing: the headword and the romaji are the
    /// label's whole content, and sit closer together.
    static let favoritesLabelSpacing: CGFloat = 2
}

// MARK: - Hosts

/// The un-star step every star site runs: the model has already decided whether
/// a press was an add or a removal still to be confirmed, and only the latter is
/// worth a question. Filing the question is the window's job, so the headword
/// goes out and the host keeps nothing.
///
/// Takes the outcome rather than the entry so all three sites share it — the
/// dictionary search row has a `DictionarySearchHit`, not a `JMDictEntry`, and a
/// signature the row cannot call is a signature that will drift into a second,
/// private copy.
@MainActor
func forwardRemovalRequest(_ outcome: FavoriteToggle, to onRequest: (String) -> Void) {
    if case let .pendingRemoval(headword) = outcome {
        onRequest(headword)
    }
}

/// The popover presented by the surface that owns the selection: the shared
/// entry content with the icon copy control, or the not-found state with
/// its related suggestions.
struct DictionaryPopoverView: View {
    var model: AppModel
    let selected: SelectedLookup
    /// Raises the window-level un-star question. The popover cannot own it: an
    /// alert inside a `.popover` presents as a sheet on the popover's own
    /// window, and closing the popover underneath it strands that sheet's
    /// dimming backdrop. The main window presents it instead, so the question
    /// outlives the popover — the same place the sidebar card's lands.
    let onFavoriteRemovalRequest: (String) -> Void

    var body: some View {
        Group {
            switch selected.content {
            case let .found(result, also, origin):
                if let entry = result.entries[safe: selected.entryIndex] {
                    DictionaryEntryContentView(
                        entry: entry,
                        entryCount: result.entries.count,
                        entryIndex: selected.entryIndex,
                        also: also,
                        displayOrigin: origin,
                        senseLimit: nil,
                        glossLimit: nil,
                        copyPlacement: .icon,
                        isFavorite: model.isFavorite(entry),
                        favoriteStyle: .popover,
                        onToggleFavorite: { requestRemovalIfPending(entry) },
                        onCopy: {
                            model.copySnippet(entry.headword ?? "")
                        },
                        onSelectAlso: { result in model.selectAlsoPill(result) },
                        isFavoritePillLead: { result in model.isFavoriteLead(result) },
                        onStepEntry: { index in model.stepLookupEntry(to: index) }
                    )
                }
            case let .notFound(surface, related):
                DictionaryNotFoundView(
                    surface: surface, related: related, copyPlacement: .icon,
                    onSelectRelated: { result in model.selectAlsoPill(result) },
                    onCopy: { model.copySnippet(surface) }
                )
            }
        }
        .padding(16)
        .frame(width: 400, alignment: .topLeading)
        .background(Theme.toastBackground)
    }

    /// The model decides whether a press was an add or a removal to confirm;
    /// only a removal raises the question.
    private func requestRemovalIfPending(_ entry: JMDictEntry) {
        forwardRemovalRequest(model.toggleFavorite(entry), to: onFavoriteRemovalRequest)
    }
}

/// The sidebar DICTIONARY card: last lookup pinned for the session, or an
/// empty state (header + hint) before the first hit. Never collapses the
/// slot; visibility itself is mode-gated by `SidebarView`.
///
/// Every sense and gloss is expanded; when they don't fit the free sidebar
/// space only the sense rows scroll — the headword/badges/pitch block above
/// and the "also:" row below stay fixed. The `GeometryReader` slot claims
/// the space the engine-mode `Spacer()` would take (`layoutPriority(1)` in
/// `SidebarView`), while the visible chrome keeps hugging its content.
struct DictionaryCardView: View {
    var model: AppModel
    /// Raises the window-level un-star question. Shared with
    /// `DictionaryPopoverView` — one slot, one alert, in the window that owns
    /// both hosts (see `FavoriteRemovalConfirmation`).
    let onFavoriteRemovalRequest: (String) -> Void

    /// Measured fixed-chrome pieces feeding `sensesViewport`: the
    /// DICTIONARY label, the entry's fixed top section, and the "also:"
    /// row. All are viewport-independent, so the derivation settles
    /// instead of feeding back.
    @State private var labelHeight: CGFloat = 0
    @State private var topSectionHeight: CGFloat = 0
    @State private var alsoHeight: CGFloat = 0
    /// Natural height of all sense rows — what the viewport clamps against.
    @State private var sensesContentHeight: CGFloat = 0
    /// Whether the pointer is on the DICTIONARY kicker, which tints the opener
    /// (`dictionaryOpener`).
    @State private var isHovering = false

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        GeometryReader { geo in
            card(freeHeight: geo.size.height)
        }
    }

    private func card(freeHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                dictionaryOpener
                Spacer(minLength: 8)
                if let pinned = model.pinnedLookup,
                   case let .found(result, _, _) = pinned.content,
                   result.entries.count > 1
                {
                    DictionaryEntryPager(
                        entryIndex: pinned.entryIndex,
                        entryCount: result.entries.count,
                        onStep: { index in model.stepLookupEntry(to: index) }
                    )
                }
            }
            // The pager's height is reserved even when it is absent, so the
            // header row never changes height between lookups.
            .frame(height: DictionaryEntryPager.height)
            .onHeightChange { height in labelHeight = height }
            if let pinned = model.pinnedLookup {
                pinnedContent(pinned, freeHeight: freeHeight)
            } else {
                emptyHint
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    /// The model decides whether a press was an add or a removal to confirm;
    /// only a removal raises the question.
    private func requestRemovalIfPending(_ entry: JMDictEntry) {
        forwardRemovalRequest(model.toggleFavorite(entry), to: onFavoriteRemovalRequest)
    }

    /// The card's kicker doubles as the card's opener: the card holds one
    /// pinned lookup, and the window holds the whole searchable dictionary, so
    /// the label is the one control on the card that reaches it. It reads as a
    /// link rather than as chrome — pointer, hover tint, and the window's own
    /// book glyph — because a static kicker next to a live entry would promise
    /// nothing. The tint is the shared accent, the one the reference window's
    /// switcher already uses to mark the selected mode.
    private var dictionaryOpener: some View {
        Button {
            ReferenceWindow.open(.dictionary, with: openWindow)
        } label: {
            HStack(spacing: 4) {
                KickerLabel("DICTIONARY", color: kickerColor)
                Image(systemName: ReferenceMode.dictionary.icon)
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(kickerColor)
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .onHover { hovering in isHovering = hovering }
        .help("Search the dictionary")
        .accessibilityLabel("Search the dictionary")
    }

    private var kickerColor: Color {
        isHovering ? Theme.accentPink : Theme.secondaryText
    }

    /// The pinned content per state: the shared entry view for a found
    /// lookup, the not-found state with its related suggestions otherwise.
    /// The not-found block feeds the top-section probe so the (sense-less)
    /// viewport math stays settled while it is up.
    @ViewBuilder
    private func pinnedContent(_ pinned: PinnedLookup, freeHeight: CGFloat) -> some View {
        switch pinned.content {
        case let .found(result, also, origin):
            if let entry = result.entries[safe: pinned.entryIndex] {
                DictionaryEntryContentView(
                    entry: entry,
                    entryCount: result.entries.count,
                    entryIndex: pinned.entryIndex,
                    also: also,
                    displayOrigin: origin,
                    senseLimit: nil,
                    glossLimit: nil,
                    // The card is the narrow host — a multi-tag sense
                    // stacks its tags above the gloss only when the inline
                    // row doesn't fit (see the flag).
                    wrapsSensePOS: true,
                    sensesViewportHeight: sensesViewport(freeHeight: freeHeight),
                    onTopSectionHeightChange: { height in topSectionHeight = height },
                    onAlsoHeightChange: { height in alsoHeight = height },
                    onSensesHeightChange: { height in sensesContentHeight = height },
                    copyPlacement: .icon,
                    showsEntryPager: false,
                    isFavorite: model.isFavorite(entry),
                    favoriteStyle: .card,
                    onToggleFavorite: { requestRemovalIfPending(entry) },
                    onCopy: {
                        model.copySnippet(entry.headword ?? "")
                    },
                    onSelectAlso: { result in model.selectAlsoPill(result) },
                    isFavoritePillLead: { result in model.isFavoriteLead(result) },
                    onStepEntry: { index in model.stepLookupEntry(to: index) }
                )
            } else {
                emptyHint
            }
        case let .notFound(surface, related):
            DictionaryNotFoundView(
                surface: surface, related: related, copyPlacement: .icon,
                onSelectRelated: { result in model.selectAlsoPill(result) },
                onCopy: { model.copySnippet(surface) }
            )
            .onHeightChange { height in topSectionHeight = height }
            .onAppear {
                // Probes this state doesn't mount keep the viewport
                // math at their zero-content values.
                alsoHeight = 0
                sensesContentHeight = 0
            }
        }
    }

    private var emptyHint: some View {
        Text("Tap a word in the transcript to see its definition here.")
            .font(.system(size: 11))
            .foregroundStyle(Theme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Height for the senses viewport: the full row height when everything
    /// fits, otherwise whatever is left of the sidebar slot after the fixed
    /// chrome (card padding, label + gap, top section + gap, "also:" row +
    /// gap) and the engine-mode `Spacer` minimum below the card.
    private func sensesViewport(freeHeight: CGFloat) -> CGFloat {
        let chrome = 2 * 14 // card padding
            + labelHeight + 10
            + topSectionHeight + 8
            + alsoHeight + 8
        let room = max(0, freeHeight - chrome - 8)
        return min(sensesContentHeight, room)
    }
}
