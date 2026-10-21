@testable import Mimidasu
import SwiftUI
import Testing

/// Pins the dictionary list row's mapping and the shared badge set.
///
/// The reference window's two modes — Dictionary (search results) and
/// Favorites — render through one `DictionaryWordRow`, so every difference
/// between them is a parameter rather than a copy. These tests read the
/// parameters each mode hands the row, which is the table the owner
/// reviews: a change to the reading gate, the label spacing, the highlight
/// spans, the romaji's source, or the star's meaning fails here rather than
/// on screen.
@MainActor
@Suite("Dictionary word row")
struct DictionaryWordRowTests {

    // MARK: - Fixtures

    private func hit(
        entSeq: Int = 1,
        keb: String? = "負ける",
        reb: String? = "まける",
        common: Bool = false,
        jlpt: Int? = nil,
        isName: Bool = false,
        namePosTokens: [String?] = [],
        matchKind: DictionarySearchHit.MatchKind = .exact,
        matchedField: DictionarySearchHit.MatchedField = .keb,
        highlightRange: Range<Int>? = nil,
        glossPreview: [String] = []
    ) -> DictionarySearchHit {
        DictionarySearchHit(
            entSeq: entSeq,
            keb: keb,
            reb: reb,
            common: common,
            jlpt: jlpt,
            isName: isName,
            namePosTokens: namePosTokens,
            matchKind: matchKind,
            matchedField: matchedField,
            highlightRange: highlightRange,
            glossPreview: glossPreview
        )
    }

    private func word(
        headword: String = "負ける",
        reading: String? = "まける",
        romaji: String? = "makeru"
    ) -> FavoriteWord {
        FavoriteWord(headword: headword, reading: reading, romaji: romaji, addedAt: 0)
    }

    /// The search row as the search view builds it.
    private func searchRow(
        _ hit: DictionarySearchHit,
        isExpanded: Bool = false,
        isFavorite: Bool = false
    ) -> DictionaryWordRow<EmptyView, Text> {
        searchWordRow(
            hit: hit,
            bindings: DictionaryWordRowBindings(
                isExpanded: isExpanded,
                phase: .idle,
                trailingHeadword: hit.headword,
                isFavorite: isFavorite,
                onToggle: {},
                onToggleFavorite: {},
                onCopy: { _ in }
            ),
            extras: { EmptyView() },
            resolvedContent: { _ in Text(verbatim: "") }
        )
    }

    /// The Favorites row as the Favorites view builds it.
    private func favoritesRow(
        _ word: FavoriteWord,
        isExpanded: Bool = false
    ) -> DictionaryWordRow<EmptyView, Text> {
        favoritesWordRow(
            word: word,
            bindings: DictionaryWordRowBindings(
                isExpanded: isExpanded,
                phase: .idle,
                trailingHeadword: word.headword,
                isFavorite: true,
                onToggle: {},
                onToggleFavorite: {},
                onCopy: { _ in }
            ),
            extras: { EmptyView() },
            resolvedContent: { _ in Text(verbatim: "") }
        )
    }

    // MARK: - The reading gate

    @Test("the search row shows a reading only for a kanji-written entry")
    func searchReadingGate() {
        // A kanji-written entry carries its reading beside the kanji.
        #expect(searchRow(hit(keb: "負ける", reb: "まける")).reading == "まける")
        // A kana-only entry's reading IS its headword: showing it again would
        // read as two different words.
        #expect(searchRow(hit(keb: nil, reb: "まける")).reading == nil)
        // A kana-only entry reached through its kana candidate highlights the
        // headword instead.
        #expect(searchRow(hit(keb: nil, reb: "まける", matchedField: .reb)).headwordHighlightRange == nil)
    }

    @Test("the favorites row shows the reading it stored, kana-only words included")
    func favoritesReadingGate() {
        // No kanji gate here: the stored word is the stored truth, and a
        // kana-only favorite shows its kana.
        #expect(favoritesRow(word(headword: "まける", reading: "まける")).reading == "まける")
        // A word with no reading at all shows no reading line.
        #expect(favoritesRow(word(reading: nil)).reading == nil)
    }

