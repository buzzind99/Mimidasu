import Foundation
@testable import Mimidasu
import Testing

/// Pure matching rules for a stored headword: which rendered segments count
/// as favorites. No store and no database — the rules live on `FavoriteIdentity`
/// precisely so they can be pinned on their own.
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
        [FavoriteIdentity.normalize("見る")]
    }

    private var naiKeys: Set<String> {
        [FavoriteIdentity.normalize("ない")]
    }

    /// The comparable readings of stored rows, as the store builds them: one
    /// carrying no kana never arrives, since no kana surface could equal it.
    private func readings(_ stored: String?...) -> Set<String> {
        Set(stored.compactMap { candidate in FavoriteIdentity.readingKey(candidate) })
    }

    @Test("normalize folds halfwidth katakana onto its fullwidth form")
    func normalizeFoldsHalfwidthKana() {
        #expect(FavoriteIdentity.normalize("ｶﾞ") == "ガ")
    }

    @Test("normalize leaves an already-composed string untouched")
    func normalizeKeepsComposedText() {
        #expect(FavoriteIdentity.normalize("見る") == "見る")
    }

    @Test("a segment matches on an exact surface hit")
    func matchesSurface() {
        #expect(FavoriteIdentity(keys: keys).matches(segment("見る")))
    }

    @Test("a conjugated surface matches through its lemma")
    func matchesLemma() {
        #expect(FavoriteIdentity(keys: keys).matches(segment("見た", lemma: "見る")))
    }

    @Test("a potential-form lemma unwraps to the starred dictionary form, so 勝つ lights 勝て")
    func matchesUnwrappedPotentialLemma() {
        let starred = Set([FavoriteIdentity.normalize("勝つ")])

        #expect(FavoriteIdentity(keys: starred).matches(
            segment("勝て", lemma: "勝てる")
        ))
    }

    @Test("a bound potential lemma stays dark for the unwrapped form")
    func ignoresBoundPotentialLemma() {
        let starred = Set([FavoriteIdentity.normalize("勝つ")])

        #expect(!FavoriteIdentity(keys: starred).matches(
            segment("勝て", lemma: "勝てる", isBound: true)
        ))
    }

    @Test("an unwrap that misses the stored form keeps the segment dark")
    func ignoresUnwrappedPotentialLemma() {
        let other = Set([FavoriteIdentity.normalize("負ける")])

        #expect(!FavoriteIdentity(keys: other).matches(
            segment("勝て", lemma: "勝てる")
        ))
    }

    @Test("a kana-written conjugate matches through its kana lemma against the stored reading")
    func matchesKanaLemmaOfKanjiFavorite() {
        let starred = Set([FavoriteIdentity.normalize("貰う")])
        let stored = readings("もらう")

        #expect(FavoriteIdentity(keys: starred, readings: stored).matches(
            segment("もらって", lemma: "もらう")
        ))
    }

    @Test("a bound kana lemma stays dark for the stored reading")
    func ignoresBoundKanaLemma() {
        let starred = Set([FavoriteIdentity.normalize("貰う")])
        let stored = readings("もらう")

        #expect(!FavoriteIdentity(keys: starred, readings: stored).matches(
            segment("もらって", lemma: "もらう", isBound: true)
        ))
    }

    @Test("a kana lemma that misses every stored reading keeps the segment dark")
    func ignoresUnrelatedKanaLemma() {
        let stored = readings("もらう")

        #expect(!FavoriteIdentity(keys: [], readings: stored).matches(
            segment("きいて", lemma: "きく")
        ))
    }

    @Test("a katakana-written conjugate folds onto the hiragana stored reading")
    func matchesKatakanaLemmaOfKanjiFavorite() {
        let starred = Set([FavoriteIdentity.normalize("貰う")])
        let stored = readings("もらう")

        #expect(FavoriteIdentity(keys: starred, readings: stored).matches(
            segment("モラッテ", lemma: "モラウ")
        ))
    }

    @Test("a kana-written potential matches through its unwrapped form against the stored reading")
    func matchesKanaPotentialOfKanjiFavorite() {
        let starred = Set([FavoriteIdentity.normalize("貰う")])
        let stored = readings("もらう")

        #expect(FavoriteIdentity(keys: starred, readings: stored).matches(
            segment("もらえる", lemma: "もらえる")
        ))
    }

    @Test("an all-kana lemma lights a kanji surface too, so 貰って lights for a starred 貰う")
    func matchesKanaLemmaUnderKanjiSurface() {
        let starred = Set([FavoriteIdentity.normalize("貰う")])
        let stored = readings("もらう")

        #expect(FavoriteIdentity(keys: starred, readings: stored).matches(
            segment("貰って", lemma: "もらう")
        ))
    }

    @Test("a lemma with kanji in it never matches through the stored reading")
    func ignoresKanjiLemmaReading() {
        let stored = readings("貰う")

        #expect(!FavoriteIdentity(keys: [], readings: stored).matches(
            segment("貰って", lemma: "貰う")
        ))
    }

    @Test("an empty surface and an empty lemma never match, so a malformed empty key stays inert")
    func ignoresEmptyText() {
        let empty = Set([""])

        #expect(!FavoriteIdentity(keys: empty).matches(segment("")))
        #expect(!FavoriteIdentity(keys: empty).matches(segment("見た", lemma: "")))
    }

    @Test("a bound token's lemma never matches, so a ない favorite leaves ねえ and なきゃ dark")
    func ignoresBoundLemma() {
        #expect(!FavoriteIdentity(keys: naiKeys).matches(
            segment("ねえ", lemma: "ない", isBound: true)
        ))
        #expect(!FavoriteIdentity(keys: naiKeys).matches(
            segment("なきゃ", lemma: "ない", isBound: true)
        ))
    }

    @Test("a bound token still matches on its exact surface, so spoken ない lights")
    func boundSurfaceStillMatches() {
        #expect(FavoriteIdentity(keys: naiKeys).matches(
            segment("ない", lemma: "ない", isBound: true)
        ))
    }

    @Test("a kana surface matches a stored reading, so 有難う lights up ありがとう")
    func matchesKanaSurfaceOfKanjiFavorite() {
        let stored = readings("ありがとう")

        #expect(FavoriteIdentity(keys: [], readings: stored).matches(
            segment("ありがとう")
        ))
    }

    @Test("a kanji surface never matches on the reading, so a おい favorite leaves 置く dark")
    func ignoresKanjiSurfaceReading() {
        let stored = readings("おい")

        #expect(!FavoriteIdentity(keys: [], readings: stored).matches(
            segment("置く", lemma: "置く", furigana: "おく")
        ))
    }

    @Test("a katakana surface matches a hiragana stored reading")
    func matchesReadingAcrossScripts() {
        let stored = readings("こーひー")

        #expect(FavoriteIdentity(keys: [], readings: stored).matches(
            segment("コーヒー")
        ))
    }

    @Test("a halfwidth-katakana surface matches a fullwidth stored reading")
    func matchesHalfwidthReading() {
        let stored = readings("こーひー")

        #expect(FavoriteIdentity(keys: [], readings: stored).matches(
            segment("ｺｰﾋｰ")
        ))
    }

    @Test("a one-kana favorite still lights up its own kana spelling")
    func matchesSingleKanaSpelling() {
        let stored = readings("は")

        #expect(FavoriteIdentity(keys: [], readings: stored).matches(segment("は")))
    }

    @Test("a reading with no kana in it has no key, so it can never match a surface")
    func readingKeyRejectsNonKana() {
        #expect(FavoriteIdentity.readingKey("50%") == nil)
    }

    @Test("a reading is kept kana-folded, so katakana compares as hiragana")
    func readingKeyFoldsKatakana() {
        #expect(FavoriteIdentity.readingKey("コーヒー") == "こーひー")
    }

    @Test("an absent reading has no key")
    func readingKeyRejectsNil() {
        #expect(FavoriteIdentity.readingKey(nil) == nil)
    }

    @Test("a differently-read kana surface does not match")
    func ignoresDifferentlyReadKanaSurface() {
        let stored = readings("ありがとう")

        #expect(!FavoriteIdentity(keys: [], readings: stored).matches(
            segment("あると")
        ))
    }

    @Test("a surface that is not kana never reaches the spelling arm at all")
    func ignoresKanjiSurface() {
        let stored = readings("にちようび")

        #expect(!FavoriteIdentity(keys: [], readings: stored).matches(
            segment("日曜日", lemma: "日曜日")
        ))
    }

    @Test("an unrelated segment does not match")
    func ignoresUnrelatedSegment() {
        #expect(!FavoriteIdentity(keys: keys).matches(segment("食べる", lemma: "食べる")))
    }

    @Test("a halfwidth-katakana surface hits a fullwidth stored key")
    func matchesHalfwidthSurface() {
        let stored = Set([FavoriteIdentity.normalize("コーヒー")])

        #expect(FavoriteIdentity(keys: stored).matches(
            segment("ｺｰﾋｰ")
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
