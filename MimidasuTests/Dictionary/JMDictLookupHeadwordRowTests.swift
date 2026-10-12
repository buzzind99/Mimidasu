import Foundation
@testable import Mimidasu
import Testing

/// Where a lookup's JLPT level and pitch accent come from: the headword row the
/// candidate matched, plus the two enrichments `scripts/jmdict_build.py` applies
/// before it writes a row — the word-level `jlpt_fallback`, and a kanji
/// writing's accent inherited from the reading its furigana names.
///
/// Split out of `JMDictLookupTests` for the lint type-body ceiling; the
/// fixture, and so every row these read, is the same one the parent builds.
extension JMDictLookupTests {
    /// `JMDictLookupTests` mirrors the build's `jlpt_fallback`, so a row with no
    /// level of its own never reaches the database level-less — it wears its
    /// sibling's: ふろしき's reb row carries the kanji row's 2 in the shipped
    /// artifact too, exactly as `omiyageInheritsPitch`'s twin pins for pitch.
    /// So the contract is pinned on 彼処/あそこ instead, where the two rows
    /// genuinely disagree: the kanji writing carries JLPT 1 and か[Dev]し'こ,
    /// the kana one its own 5 and あそ'こ, and the matched row is the only
    /// thing that can choose between them.
    @Test("takes jlpt and pitch verbatim from the matched kana headword row")
    func jlptFromMatchedRow() throws {
        let result = try #require(try engine.lookup(LookupCandidate(text: "あそこ")))

        let entry = try #require(result.entries.first)

        #expect(entry.entSeq == 1_000_320)
        #expect(entry.jlpt == 5, "the kana row's own 5, not the kanji row's 1")
        #expect(entry.hatsuon == "あそ'こ")
        #expect(entry.zoPatts == "LHHH")
    }

    /// The builder's word-level fallback, and the regression the fixture used
    /// to be blind to: 御土産 carries no JLPT upstream, so `jlpt_fallback`
    /// copies the word's first level — 4, off お土産 — onto it. That is what
    /// the shipped database holds, so the lookup answers 4 and never nil.
    @Test("a writing with no level of its own wears the word's first")
    func jlptFallbackMirrorsTheBuilder() throws {
        let result = try #require(try engine.lookup(LookupCandidate(text: "御土産")))

        let entry = try #require(result.entries.first)

        #expect(entry.entSeq == 1_002_500)
        #expect(entry.jlpt == 4)
    }

    /// The pitch half of the same rule: a kanji writing with no accent of its
    /// own wears the accent of the reading its furigana names, which is why the
    /// live twin `omiyageInheritsPitch` reads お土産 as お･みやげ and not null.
    @Test("a kanji row with no accent of its own inherits the reading's")
    func pitchInheritedFromTheNamedReading() throws {
        let result = try #require(try engine.lookup(LookupCandidate(text: "お土産")))

        let entry = try #require(result.entries.first)

        #expect(entry.entSeq == 1_002_500)
        #expect(entry.hatsuon == "お･みやげ")
        #expect(entry.accPatts == "0")
        #expect(entry.zoPatts == "LHHHH")
    }

    /// The state inheritance cannot fill: 風とおし's own accent is empty *and*
    /// the reading its furigana names (かぜとおし) carries none either, so the
    /// matched row really is null — a shape the shipped database does hold.
    @Test("leaves pitch nil when neither the row nor its reading has one")
    func pitchNullWhenRowLacksIt() throws {
        let result = try #require(try engine.lookup(LookupCandidate(text: "風とおし")))

        let entry = try #require(result.entries.first)

        #expect(entry.entSeq == 1_500_010)
        #expect(entry.jlpt == nil)
        #expect(entry.hatsuon == nil)
        #expect(entry.accPatts == nil)
        #expect(entry.zoPatts == nil)
    }
}