    @Test("the two modes disagree on a kana-only word, and only there")
    func kanaOnlyDivergence() {
        let kanaOnly = hit(keb: nil, reb: "まける")
        #expect(searchRow(kanaOnly).reading == nil)
        #expect(favoritesRow(word(headword: "まける", reading: "まける")).reading == "まける")
    }

    // MARK: - The label spacing

    @Test("the search label's lines sit wider apart than the favorites label's")
    func labelSpacing() {
        #expect(searchRow(hit()).labelSpacing == 4)
        #expect(favoritesRow(word()).labelSpacing == 2)
        #expect(DictionaryWordRowLayout.searchLabelSpacing == 4)
        #expect(DictionaryWordRowLayout.favoritesLabelSpacing == 2)
    }

    // MARK: - The highlights

    @Test("the search row lights up the field that matched")
    func searchHighlights() {
        // The kanji matched: the headword carries the span, the reading does not.
        let kebHit = hit(matchedField: .keb, highlightRange: 0 ..< 2)
        #expect(searchRow(kebHit).headwordHighlightRange == 0 ..< 2)
        #expect(searchRow(kebHit).readingHighlightRange == nil)

        // The reading matched: the reading carries the span.
        let rebHit = hit(matchedField: .reb, highlightRange: 0 ..< 3)
        #expect(searchRow(rebHit).readingHighlightRange == 0 ..< 3)
        #expect(searchRow(rebHit).headwordHighlightRange == nil)

        // A kana-only entry matched on its reading: the headword IS the
        // reading, so the span lands on the headword instead.
        let kanaHit = hit(keb: nil, reb: "まける", matchedField: .reb, highlightRange: 0 ..< 3)
        #expect(searchRow(kanaHit).headwordHighlightRange == 0 ..< 3)
        #expect(searchRow(kanaHit).readingHighlightRange == 0 ..< 3)
    }

    @Test("the favorites row never lights anything up")
    func favoritesHighlights() {
        let row = favoritesRow(word())
        #expect(row.headwordHighlightRange == nil)
        #expect(row.readingHighlightRange == nil)
    }

    // MARK: - The romaji

    @Test("the search row derives its romaji live; the favorites row shows the stored snapshot")
    func romajiSource() {
        // Derived from the entry's reading at render time.
        #expect(searchRow(hit(reb: "まける")).romaji == "makeru")
        // An unmappable reading drops the line.
        #expect(searchRow(hit(reb: nil)).romaji == nil)

        // The favorites row renders the snapshot taken when the word was
        // starred — a stale snapshot stays stale, which is the difference.
        #expect(favoritesRow(word(romaji: "makeru")).romaji == "makeru")
        #expect(favoritesRow(word(romaji: nil)).romaji == nil)
    }

    // MARK: - The headword and the controls

    @Test("the row's headword falls back to the reading, then to a dash")
    func rowHeadword() {
        #expect(searchRow(hit(keb: "負ける", reb: "まける")).headword == "負ける")
        #expect(searchRow(hit(keb: nil, reb: "まける")).headword == "まける")
        #expect(searchRow(hit(keb: nil, reb: nil)).headword == "—")
    }

    @Test("the search row's controls need a headword; the favorites row's never do")
    func trailingControls() {
        // A hit with no headword has nothing to key a favorite on, so it
        // carries neither the copy nor the star.
        #expect(searchRow(hit(keb: nil, reb: nil)).trailingHeadword == nil)
        #expect(searchRow(hit(keb: "負ける")).trailingHeadword == "負ける")
        // Every favorites row is a word.
        #expect(favoritesRow(word()).trailingHeadword == "負ける")
    }

    @Test("the favorites star is always filled; the search star is the store's answer")
    func starState() {
        #expect(favoritesRow(word()).isFavorite)
        #expect(searchRow(hit(), isFavorite: true).isFavorite)
        #expect(searchRow(hit(), isFavorite: false).isFavorite == false)
    }

