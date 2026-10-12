import Foundation
@testable import Mimidasu
import Testing

/// The lemma retry's gating: prefix-block, mixed-script
/// dual-arm, base-before-unwrap order, and the `requiresExactCount` refusal.
/// Split from `DictionarySearchEngineLemmaTests` to respect the type-body
/// budget. Everything here runs offline with an injected tokenizer.
@Suite("DictionarySearchEngine lemma gating")
final class DictionarySearchEngineLemmaGatingTests {
    private let fixture: DictionarySearchFixture

    init() throws {
        fixture = try DictionarySearchFixture()
    }

    private var databaseURL: URL {
        fixture.url
    }

    @Test("the romaji gate covers its shapes")
    func hasFullyConsumedRomajiShapes() {
        #expect(DictionarySearchEngine.hasFullyConsumedRomaji("tabetai"))
        #expect(!DictionarySearchEngine.hasFullyConsumedRomaji("mak"))
        #expect(!DictionarySearchEngine.hasFullyConsumedRomaji("tabetai,"))
        #expect(!DictionarySearchEngine.hasFullyConsumedRomaji("(tabetai)"))
        #expect(DictionarySearchEngine.hasFullyConsumedRomaji("TABETAI"))
        #expect(DictionarySearchEngine.hasFullyConsumedRomaji("tabetai "))
        #expect(!DictionarySearchEngine.hasFullyConsumedRomaji(""))
        #expect(!DictionarySearchEngine.hasFullyConsumedRomaji("(mak"))
    }

    @Test("the romaji bridge splits base and unwrap")
    func romajiLemmaCandidatesSplitUnwrap() {
        // `tabetai` converts onto たべたい, whose base たべる no headword
        // probe covers — the base survives the probed filter.
        let tabetaiTokenize: @Sendable (String) -> [DictionaryToken]? = { text in
            guard text == "たべたい" else { return nil }
            return [DictionaryToken(
                text: text, start: 0, end: 4,
                reading: text, base: "たべる", pos: "動詞", bound: false
            )]
        }
        let baseOnly = DictionarySearchEngine.romajiLemmaCandidates(
            for: "tabetai", tokenize: tabetaiTokenize, includeUnwrap: false
        )
        #expect(baseOnly.contains { candidate in candidate.text == "たべる" })
        // `tsukureru` converts onto つくれる itself (already probed), so only
        // the unwrap rides the bridge — and only with `includeUnwrap`.
        let tsukureruTokenize: @Sendable (String) -> [DictionaryToken]? = { text in
            guard text == "つくれる" else { return nil }
            return [DictionaryToken(
                text: text, start: 0, end: 4,
                reading: text, base: "つくれる", pos: "動詞", bound: false
            )]
        }
        let combined = DictionarySearchEngine.romajiLemmaCandidates(
            for: "tsukureru", tokenize: tsukureruTokenize
        )
        #expect(combined.contains { candidate in candidate.text == "つくる" })
        let baseStage = DictionarySearchEngine.romajiLemmaCandidates(
            for: "tsukureru", tokenize: tsukureruTokenize, includeUnwrap: false
        )
        #expect(!baseStage.contains { candidate in candidate.text == "つくる" })
    }

    @Test("skips the lemma retry when a prefix hit already answers",
          arguments: ["たべ", "tabe"])
    func lemmaSkippedWhenPrefixHits(query: String) throws {
        // たべ prefix-hits たべる, so the emptiness gate blocks the retry even
        // though the stub would lemmatize. Non-empty by construction: the
        // assertion is about the tier, not about emptiness.
        let sut = DictionarySearchEngine(
            resolveDatabase: { [url = databaseURL] in url },
            tokenize: { text in
                guard text == "たべ" || text == "たべる" else { return nil }
                return [DictionaryToken(
                    text: text, start: 0, end: 2,
                    reading: text, base: "たべる", pos: "動詞", bound: false
                )]
            }
        )
        defer { sut.close() }

        let outcome = try sut.search(query, filters: DictionarySearchFilters())

        #expect(!outcome.hits.isEmpty)
        #expect(outcome.hits.allSatisfy { hit in hit.matchKind != .lemma })
    }

