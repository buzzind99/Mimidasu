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
}
