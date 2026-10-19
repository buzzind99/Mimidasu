import Foundation
@testable import Mimidasu
import Testing

/// The POS filter's second suite: tag-mapping boundaries, token splitting,
/// multi-select union, and coexistence with the other filters. Split from
/// `DictionarySearchFilterTests` so both types stay inside the body budget.
/// Everything here runs offline.
@Suite("DictionarySearchPOSFilters")
struct DictionarySearchPOSFilterTests {
    @Test("maps the closed vocabularies and verb/adjective families", arguments: zip(
        ["aux-adj", "adv", "aux", "pref", "suf", "n-pref", "n-suf", "num",
         "vi", "vt", "vs", "v1", "adj-na", "adj-no"],
        [
            DictionarySearchFilters.POSGroup.adjective, .adverb, .auxiliary, .affix, .affix,
            .noun, .noun, .noun, .verb, .verb, .verb, .verb, .adjective, .adjective
        ]
    ))
    func posGroupMappingBoundary(tag: String, group: DictionarySearchFilters.POSGroup) {
        // `aux-adj` is the load-bearing exact entry the `adj` prefix cannot
        // cover; `vi`/`vt`/`vs` pin the transitivity markers the `v` prefix
        // absorbs; the rest pin each closed-vocabulary member.
        #expect(DictionarySearchFilters.posGroupsPresent(posTokens: [tag]) == [group])
    }

    @Test("maps no case variant to any POS group", arguments: ["V1", "N", "ADJ-I", "Exp", "PRT"])
    func posGroupMappingRejectsCaseVariants(tag: String) {
        // Upstream tags are lowercase; the match is case-sensitive by design.
        #expect(DictionarySearchFilters.posGroupsPresent(posTokens: [tag]).isEmpty)
    }

    @Test("splits stored columns on commas and skips empties")
    func posGroupsPresentSplitsColumns() {
        #expect(DictionarySearchFilters.posGroupsPresent(posTokens: [""]).isEmpty)
        #expect(DictionarySearchFilters.posGroupsPresent(posTokens: [" "]).isEmpty)
        #expect(DictionarySearchFilters.posGroupsPresent(posTokens: ["n,,vs"]) == [.noun, .verb])
        #expect(DictionarySearchFilters.posGroupsPresent(posTokens: ["n", "v1"]) == [.noun, .verb])
        #expect(DictionarySearchFilters.posGroupsPresent(posTokens: [" v1 , vt "]) == [.verb])
    }

    @Test("admitsPOS unions a multi-select across groups")
    func admitsPOSMultiSelectUnion() {
        var selected = DictionarySearchFilters()
        selected.posGroups = [.verb, .adverb]

        #expect(selected.admitsPOS(tokens: ["adv"]))
        #expect(selected.admitsPOS(tokens: ["v1"]))
        #expect(selected.admitsPOS(tokens: ["n,vs,vt"]))
        #expect(!selected.admitsPOS(tokens: ["n"]))
    }

    @Test("a POS selection filters under Words")
    func posFiltersUnderWords() throws {
        let fixture = try DictionarySearchFixture(extraWords: Self.posHomographs)
        let unfiltered = try fixture.outcome("ぽすも", scope: .words)

        #expect(unfiltered.hits.map(\.entSeq) == [9_990_185, 9_990_186])

        let verbs = try fixture.outcome("ぽすも", scope: .words, posGroups: [.verb])

        #expect(verbs.hits.map(\.entSeq) == [9_990_185])
        #expect(verbs.matchedCount == 1)
        #expect(verbs.isFloor == false)
    }

    @Test("POS coexists with COMMON")
    func posCoexistsWithCommon() throws {
        // あめむら pairs the common 雨村 word (`n`) with its surname
        // homograph: COMMON keeps the word, POS keeps the noun, and the
        // conjunction keeps exactly the word.
        let fixture = try DictionarySearchFixture()
        let commonNoun = try fixture.outcome("あめむら", commonOnly: true, posGroups: [.noun])

        #expect(commonNoun.hits.map(\.entSeq) == [9_990_100])
        #expect(commonNoun.matchedCount == 1)
        #expect(commonNoun.isFloor == false)

        let commonVerb = try fixture.outcome("あめむら", commonOnly: true, posGroups: [.verb])

        #expect(commonVerb.isEmpty)
        #expect(commonVerb.matchedCount == 0)
        #expect(commonVerb.isFloor == false)
    }

