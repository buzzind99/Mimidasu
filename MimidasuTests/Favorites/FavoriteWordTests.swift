import Foundation
@testable import Mimidasu
import Testing

/// Pure matching rules for a stored headword: which rendered segments count
/// as favorites. No store and no database — the rules are static precisely so
/// they can be pinned on their own.
@Suite("FavoriteWord")
struct FavoriteWordTests {

    private func segment(
        _ surface: String, lemma: String? = nil, furigana: String? = nil,
        isBound: Bool = false
    ) -> ReadingSegment {
        ReadingSegment(
            surface: surface, romaji: surface, furigana: furigana, lemma: lemma,
            isBound: isBound
        )
    }

    private var keys: Set<String> {
        [FavoriteWord.normalize("見る")]
    }

    private var naiKeys: Set<String> {
        [FavoriteWord.normalize("ない")]
    }

    /// The comparable readings of stored rows, as the store builds them: one
    /// carrying no kana never arrives, since no kana surface could equal it.
    private func readings(_ stored: String?...) -> Set<String> {
        Set(stored.compactMap { candidate in FavoriteWord.readingKey(candidate) })
    }

    @Test("normalize folds halfwidth katakana onto its fullwidth form")
    func normalizeFoldsHalfwidthKana() {
        #expect(FavoriteWord.normalize("ｶﾞ") == "ガ")
    }

    @Test("normalize leaves an already-composed string untouched")
    func normalizeKeepsComposedText() {
        #expect(FavoriteWord.normalize("見る") == "見る")
    }

    @Test("a segment matches on an exact surface hit")
    func matchesSurface() {
        #expect(FavoriteWord.matches(segment("見る"), keys: keys, readings: []))
    }

    @Test("a conjugated surface matches through its lemma")
    func matchesLemma() {
        #expect(FavoriteWord.matches(segment("見た", lemma: "見る"), keys: keys, readings: []))
    }

