import Foundation
@testable import Mimidasu
import Testing

/// The ladder over the headwords stored verbatim — the numeric and Latin
/// spellings the romaji converter cannot spell, plus the uppercase probe
/// that reaches them from a lowercased query. Split from the main suite to
/// keep both inside the type-body ceiling; the fixture harness is the same
/// one line for line.
@Suite("DictionarySearchEngine spelling stages")
final class DictionarySearchEngineSpellingTests {
    private let fixture: DictionarySearchFixture

    init() throws {
        fixture = try DictionarySearchFixture()
    }

    private func search(_ query: String) throws -> DictionarySearchOutcome {
        try fixture.outcome(query)
    }

    @Test("a numeric headword answers its own spelling as an exact hit")
    func digitExact() throws {
        let hit = try #require(try search("4649").hits.first)

        #expect(hit.entSeq == 9_990_170)
        #expect(hit.matchKind == .exact)
        #expect(hit.matchedField == .keb)
        #expect(hit.keb == "4649")
        #expect(hit.reb == "よろしく")
        #expect(hit.highlightRange == 0 ..< 4)
        #expect(hit.common)
    }

    @Test("a numeric prefix reaches the headword it starts",
          arguments: zip(["4", "46", "464"], [1, 2, 3]))
    func digitPrefix(query: String, typed: Int) throws {
        let hit = try #require(try search(query).hits.first { candidate in
            candidate.keb == "4649"
        })

        #expect(hit.matchKind == .prefix)
        #expect(hit.matchedField == .keb)
        #expect(hit.highlightRange == 0 ..< typed)
    }

    @Test("a lowercase Latin spelling reaches the uppercase-stored initialism",
          arguments: ["tkg", "TKG"])
    func latinCaseExact(query: String) throws {
        let hit = try #require(try search(query).hits.first)

        #expect(hit.entSeq == 9_990_160)
        #expect(hit.matchKind == .exact)
        #expect(hit.matchedField == .keb)
        #expect(hit.keb == "TKG")
        #expect(hit.highlightRange == 0 ..< 3)
    }

    @Test("a mixed-script query reaches the case-bearing headword its fold names")
    func mixedScriptCaseExact() throws {
        // `ABC順` keeps its case in the BINARY-ordered B-tree, so the
        // whole-string probes a Japanese-script query runs (`abc順` exact,
        // the `abc順`+sentinel prefix range) both miss it — `A` sorts before
        // `a`. This is the Latin branch's `tkg` shape arriving with 順 riding
        // along, rescued on this branch by the same folded spellings. The
        // fixture word rides `extraWords`, not the shared synthetic list, so
        // the other suites' row counts stay untouched.
        let fixture = try DictionarySearchFixture(extraWords: [
            JMDictFixtureDatabase.FixtureWord(
                id: "9990180",
                kanji: [JMDictFixtureDatabase.FixtureKanji(
                    text: "ABC順", common: true, jlptLevel: nil, pitchAccent: nil
                )],
                kana: [JMDictFixtureDatabase.FixtureKana(
                    text: "エービーシーじゅん", common: true, appliesToKanji: ["*"],
                    jlptLevel: nil, pitchAccent: nil
                )],
                sense: [JMDictFixtureDatabase.FixtureSense(
                    partOfSpeech: ["n"], appliesToKanji: nil, appliesToKana: nil,
                    misc: nil,
                    gloss: [JMDictFixtureDatabase.FixtureGloss(
                        lang: "eng", text: "alphabetical order"
                    )]
                )]
            )
        ])

        for query in ["ABC順", "abc順"] {
            let hit = try #require(try fixture.outcome(query).hits.first)

            #expect(hit.entSeq == 9_990_180, "\(query)")
            #expect(hit.matchKind == .exact, "\(query)")
            #expect(hit.matchedField == .keb, "\(query)")
            #expect(hit.keb == "ABC順", "\(query)")
            #expect(hit.highlightRange == 0 ..< 4, "\(query)")
        }
    }
}