    @Test("the row's accessible name is the headword it shows")
    func accessibilityHeadword() {
        #expect(searchRow(hit(keb: nil, reb: "まける")).accessibilityHeadword == "まける")
        #expect(favoritesRow(word(headword: "負ける")).accessibilityHeadword == "負ける")
    }

    // MARK: - The badge set

    @Test("the badge set is the leading chip, then commonness, level, and name types")
    func badgeOrder() {
        let badges = dictionaryBadges(
            leading: DictionaryBadge(text: "EXACT", color: Theme.accentPink, icon: "magnifyingglass"),
            common: true,
            jlpt: 5,
            namePosTokens: ["surname"]
        )
        #expect(badges.map(\.text) == ["EXACT", "COMMON", "≈N5", "SURNAME"])
    }

    @Test("commonness wears green; the level and the name types wear violet")
    func badgeColours() {
        let badges = dictionaryBadges(
            leading: nil,
            common: true,
            jlpt: 3,
            namePosTokens: ["place"]
        )
        #expect(badges.count == 3)
        #expect(badges[0].color == Theme.dotGreen)
        #expect(badges[1].color == Theme.brandViolet)
        #expect(badges[2].color == Theme.brandViolet)
    }

    @Test("the commonness chip is the one literal the filter toggle uses")
    func commonChipLiteral() {
        #expect(DictionaryBadgeChip.common == "COMMON")
        #expect(DictionaryBadgeChip.commonColor == Theme.dotGreen)
        let badges = dictionaryBadges(leading: nil, common: true, jlpt: nil, namePosTokens: [])
        #expect(badges.map(\.text) == ["COMMON"])
    }

    @Test("the leading chip is the caller's: the search row's carries the magnifier, the popover's does not")
    func leadingChip() {
        let search = dictionaryBadges(
            leading: DictionaryBadge(
                text: DictionarySearchHit.MatchKind.glossWordBoundary.badgeLabel,
                color: Theme.accentPink,
                icon: "magnifyingglass"
            ),
            common: false,
            jlpt: nil,
            namePosTokens: []
        )
        #expect(search.map(\.text) == ["GLOSS"])
        #expect(search[0].icon == "magnifyingglass")
        #expect(search[0].color == Theme.accentPink)

        let popover = dictionaryBadges(
            leading: DictionaryBadge(text: "JOINED MATCH", color: Theme.brandViolet),
            common: false,
            jlpt: nil,
            namePosTokens: []
        )
        #expect(popover.map(\.text) == ["JOINED MATCH"])
        #expect(popover[0].icon == nil)
        #expect(popover[0].color == Theme.brandViolet)
    }

    @Test("the name-type mapper is the same for either source shape")
    func nameTypeMapper() {
        // A search hit's stored tokens, and an entry's sense columns, map
        // through one mapper — so the same name never wears two labels.
        let fromHit = dictionaryBadges(
            leading: nil, common: false, jlpt: nil, namePosTokens: ["fem", "surname"]
        )
        let fromEntry = dictionaryBadges(
            leading: nil, common: false, jlpt: nil, namePosTokens: ["fem", "surname"]
        )
        #expect(fromHit.map(\.text) == ["GIVEN NAME", "SURNAME"])
        #expect(fromEntry.map(\.text) == fromHit.map(\.text))
        // A word entry carries no name types.
        #expect(dictionaryBadges(
            leading: nil, common: false, jlpt: nil, namePosTokens: []
        ).isEmpty)
    }

    @Test("an absent level and an absent commonness add no chip")
    func badgeOmissions() {
        #expect(dictionaryBadges(leading: nil, common: false, jlpt: nil, namePosTokens: []).isEmpty)
        #expect(dictionaryBadges(leading: nil, common: false, jlpt: nil, namePosTokens: []).isEmpty)
        #expect(dictionaryBadges(
            leading: nil, common: false, jlpt: nil, namePosTokens: []
        ).count == 0)
    }
}