    @Test("POS coexists with JLPT")
    func posCoexistsWithJLPT() throws {
        // Two level-5 homographs sharing ぽすじ — a verb and a noun — so the
        // conjunction narrows on entries the suite itself owns.
        let fixture = try DictionarySearchFixture(extraWords: Self.jlptPOSHomographs)
        let levelled = try fixture.outcome("ぽすじ", jlptLevels: [5])

        #expect(levelled.hits.map(\.entSeq) == [9_990_187, 9_990_188])
        #expect(levelled.matchedCount == 2)

        let verbs = try fixture.outcome("ぽすじ", jlptLevels: [5], posGroups: [.verb])

        #expect(verbs.hits.map(\.entSeq) == [9_990_187])
        #expect(verbs.matchedCount == 1)
        #expect(verbs.isFloor == false)

        let wrongLevel = try fixture.outcome("ぽすじ", jlptLevels: [4], posGroups: [.verb])

        #expect(wrongLevel.isEmpty)
        #expect(wrongLevel.matchedCount == 0)
        #expect(wrongLevel.isFloor == false)
    }

    @Test("POS coexists with the exact tier")
    func posCoexistsWithMatchGroups() throws {
        let fixture = try DictionarySearchFixture(extraWords: Self.posHomographs)
        let verbs = try fixture.outcome("ぽすも", matchGroups: [.exact], posGroups: [.verb])

        #expect(verbs.hits.map(\.entSeq) == [9_990_185])
        #expect(verbs.matchedCount == 1)
        #expect(verbs.isFloor == false)
    }

    @Test("POS and name types conjoin to nothing under All")
    func posAndNameTypesConjunctionIsEmpty() throws {
        // The transition prevents this pairing; the model still allows raw
        // construction: the word fails the badge check, the name fails POS,
        // and the shared single fetch still answers exactly. Covers the
        // both-effective engine path.
        let fixture = try DictionarySearchFixture()

        let verbs = try fixture.outcome("あめむら", nameTypes: ["SURNAME"], posGroups: [.verb])

        #expect(verbs.isEmpty)
        #expect(verbs.matchedCount == 0)
        #expect(verbs.isFloor == false)

        let nouns = try fixture.outcome("あめむら", nameTypes: ["SURNAME"], posGroups: [.noun])

        #expect(nouns.isEmpty)
        #expect(nouns.matchedCount == 0)
        #expect(nouns.isFloor == false)
    }

    /// Two kana-only homographs sharing the reading ぽすも: a verb
    /// (`v1,vt`) and a noun (`n`), so the POS engine tests can pin
    /// narrowing on entries the suite itself owns.
    private static let posHomographs: [JMDictFixtureDatabase.FixtureWord] = [
        JMDictFixtureDatabase.FixtureWord(
            id: "9990185",
            kanji: nil,
            kana: [JMDictFixtureDatabase.FixtureKana(
                text: "ぽすも", common: false, appliesToKanji: nil,
                jlptLevel: nil, pitchAccent: nil
            )],
            sense: [JMDictFixtureDatabase.FixtureSense(
                partOfSpeech: ["v1", "vt"], appliesToKanji: nil, appliesToKana: nil,
                misc: nil,
                gloss: [JMDictFixtureDatabase.FixtureGloss(lang: "eng", text: "to posmo")]
            )]
        ),
        JMDictFixtureDatabase.FixtureWord(
            id: "9990186",
            kanji: nil,
            kana: [JMDictFixtureDatabase.FixtureKana(
                text: "ぽすも", common: false, appliesToKanji: nil,
                jlptLevel: nil, pitchAccent: nil
            )],
            sense: [JMDictFixtureDatabase.FixtureSense(
                partOfSpeech: ["n"], appliesToKanji: nil, appliesToKana: nil,
                misc: nil,
                gloss: [JMDictFixtureDatabase.FixtureGloss(lang: "eng", text: "a posmo")]
            )]
        )
    ]

    /// Two level-5 kana-only homographs sharing the reading ぽすじ: a verb
    /// (`v1,vt`) and a noun (`n`), so the JLPT+POS coexistence test can pin
    /// the conjunction on entries the suite itself owns.
    private static let jlptPOSHomographs: [JMDictFixtureDatabase.FixtureWord] = [
        JMDictFixtureDatabase.FixtureWord(
            id: "9990187",
            kanji: nil,
            kana: [JMDictFixtureDatabase.FixtureKana(
                text: "ぽすじ", common: false, appliesToKanji: nil,
                jlptLevel: 5, pitchAccent: nil
            )],
            sense: [JMDictFixtureDatabase.FixtureSense(
                partOfSpeech: ["v1", "vt"], appliesToKanji: nil, appliesToKana: nil,
                misc: nil,
                gloss: [JMDictFixtureDatabase.FixtureGloss(lang: "eng", text: "to posji")]
            )]
        ),
        JMDictFixtureDatabase.FixtureWord(
            id: "9990188",
            kanji: nil,
            kana: [JMDictFixtureDatabase.FixtureKana(
                text: "ぽすじ", common: false, appliesToKanji: nil,
                jlptLevel: 5, pitchAccent: nil
            )],
            sense: [JMDictFixtureDatabase.FixtureSense(
                partOfSpeech: ["n"], appliesToKanji: nil, appliesToKana: nil,
                misc: nil,
                gloss: [JMDictFixtureDatabase.FixtureGloss(lang: "eng", text: "a posji")]
            )]
        )
    ]
}
