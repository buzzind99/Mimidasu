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
        // The count is the post-filter total, not the unfiltered one: a bug
        // filtering `hits` but leaving `matchedCount` at 4 passes the rows
        // above and fails here.
        #expect(outcome.matchedCount == 2)
        #expect(outcome.isFloor == false)
    }

    @Test("a prefix-only search keeps every entry at the prefix tier")
    func prefixOnlySearch() throws {
        // Unfiltered あめ is two exact rows plus two prefix rows; with exact
        // off every entry falls back to its prefix-tier row instead of
        // vanishing — which is what proves the ladder skipped the stage
        // rather than the predicate merely allowing the tier.
        let outcome = try fixture.outcome("あめ", matchGroups: [.prefix])

        #expect(outcome.matchedCount == 4)
        #expect(outcome.hits.allSatisfy { hit in hit.matchKind == .prefix })
        #expect(outcome.isFloor == false)
    }

    @Test("a gloss-only search still finds the gloss tier")
    func glossOnlySearch() throws {
        let outcome = try fixture.outcome("bridge", matchGroups: [.gloss])
        let glossOnly = DictionarySearchFilters(matchGroups: [.gloss])

        #expect(outcome.hits.contains { hit in
            hit.entSeq == 1_237_410 && hit.matchKind == .glossWordBoundary
        })
        #expect(outcome.hits.allSatisfy { hit in glossOnly.admits(matchKind: hit.matchKind) })
        #expect(outcome.matchedCount == outcome.hits.count)
        #expect(outcome.isFloor == false)
    }

    @Test("an empty match-group set answers nothing and saturates nothing")
    func emptyMatchGroupsYieldsEmpty() throws {
        // Every stage skips, so the answer is empty — and with no pending
        // tier the window cannot be holding a floor open either.
        let outcome = try fixture.outcome("あめ", matchGroups: [])

        #expect(outcome.isEmpty)
        #expect(outcome.matchedCount == 0)
        #expect(outcome.saturated == false)
        #expect(outcome.isFloor == false)
    }

    @Test("a Latin query with gloss off finds no gloss hits")
    func glossOffLatinQuery() throws {
        let outcome = try fixture.outcome("bridge", matchGroups: [.exact, .prefix])

        #expect(outcome.isEmpty)
        #expect(outcome.matchedCount == 0)
        #expect(outcome.isFloor == false)
    }

    @Test("a JLPT filter keeps the level and drops unlevelled entries")
    func jlptFilterNarrows() throws {
        // あめ unfiltered is two level-5 exact rows plus two unlevelled prefix
        // rows (the common 雨村 word and the 雨村 surname name): the filter
        // keeps the level and drops the rest.
        let outcome = try fixture.outcome("あめ", jlptLevels: [5])

        #expect(outcome.hits.map(\.entSeq) == [1_153_520, 9_990_030])
        #expect(outcome.hits.allSatisfy { hit in hit.jlpt == 5 })
        #expect(outcome.matchedCount == 2)
        #expect(outcome.isFloor == false)
    }

    @Test("a surname filter keeps the surname name and drops words", arguments: zip(
        ["あめむら", "きむら"], [[15_668_307], [15_668_306]]
    ))
    func surnameFilter(query: String, expected: [Int]) throws {
        // あめむら unfiltered pairs the common word with its surname homograph,
        // so the filter's word-drop is observable; きむら pins the other surname.
        let outcome = try fixture.outcome(query, nameTypes: ["SURNAME"])

        #expect(outcome.hits.map(\.entSeq) == expected)
        #expect(outcome.matchedCount == expected.count)
        #expect(outcome.isFloor == false)
        #expect(outcome.hits.allSatisfy { hit in hit.isName })
        #expect(outcome.hits.allSatisfy { hit in
            DictionaryContent.nameTypeBadges(posTokens: hit.namePosTokens).contains("SURNAME")
        })
    }

    @Test("the surname filter drops the word homograph")
    func surnameFilterDropsWords() throws {
        let unfiltered = try fixture.outcome("あめむら")

        #expect(unfiltered.hits.map(\.entSeq) == [9_990_100, 15_668_307])
        #expect(unfiltered.matchedCount == 2)

        let filtered = try fixture.outcome("あめむら", nameTypes: ["SURNAME"])

        #expect(filtered.hits.map(\.entSeq) == [15_668_307])
        #expect(filtered.matchedCount == 1)
        #expect(filtered.isFloor == false)
        #expect(filtered.hits.allSatisfy { hit in hit.isName })
    }

    @Test("a multi-badge name intersects on any selected badge")
    func surnameFilterMatchesMultiBadgeNames() throws {
        // 木村 carries place + surname: SURNAME intersects, GIVEN NAME does
        // not, and the badge compare is exact — lowercase never matches.
        #expect(try fixture.outcome("きむら", nameTypes: ["SURNAME"]).hits.map(\.entSeq) == [15_668_306])
        let given = try fixture.outcome("きむら", nameTypes: ["GIVEN NAME"])
        #expect(given.isEmpty)
        #expect(given.matchedCount == 0)
        let lower = try fixture.outcome("きむら", nameTypes: ["surname"])
        #expect(lower.isEmpty)
        #expect(lower.matchedCount == 0)
    }

    @Test("a JLPT selection is ignored under Names")
    func jlptIgnoredUnderNames() throws {
        // The engine gates the level check on scope, so the filtered search
        // is the unfiltered names search — not an empty answer, which is what
        // a scope-blind level check would return for levelless names.
        let unfiltered = try fixture.outcome("あめ", scope: .names)
        let filtered = try fixture.outcome("あめ", scope: .names, jlptLevels: [5])

        #expect(filtered.hits.map(\.entSeq) == unfiltered.hits.map(\.entSeq))
        #expect(filtered.matchedCount == unfiltered.matchedCount)
        #expect(filtered.isFloor == false)
    }

    @Test("a name-type selection is ignored under Words")
    func nameTypesIgnoredUnderWords() throws {
        let unfiltered = try fixture.outcome("あめむら", scope: .words)
        let filtered = try fixture.outcome("あめむら", scope: .words, nameTypes: ["SURNAME"])

        #expect(unfiltered.hits.map(\.entSeq) == [9_990_100])
        #expect(filtered.hits.map(\.entSeq) == unfiltered.hits.map(\.entSeq))
        #expect(filtered.matchedCount == unfiltered.matchedCount)
        #expect(filtered.isFloor == false)
    }

    @Test("names the searches that need an exact total")
    func requiresExactCount() {
        #expect(DictionarySearchFilters().requiresExactCount == false)
        #expect(DictionarySearchFilters(commonOnly: true).requiresExactCount)
        #expect(DictionarySearchFilters(jlptLevels: [5]).requiresExactCount)
        #expect(DictionarySearchFilters(scope: .words, jlptLevels: [5]).requiresExactCount)
        #expect(DictionarySearchFilters(scope: .names, jlptLevels: [5]).requiresExactCount == false)
        #expect(DictionarySearchFilters(nameTypes: ["SURNAME"]).requiresExactCount)
        #expect(DictionarySearchFilters(scope: .names, nameTypes: ["SURNAME"]).requiresExactCount)
        #expect(DictionarySearchFilters(scope: .words, nameTypes: ["SURNAME"]).requiresExactCount == false)
        #expect(DictionarySearchFilters(matchGroups: []).requiresExactCount == false)
    }

    @Test("saturation counts only the entries an enabled tier will render")
    func capSaturationRespectsMatchGroups() {
        // A full window of exact rows saturates against a pending prefix tier
        // — but with `.exact` off those rows are not the window at all: the
        // tiers filter pre-count, so the pending tier finds nothing measured
        // against it and the stage must run. (Lives here rather than beside
        // `capSaturationRespectsScope`: that suite is at its body budget.)
        let rows = (1 ... 60).map { entryID in
            DictionarySearchEngine.CandidateRow(
                entryID: entryID, matchedField: .keb, matchKind: .exact,
                jlpt: nil, matchedLength: 3, highlightRange: 0 ..< 1,
                matchedGloss: nil
            )
        }
        let limit = DictionarySearchEngine.pageSize
        let pending = [DictionarySearchHit.MatchKind.prefix.rawValue]

        #expect(DictionarySearchEngine.capSaturated(
            rows, filters: DictionarySearchFilters(), limit: limit, remaining: pending
        ) == true)
        var prefixOnly = DictionarySearchFilters()
        prefixOnly.matchGroups = [.prefix]
        #expect(DictionarySearchEngine.capSaturated(
            rows, filters: prefixOnly, limit: limit, remaining: pending
        ) == false)
    }

    @Test("the outcome helper defaults to an unfiltered search")
    func outcomeHelperDefaults() throws {
        // Every pre-existing baseline runs through the helper's defaults, so
        // a wrong default would silently empty them all — pin it directly.
        let plain = try fixture.outcome("あめ")
        let explicit = try fixture.outcome(
            "あめ",
            matchGroups: Set(DictionarySearchFilters.MatchGroup.allCases),
            jlptLevels: [], nameTypes: []
        )

        #expect(plain == explicit)
    }
}
