import Foundation
@testable import Mimidasu
import Testing

/// The search's filter predicates over the fixture database: which tiers a
/// match-group selection answers, and how the JLPT and name-type selections
/// narrow the rows. Split from the engine suite so both types stay inside the
/// body budget. Everything here runs offline.
@Suite("DictionarySearchFilters")
final class DictionarySearchFilterTests {
    private let fixture: DictionarySearchFixture

    init() throws {
        fixture = try DictionarySearchFixture()
    }

    @Test("maps each tier to its filter group", arguments: zip(
        [
            DictionarySearchHit.MatchKind.exact, DictionarySearchHit.MatchKind.lemma,
            DictionarySearchHit.MatchKind.prefix, DictionarySearchHit.MatchKind.glossWordBoundary,
            DictionarySearchHit.MatchKind.glossPrefix, DictionarySearchHit.MatchKind.glossSubstring
        ],
        [
            DictionarySearchFilters.MatchGroup.exact, DictionarySearchFilters.MatchGroup.exact,
            DictionarySearchFilters.MatchGroup.prefix, DictionarySearchFilters.MatchGroup.gloss,
            DictionarySearchFilters.MatchGroup.gloss, DictionarySearchFilters.MatchGroup.gloss
        ]
    ))
    func matchGroupMapping(kind: DictionarySearchHit.MatchKind, group: DictionarySearchFilters.MatchGroup) {
        var only = DictionarySearchFilters()
        only.matchGroups = [group]
        var rest = DictionarySearchFilters()
        rest.matchGroups = Set(DictionarySearchFilters.MatchGroup.allCases).subtracting([group])

        #expect(only.admits(matchKind: kind))
        #expect(!rest.admits(matchKind: kind))
    }

    @Test("labels every match group")
    func matchGroupLabels() {
        #expect(DictionarySearchFilters.MatchGroup.allCases.map(\.label) == ["Exact", "Prefix", "Gloss"])
    }

    @Test("an exact-only search keeps the exact tier and drops the prefix tier")
    func exactOnlySearch() throws {
        let outcome = try fixture.outcome("あめ", matchGroups: [.exact])

        #expect(outcome.hits.map(\.entSeq) == [1_153_520, 9_990_030])
        #expect(outcome.hits.allSatisfy { hit in hit.matchKind == .exact })
    }

    @Test("a Latin query with gloss off finds no gloss hits")
    func glossOffLatinQuery() throws {
        let outcome = try fixture.outcome("bridge", matchGroups: [.exact, .prefix])

        #expect(outcome.isEmpty)
    }

    @Test("a JLPT filter keeps the level and drops unlevelled entries")
    func jlptFilterNarrows() throws {
        // あめ unfiltered is two level-5 exact rows plus two unlevelled prefix
        // rows (the common 雨村 word and the 雨村 surname name): the filter
        // keeps the level and drops the rest.
        let outcome = try fixture.outcome("あめ", jlptLevels: [5])

        #expect(outcome.hits.map(\.entSeq) == [1_153_520, 9_990_030])
        #expect(outcome.hits.allSatisfy { hit in hit.jlpt == 5 })
    }

    @Test("a surname filter keeps the surname name and drops words", arguments: zip(
        ["あめむら", "きむら"], [[15_668_307], [15_668_306]]
    ))
    func surnameFilter(query: String, expected: [Int]) throws {
        // あめむら unfiltered pairs the common word with its surname homograph,
        // so the filter's word-drop is observable; きむら pins the other surname.
        let outcome = try fixture.outcome(query, nameTypes: ["SURNAME"])

        #expect(outcome.hits.map(\.entSeq) == expected)
    }
}