    @Test("punctuated romaji does not lemmatize", arguments: ["tabetai,", "(tabetai)", "\"tabetai,"])
    func punctuatedRomajiDoesNotLemmatize(query: String) throws {
        // No punctuation stripping on the lemma path: a pasted fragment keeps
        // its punctuation, the conversion is not fully consumed, and the retry
        // stays shut.
        let sut = DictionarySearchEngine(
            resolveDatabase: { [url = databaseURL] in url },
            tokenize: { text in
                guard text == "たべたい" else { return nil }
                return [DictionaryToken(
                    text: text, start: 0, end: 4,
                    reading: text, base: "たべる", pos: "動詞", bound: false
                )]
            }
        )
        defer { sut.close() }

        let outcome = try sut.search(query, filters: DictionarySearchFilters())

        #expect(!outcome.hits.contains { candidate in
            candidate.entSeq == 1_358_280 && candidate.matchKind == .lemma
        })
    }

    @Test("runs the romaji arm for mixed-script input")
    func lemmaRunsRomajiArmForMixedScript() throws {
        // `tabetai たべる` contains Japanese, so the Japanese arm reads the
        // whole query (stub: miss) while the romaji arm reads the leading
        // token's kana (stub: base たべる). An exclusive either/or branch
        // would run only the Japanese arm and miss.
        let sut = DictionarySearchEngine(
            resolveDatabase: { [url = databaseURL] in url },
            tokenize: { text in
                guard text == "たべたい" else { return nil }
                return [DictionaryToken(
                    text: text, start: 0, end: 4,
                    reading: text, base: "たべる", pos: "動詞", bound: false
                )]
            }
        )
        defer { sut.close() }

        let outcome = try sut.search("tabetai たべる", filters: DictionarySearchFilters())
        let hit = try #require(outcome.hits.first { candidate in
            candidate.entSeq == 1_358_280
        })

        #expect(hit.matchKind == .lemma)
        #expect(hit.highlightRange == nil)
    }

    @Test("prefers the genuine base over the unwrapped potential")
    func lemmaPrefersBaseOverUnwrap() throws {
        // くれろ's base くれる exists, so the retry answers くれる and never
        // probes the くる unwrap — shape alone cannot tell a potential from
        // a dictionary -える verb. Both entries ride `extraWords`.
        let fixture = try DictionarySearchFixture(
            tokenize: { text in
                guard text == "くれろ" else { return nil }
                return [DictionaryToken(
                    text: text, start: 0, end: 3,
                    reading: text, base: "くれる", pos: "動詞", bound: false
                )]
            },
            extraWords: [
                JMDictFixtureDatabase.FixtureWord(
                    id: "9990181",
                    kanji: [JMDictFixtureDatabase.FixtureKanji(
                        text: "呉れる", common: true, jlptLevel: 5, pitchAccent: nil
                    )],
                    kana: [JMDictFixtureDatabase.FixtureKana(
                        text: "くれる", common: true, appliesToKanji: ["*"],
                        jlptLevel: nil, pitchAccent: nil
                    )],
                    sense: [JMDictFixtureDatabase.FixtureSense(
                        partOfSpeech: ["v1"], appliesToKanji: nil, appliesToKana: nil,
                        misc: nil,
                        gloss: [JMDictFixtureDatabase.FixtureGloss(
                            lang: "eng", text: "to give"
                        )]
                    )]
                ),
                JMDictFixtureDatabase.FixtureWord(
                    id: "9990182",
                    kanji: [JMDictFixtureDatabase.FixtureKanji(
                        text: "来る", common: true, jlptLevel: 5, pitchAccent: nil
                    )],
                    kana: [JMDictFixtureDatabase.FixtureKana(
                        text: "くる", common: true, appliesToKanji: ["*"],
                        jlptLevel: nil, pitchAccent: nil
                    )],
                    sense: [JMDictFixtureDatabase.FixtureSense(
                        partOfSpeech: ["vk"], appliesToKanji: nil, appliesToKana: nil,
                        misc: nil,
                        gloss: [JMDictFixtureDatabase.FixtureGloss(
                            lang: "eng", text: "to come"
                        )]
                    )]
                )
            ]
        )

        let outcome = try fixture.outcome("くれろ")
        #expect(outcome.hits.contains { hit in
            hit.entSeq == 9_990_181 && hit.matchKind == .lemma
        })
        #expect(!outcome.hits.contains { hit in hit.entSeq == 9_990_182 })
    }

    @Test("runs the lemma retry for filtered searches with only filtered-out hits")
    func lemmaRunsWhenRequiresExactCountFiltersHits() throws {
        // `たべたい` rides `extraWords` as an uncommon headword: unfiltered,
        // its exact hit blocks the retry; common-only filters it post-join,
        // and the retry must still lemmatize to たべる.
        let fixture = try DictionarySearchFixture(
            tokenize: { text in
                guard text == "たべたい" else { return nil }
                return [DictionaryToken(
                    text: text, start: 0, end: 4,
                    reading: text, base: "たべる", pos: "動詞", bound: false
                )]
            },
            extraWords: [
                JMDictFixtureDatabase.FixtureWord(
                    id: "9990183",
                    kanji: [],
                    kana: [JMDictFixtureDatabase.FixtureKana(
                        text: "たべたい", common: false, appliesToKanji: nil,
                        jlptLevel: nil, pitchAccent: nil
                    )],
                    sense: [JMDictFixtureDatabase.FixtureSense(
                        partOfSpeech: ["exp"], appliesToKanji: nil, appliesToKana: nil,
                        misc: nil,
                        gloss: [JMDictFixtureDatabase.FixtureGloss(
                            lang: "eng", text: "want to eat (fixture)"
                        )]
                    )]
                )
            ]
        )

        let unfiltered = try fixture.outcome("たべたい")
        #expect(unfiltered.hits.contains { hit in hit.entSeq == 9_990_183 })
        #expect(!unfiltered.hits.contains { hit in
            hit.entSeq == 1_358_280 && hit.matchKind == .lemma
        })

        let filtered = try fixture.outcome("たべたい", commonOnly: true)
        #expect(filtered.hits.contains { hit in
            hit.entSeq == 1_358_280 && hit.matchKind == .lemma
        })
        #expect(!filtered.hits.contains { hit in hit.entSeq == 9_990_183 })
    }

    @Test("prefers the genuine base over the unwrap when filtered")
    func lemmaPrefersBaseOverUnwrapWhenFiltered() throws {
        // Both くれる and くる are common, so a common-only search keeps both
        // post-join rows: the base must still win and the unwrap must be
        // dropped, matching the unfiltered two-stage order.
        let fixture = try DictionarySearchFixture(
            tokenize: { text in
                guard text == "くれろ" else { return nil }
                return [DictionaryToken(
                    text: text, start: 0, end: 3,
                    reading: text, base: "くれる", pos: "動詞", bound: false
                )]
            },
            extraWords: [
                JMDictFixtureDatabase.FixtureWord(
                    id: "9990181",
                    kanji: [JMDictFixtureDatabase.FixtureKanji(
                        text: "呉れる", common: true, jlptLevel: 5, pitchAccent: nil
                    )],
                    kana: [JMDictFixtureDatabase.FixtureKana(
                        text: "くれる", common: true, appliesToKanji: ["*"],
                        jlptLevel: nil, pitchAccent: nil
                    )],
                    sense: [JMDictFixtureDatabase.FixtureSense(
                        partOfSpeech: ["v1"], appliesToKanji: nil, appliesToKana: nil,
                        misc: nil,
                        gloss: [JMDictFixtureDatabase.FixtureGloss(
                            lang: "eng", text: "to give"
                        )]
                    )]
                ),
                JMDictFixtureDatabase.FixtureWord(
                    id: "9990182",
                    kanji: [JMDictFixtureDatabase.FixtureKanji(
                        text: "来る", common: true, jlptLevel: 5, pitchAccent: nil
                    )],
                    kana: [JMDictFixtureDatabase.FixtureKana(
                        text: "くる", common: true, appliesToKanji: ["*"],
                        jlptLevel: nil, pitchAccent: nil
                    )],
                    sense: [JMDictFixtureDatabase.FixtureSense(
                        partOfSpeech: ["vk"], appliesToKanji: nil, appliesToKana: nil,
                        misc: nil,
                        gloss: [JMDictFixtureDatabase.FixtureGloss(
                            lang: "eng", text: "to come"
                        )]
                    )]
                )
            ]
        )

        let filtered = try fixture.outcome("くれろ", commonOnly: true)
        #expect(filtered.hits.contains { hit in
            hit.entSeq == 9_990_181 && hit.matchKind == .lemma
        })
        #expect(!filtered.hits.contains { hit in hit.entSeq == 9_990_182 })
    }
}
