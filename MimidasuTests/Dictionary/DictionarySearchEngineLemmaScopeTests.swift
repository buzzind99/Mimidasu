import Foundation
@testable import Mimidasu
import Testing

/// The lemma tier's scope: exact-only probes over words. A lemma hit means a
/// headword of the entry *is* the query's dictionary form — a stem probe
/// sprays no LEMMA over the compounds it extends, and no probe lemmatizes a
/// name, which has no dictionary form to be.
/// Split from the lemma suites to respect the type-body budget. Everything
/// here runs offline with an injected tokenizer.
@Suite("DictionarySearchEngine lemma scope")
final class DictionarySearchEngineLemmaScopeTests {
    /// A 食べ汚す-shaped compound the lemma probe merely extends, plus a
    /// name whose reading the probe spells out exactly.
    private static func sprayPopulation() -> [JMDictFixtureDatabase.FixtureWord] {
        [
            JMDictFixtureDatabase.FixtureWord(
                id: "9990184",
                kanji: [JMDictFixtureDatabase.FixtureKanji(
                    text: "食べ汚す", common: false, jlptLevel: nil, pitchAccent: nil
                )],
                kana: [JMDictFixtureDatabase.FixtureKana(
                    text: "たべよごす", common: false, appliesToKanji: ["*"],
                    jlptLevel: nil, pitchAccent: nil
                )],
                sense: [JMDictFixtureDatabase.FixtureSense(
                    partOfSpeech: ["v5s"], appliesToKanji: nil, appliesToKana: nil,
                    misc: nil,
                    gloss: [JMDictFixtureDatabase.FixtureGloss(
                        lang: "eng", text: "to eat filthily (fixture)"
                    )]
                )]
            ),
            JMDictFixtureDatabase.FixtureWord(
                id: "15668308",
                kanji: [JMDictFixtureDatabase.FixtureKanji(
                    text: "田部", common: false, jlptLevel: nil, pitchAccent: nil
                )],
                kana: [JMDictFixtureDatabase.FixtureKana(
                    text: "たべ", common: false, appliesToKanji: ["*"],
                    jlptLevel: nil, pitchAccent: nil
                )],
                sense: [JMDictFixtureDatabase.FixtureSense(
                    partOfSpeech: ["surname"], appliesToKanji: nil, appliesToKana: nil,
                    misc: nil,
                    gloss: [JMDictFixtureDatabase.FixtureGloss(
                        lang: "eng", text: "Tabe (fixture surname)"
                    )]
                )]
            )
        ]
    }

    @Test("a stem probe lemmatizes neither the compounds nor the names it touches")
    func stemProbeLemmatizesNothingItMerelyExtends() throws {
        // The `tabemasu` shape: the tokenizer answers a stem (`たべ`), not a
        // dictionary form. The old prefix arm badged every たべ* headword —
        // the 食べる verb, the 食べ汚す compound, the たべ-reading name —
        // LEMMA. Exact-only, the stem matches no word headword and the name
        // row is dropped, so no row may carry the lemma tier at all.
        let fixture = try DictionarySearchFixture(
            tokenize: { text in
                guard text == "たべます" else { return nil }
                return [DictionaryToken(
                    text: text, start: 0, end: 4,
                    reading: text, base: "たべ", pos: "動詞", bound: false
                )]
            },
            extraWords: Self.sprayPopulation()
        )

        let outcome = try fixture.outcome("たべます")

        #expect(outcome.hits.allSatisfy { hit in hit.matchKind != .lemma })
        #expect(!outcome.hits.contains { hit in hit.entSeq == 9_990_184 })
        #expect(!outcome.hits.contains { hit in hit.entSeq == 15_668_308 })

        // Controls: both entries exist and answer honestly — the compound
        // exactly, the name exactly when typed.
        let compound = try fixture.outcome("たべよごす")
        let compoundHit = try #require(compound.hits.first { hit in hit.entSeq == 9_990_184 })
        #expect(compoundHit.matchKind == .exact)
        #expect(compoundHit.keb == "食べ汚す")

        let name = try fixture.outcome("たべ")
        let nameHit = try #require(name.hits.first { hit in hit.entSeq == 15_668_308 })
        #expect(nameHit.isName)
        #expect(nameHit.matchKind == .exact)
    }

    @Test("a dictionary-form probe still lemmatizes beside a longer compound")
    func dictionaryFormProbeLemmatizesDespiteCompounds() throws {
        // Same population, honest base: たべたい → たべる answers 食べる as
        // LEMMA while the 食べ汚す compound stays out of the lemma tier.
        let fixture = try DictionarySearchFixture(
            tokenize: { text in
                guard text == "たべたい" else { return nil }
                return [DictionaryToken(
                    text: text, start: 0, end: 4,
                    reading: text, base: "たべる", pos: "動詞", bound: false
                )]
            },
            extraWords: Self.sprayPopulation()
        )

        let outcome = try fixture.outcome("たべたい")
        let verb = try #require(outcome.hits.first { hit in hit.entSeq == 1_358_280 })

        #expect(verb.matchKind == .lemma)
        #expect(!outcome.hits.contains { hit in hit.entSeq == 9_990_184 })

        let compound = try fixture.outcome("たべよごす")
        #expect(compound.hits.contains { hit in
            hit.entSeq == 9_990_184 && hit.matchKind == .exact
        })
    }
}