    @Test("a potential-form lemma unwraps to the starred dictionary form, so 勝つ lights 勝て")
    func matchesUnwrappedPotentialLemma() {
        let starred = Set([FavoriteWord.normalize("勝つ")])

        #expect(FavoriteWord.matches(
            segment("勝て", lemma: "勝てる"), keys: starred, readings: []
        ))
    }

    @Test("a bound potential lemma stays dark for the unwrapped form")
    func ignoresBoundPotentialLemma() {
        let starred = Set([FavoriteWord.normalize("勝つ")])

        #expect(!FavoriteWord.matches(
            segment("勝て", lemma: "勝てる", isBound: true), keys: starred, readings: []
        ))
    }

    @Test("an unwrap that misses the stored form keeps the segment dark")
    func ignoresUnwrappedPotentialLemma() {
        let other = Set([FavoriteWord.normalize("負ける")])

        #expect(!FavoriteWord.matches(
            segment("勝て", lemma: "勝てる"), keys: other, readings: []
        ))
    }

    @Test("a kana-written conjugate matches through its kana lemma against the stored reading")
    func matchesKanaLemmaOfKanjiFavorite() {
        let starred = Set([FavoriteWord.normalize("貰う")])
        let stored = readings("もらう")

        #expect(FavoriteWord.matches(
            segment("もらって", lemma: "もらう"), keys: starred, readings: stored
        ))
    }

    @Test("a bound kana lemma stays dark for the stored reading")
    func ignoresBoundKanaLemma() {
        let starred = Set([FavoriteWord.normalize("貰う")])
        let stored = readings("もらう")

        #expect(!FavoriteWord.matches(
            segment("もらって", lemma: "もらう", isBound: true),
            keys: starred, readings: stored
        ))
    }

    @Test("a kana lemma that misses every stored reading keeps the segment dark")
    func ignoresUnrelatedKanaLemma() {
        let stored = readings("もらう")

        #expect(!FavoriteWord.matches(
            segment("きいて", lemma: "きく"), keys: [], readings: stored
        ))
    }

    @Test("a katakana-written conjugate folds onto the hiragana stored reading")
    func matchesKatakanaLemmaOfKanjiFavorite() {
        let starred = Set([FavoriteWord.normalize("貰う")])
        let stored = readings("もらう")

        #expect(FavoriteWord.matches(
            segment("モラッテ", lemma: "モラウ"), keys: starred, readings: stored
        ))
    }

    @Test("a kana-written potential matches through its unwrapped form against the stored reading")
    func matchesKanaPotentialOfKanjiFavorite() {
        let starred = Set([FavoriteWord.normalize("貰う")])
        let stored = readings("もらう")

        #expect(FavoriteWord.matches(
            segment("もらえる", lemma: "もらえる"), keys: starred, readings: stored
        ))
    }

    @Test("an all-kana lemma lights a kanji surface too, so 貰って lights for a starred 貰う")
    func matchesKanaLemmaUnderKanjiSurface() {
        let starred = Set([FavoriteWord.normalize("貰う")])
        let stored = readings("もらう")

        #expect(FavoriteWord.matches(
            segment("貰って", lemma: "もらう"), keys: starred, readings: stored
        ))
    }

    @Test("a lemma with kanji in it never matches through the stored reading")
    func ignoresKanjiLemmaReading() {
        let stored = readings("貰う")

        #expect(!FavoriteWord.matches(
            segment("貰って", lemma: "貰う"), keys: [], readings: stored
        ))
    }

    @Test("an empty surface and an empty lemma never match, so a malformed empty key stays inert")
    func ignoresEmptyText() {
        let empty = Set([""])

        #expect(!FavoriteWord.matches(segment(""), keys: empty, readings: []))
        #expect(!FavoriteWord.matches(segment("見た", lemma: ""), keys: empty, readings: []))
    }

    @Test("a bound token's lemma never matches, so a ない favorite leaves ねえ and なきゃ dark")
    func ignoresBoundLemma() {
        #expect(!FavoriteWord.matches(
            segment("ねえ", lemma: "ない", isBound: true), keys: naiKeys, readings: []
        ))
        #expect(!FavoriteWord.matches(
            segment("なきゃ", lemma: "ない", isBound: true), keys: naiKeys, readings: []
        ))
    }

    @Test("a bound token still matches on its exact surface, so spoken ない lights")
    func boundSurfaceStillMatches() {
        #expect(FavoriteWord.matches(
            segment("ない", lemma: "ない", isBound: true), keys: naiKeys, readings: []
        ))
    }

    @Test("a kana surface matches a stored reading, so 有難う lights up ありがとう")
    func matchesKanaSurfaceOfKanjiFavorite() {
        let stored = readings("ありがとう")

        #expect(FavoriteWord.matches(
            segment("ありがとう"), keys: [], readings: stored
        ))
    }

    @Test("a kanji surface never matches on the reading, so a おい favorite leaves 置く dark")
    func ignoresKanjiSurfaceReading() {
        let stored = readings("おい")

        #expect(!FavoriteWord.matches(
            segment("置く", lemma: "置く", furigana: "おく"), keys: [], readings: stored
        ))
    }

    @Test("a katakana surface matches a hiragana stored reading")
    func matchesReadingAcrossScripts() {
        let stored = readings("こーひー")

        #expect(FavoriteWord.matches(
            segment("コーヒー"), keys: [], readings: stored
        ))
    }

    @Test("a halfwidth-katakana surface matches a fullwidth stored reading")
    func matchesHalfwidthReading() {
        let stored = readings("こーひー")

        #expect(FavoriteWord.matches(
            segment("ｺｰﾋｰ"), keys: [], readings: stored
        ))
    }

    @Test("a one-kana favorite still lights up its own kana spelling")
    func matchesSingleKanaSpelling() {
        let stored = readings("は")

        #expect(FavoriteWord.matches(segment("は"), keys: [], readings: stored))
    }

    @Test("a reading with no kana in it has no key, so it can never match a surface")
    func readingKeyRejectsNonKana() {
        #expect(FavoriteWord.readingKey("50%") == nil)
    }

    @Test("a reading is kept kana-folded, so katakana compares as hiragana")
    func readingKeyFoldsKatakana() {
        #expect(FavoriteWord.readingKey("コーヒー") == "こーひー")
    }

    @Test("an absent reading has no key")
    func readingKeyRejectsNil() {
        #expect(FavoriteWord.readingKey(nil) == nil)
    }

    @Test("a differently-read kana surface does not match")
    func ignoresDifferentlyReadKanaSurface() {
        let stored = readings("ありがとう")

        #expect(!FavoriteWord.matches(
            segment("あると"), keys: [], readings: stored
        ))
    }

    @Test("a surface that is not kana never reaches the spelling arm at all")
    func ignoresKanjiSurface() {
        let stored = readings("にちようび")

        #expect(!FavoriteWord.matches(
            segment("日曜日", lemma: "日曜日"), keys: [], readings: stored
        ))
    }

    @Test("an unrelated segment does not match")
    func ignoresUnrelatedSegment() {
        #expect(!FavoriteWord.matches(segment("食べる", lemma: "食べる"), keys: keys, readings: []))
    }

    @Test("a halfwidth-katakana surface hits a fullwidth stored key")
    func matchesHalfwidthSurface() {
        let stored = Set([FavoriteWord.normalize("コーヒー")])

        #expect(FavoriteWord.matches(
            segment("ｺｰﾋｰ"), keys: stored, readings: []
        ))
    }

    @Test("identity is the headword, so the list is keyed by word")
    func identityIsHeadword() {
        let word = FavoriteWord(
            headword: "見る", reading: "みる", romaji: "miru", addedAt: 0
        )

        #expect(word.id == "見る")
    }
}
