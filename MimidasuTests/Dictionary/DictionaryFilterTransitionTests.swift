import Foundation
@testable import Mimidasu
import Testing

/// The Filter transition's pure surface: the scope and toggle carry-over
/// rules, the match-group and clear floors, normalization, and a seeded walk
/// over random event sequences. No database and no window — every case is a
/// value assertion on `apply` and `normalized`.
@Suite("DictionaryFilterTransition")
struct DictionaryFilterTransitionTests {

    // MARK: - Toggle carry-over

    @Test("toggling POS under All clears name types and keeps JLPT")
    func togglePOSClearsNameTypesUnderAll() {
        let filters = DictionarySearchFilters(jlptLevels: [5], nameTypes: ["SURNAME"])

        let updated = filters.apply(.togglePOS(.verb))

        #expect(updated.posGroups == [.verb])
        #expect(updated.nameTypes.isEmpty)
        #expect(updated.jlptLevels == [5])
    }

    @Test("toggling POS under Words keeps the name-type selection")
    func togglePOSKeepsNameTypesUnderWords() {
        let filters = DictionarySearchFilters(scope: .words, nameTypes: ["SURNAME"])

        let updated = filters.apply(.togglePOS(.verb))

        #expect(updated.posGroups == [.verb])
        #expect(updated.nameTypes == ["SURNAME"])
    }

    @Test("toggling POS off clears nothing else")
    func togglePOSRemovalClearsNothing() {
        let filters = DictionarySearchFilters(nameTypes: ["SURNAME"], posGroups: [.verb])

        let updated = filters.apply(.togglePOS(.verb))

        #expect(updated.posGroups.isEmpty)
        #expect(updated.nameTypes == ["SURNAME"])
    }

    @Test("toggling a name type under All clears JLPT and POS")
    func toggleNameTypeClearsWordFiltersUnderAll() {
        let filters = DictionarySearchFilters(jlptLevels: [5], posGroups: [.verb])

        let updated = filters.apply(.toggleNameType("SURNAME"))

        #expect(updated.nameTypes == ["SURNAME"])
        #expect(updated.jlptLevels.isEmpty)
        #expect(updated.posGroups.isEmpty)
    }

    @Test("toggling a name type under Words keeps the word selections")
    func toggleNameTypeKeepsWordFiltersUnderWords() {
        let filters = DictionarySearchFilters(scope: .words, jlptLevels: [5], posGroups: [.verb])

        let updated = filters.apply(.toggleNameType("SURNAME"))

        #expect(updated.nameTypes == ["SURNAME"])
        #expect(updated.jlptLevels == [5])
        #expect(updated.posGroups == [.verb])
    }

    @Test("toggling JLPT under All clears name types and keeps POS")
    func toggleJLPTKeepsPOSUnderAll() {
        let filters = DictionarySearchFilters(nameTypes: ["SURNAME"], posGroups: [.verb])

        let updated = filters.apply(.toggleJLPTLevel(5))

        #expect(updated.jlptLevels == [5])
        #expect(updated.nameTypes.isEmpty)
        #expect(updated.posGroups == [.verb])
    }

    @Test("toggling JLPT off clears nothing else")
    func toggleJLPTLevelRemovalClearsNothing() {
        let filters = DictionarySearchFilters(jlptLevels: [5], nameTypes: ["SURNAME"])

        let updated = filters.apply(.toggleJLPTLevel(5))

        #expect(updated.jlptLevels.isEmpty)
        #expect(updated.nameTypes == ["SURNAME"])
    }

    @Test("toggling a name type off clears nothing else")
    func toggleNameTypeRemovalClearsNothing() {
        let filters = DictionarySearchFilters(jlptLevels: [5], nameTypes: ["SURNAME"])

        let updated = filters.apply(.toggleNameType("SURNAME"))

        #expect(updated.nameTypes.isEmpty)
        #expect(updated.jlptLevels == [5])
    }

    // MARK: - Scope carry-over

    @Test("entering All from Words clears name types and keeps POS and JLPT")
    func setScopeFromWordsToAll() {
        let filters = DictionarySearchFilters(
            scope: .words, jlptLevels: [5], nameTypes: ["SURNAME"], posGroups: [.verb]
        )

        let updated = filters.apply(.setScope(.all))

        #expect(updated.scope == .all)
        #expect(updated.nameTypes.isEmpty)
        #expect(updated.jlptLevels == [5])
        #expect(updated.posGroups == [.verb])
    }

    @Test("entering All from Names clears JLPT and POS and keeps name types")
    func setScopeFromNamesToAll() {
        let filters = DictionarySearchFilters(
            scope: .names, jlptLevels: [5], nameTypes: ["SURNAME"], posGroups: [.verb]
        )

        let updated = filters.apply(.setScope(.all))

        #expect(updated.scope == .all)
        #expect(updated.nameTypes == ["SURNAME"])
        #expect(updated.jlptLevels.isEmpty)
        #expect(updated.posGroups.isEmpty)
    }

    @Test("entering All from All clears nothing")
    func setScopeFromAllToAll() {
        let filters = DictionarySearchFilters(nameTypes: ["SURNAME"], posGroups: [.verb])

        let updated = filters.apply(.setScope(.all))

        #expect(updated.nameTypes == ["SURNAME"])
        #expect(updated.posGroups == [.verb])
    }

    @Test("leaving All clears nothing")
    func setScopeLeavingAll() {
        let filters = DictionarySearchFilters(nameTypes: ["SURNAME"], posGroups: [.verb])

        let updated = filters.apply(.setScope(.words))

        #expect(updated.scope == .words)
        #expect(updated.nameTypes == ["SURNAME"])
        #expect(updated.posGroups == [.verb])
    }

    // MARK: - Match groups

    @Test("toggling off the last match group is a no-op")
    func lastMatchGroupStaysActive() {
        let updated = DictionarySearchFilters(matchGroups: [.exact]).apply(.toggleMatchGroup(.exact))

        #expect(updated.matchGroups == [.exact])
    }

    @Test("a raw empty match-group set is preserved, not repaired")
    func rawEmptyMatchGroupsIsPreserved() {
        // The event is deliberately arbitrary — anything orthogonal works; an
        // interacting one like `.selectAllMatchGroups` would overwrite the
        // set. The funnel must return raw values untouched.
        let updated = DictionarySearchFilters(matchGroups: []).apply(.clearJLPTLevels)

        #expect(updated.matchGroups.isEmpty)
    }

    @Test("selecting all match groups restores every tier")
    func selectAllMatchGroupsRestoresEveryTier() {
        let updated = DictionarySearchFilters(matchGroups: [.prefix]).apply(.selectAllMatchGroups)

        #expect(updated.matchGroups == Set(DictionarySearchFilters.MatchGroup.allCases))
    }

    @Test("a two-group match selection can drop to one")
    func twoGroupMatchSelectionDropsToOne() {
        let filters = DictionarySearchFilters(matchGroups: [.exact, .gloss])

        let updated = filters.apply(.toggleMatchGroup(.gloss))

        #expect(updated.matchGroups == [.exact])
    }

    // MARK: - Clear events

    @Test("clearing JLPT keeps name types")
    func clearJLPTLevelsKeepsNameTypes() {
        let filters = DictionarySearchFilters(jlptLevels: [1, 2], nameTypes: ["SURNAME"])

        let updated = filters.apply(.clearJLPTLevels)

        #expect(updated.jlptLevels.isEmpty)
        #expect(updated.nameTypes == ["SURNAME"])
    }

    @Test("clearing name types keeps JLPT")
    func clearNameTypesKeepsJLPT() {
        let filters = DictionarySearchFilters(jlptLevels: [5], nameTypes: ["SURNAME"])

        let updated = filters.apply(.clearNameTypes)

        #expect(updated.nameTypes.isEmpty)
        #expect(updated.jlptLevels == [5])
    }

    @Test("clearing POS keeps name types")
    func clearPOSKeepsNameTypes() {
        let filters = DictionarySearchFilters(nameTypes: ["SURNAME"], posGroups: [.verb])

        let updated = filters.apply(.clearPOS)

        #expect(updated.posGroups.isEmpty)
        #expect(updated.nameTypes == ["SURNAME"])
    }

    // MARK: - Reset, COMMON, normalization

    @Test("reset returns the defaults")
    func resetReturnsTheDefaults() {
        let messy = DictionarySearchFilters(
            scope: .names, commonOnly: true, matchGroups: [.exact],
            jlptLevels: [5], nameTypes: ["SURNAME"], posGroups: [.verb]
        )

        let updated = messy.apply(.reset)

        #expect(updated == DictionarySearchFilters())
    }

    @Test("toggling COMMON under Names is a net no-op")
    func toggleCommonUnderNamesIsNoOp() {
        let names = DictionarySearchFilters(scope: .names)

        #expect(names.apply(.toggleCommonOnly) == names)
    }

    @Test("toggling COMMON sets it under All and clears it again")
    func toggleCommonFlipsUnderAll() {
        let on = DictionarySearchFilters().apply(.toggleCommonOnly)

        #expect(on == DictionarySearchFilters(commonOnly: true))

        let off = on.apply(.toggleCommonOnly)

        #expect(off == DictionarySearchFilters())
    }

    @Test("toggling COMMON cannot park it under Names")
    func toggleCommonCannotParkUnderNames() {
        let parked = DictionarySearchFilters(scope: .names, commonOnly: true)

        let updated = parked.apply(.toggleCommonOnly)

        #expect(updated.scope == .names)
        #expect(updated.commonOnly == false)
    }

    @Test("COMMON cleared entering Names stays cleared back under All")
    func commonStaysClearedReturningToAll() {
        let back = DictionarySearchFilters()
            .apply(.toggleCommonOnly)
            .apply(.setScope(.names))
            .apply(.setScope(.all))

        #expect(back.scope == .all)
        #expect(back.commonOnly == false)
    }

    @Test("a raw two-sided All selection survives an unrelated scope event")
    func rawTwoSidedAllSelectionIsPreserved() {
        let raw = DictionarySearchFilters(jlptLevels: [5], nameTypes: ["SURNAME"])

        let updated = raw.apply(.setScope(.all))

        #expect(updated.jlptLevels == [5])
        #expect(updated.nameTypes == ["SURNAME"])
    }

    @Test("entering Names normalizes COMMON away")
    func setScopeNamesNormalizesCommonAway() {
        let updated = DictionarySearchFilters(commonOnly: true).apply(.setScope(.names))

        #expect(updated.scope == .names)
        #expect(updated.commonOnly == false)
    }

    @Test("normalized clears COMMON under Names")
    func normalizedClearsCommonUnderNames() {
        let normalized = DictionarySearchFilters(scope: .names, commonOnly: true).normalized

        #expect(normalized.commonOnly == false)
        #expect(normalized.scope == .names)
    }

    @Test("normalized is idempotent")
    func normalizedIsIdempotent() {
        let once = DictionarySearchFilters(scope: .names, commonOnly: true).normalized

        #expect(once.normalized == once)
    }

    // MARK: - Scope capability table

    @Test("scope capability: JLPT", arguments: zip(
        [DictionarySearchFilters.Scope.all, .words, .names],
        [true, true, false]
    ))
    func scopeAnswersJLPT(scope: DictionarySearchFilters.Scope, expected: Bool) {
        #expect(scope.answersJLPT == expected)
    }

    @Test("scope capability: name types", arguments: zip(
        [DictionarySearchFilters.Scope.all, .words, .names],
        [true, false, true]
    ))
    func scopeAnswersNameTypes(scope: DictionarySearchFilters.Scope, expected: Bool) {
        #expect(scope.answersNameTypes == expected)
    }

    @Test("scope capability: POS", arguments: zip(
        [DictionarySearchFilters.Scope.all, .words, .names],
        [true, true, false]
    ))
    func scopeAnswersPOS(scope: DictionarySearchFilters.Scope, expected: Bool) {
        #expect(scope.answersPOS == expected)
    }

    @Test("scope capability: COMMON", arguments: zip(
        [DictionarySearchFilters.Scope.all, .words, .names],
        [true, true, false]
    ))
    func scopeAnswersCommon(scope: DictionarySearchFilters.Scope, expected: Bool) {
        #expect(scope.answersCommon == expected)
    }

    // MARK: - Seeded sequences

    @Test("event sequences never reach an impossible filter state")
    func eventSequencesNeverReachImpossibleState() {
        let seeds: [UInt64] = [0x5EED_0001, 0x5EED_0002, 0x0BAD_F00D]

        for seed in seeds {
            var generator = SplitMix64(state: seed)
            var filters = DictionarySearchFilters()

            for step in 1 ... 200 {
                filters = filters.apply(randomEvent(using: &generator))

                #expect(
                    !(filters.scope == .names && filters.commonOnly),
                    "seed \(seed) step \(step): COMMON under Names"
                )
                #expect(
                    filters.scope != .all || filters.nameTypes.isEmpty
                        || (filters.jlptLevels.isEmpty && filters.posGroups.isEmpty),
                    "seed \(seed) step \(step): name types under All with word-side selections"
                )
                #expect(
                    !filters.matchGroups.isEmpty,
                    "seed \(seed) step \(step): match groups emptied"
                )
            }
        }
    }

    @Test("kept-but-ignored selections survive scope excursions")
    func keptButIgnoredSelectionsSurviveExcursions() {
        let wordExcursion = DictionarySearchFilters()
            .apply(.toggleJLPTLevel(5))
            .apply(.togglePOS(.verb))
            .apply(.setScope(.names))
            .apply(.setScope(.words))
            .apply(.setScope(.all))

        #expect(wordExcursion.jlptLevels == [5])
        #expect(wordExcursion.posGroups == [.verb])

        let nameExcursion = DictionarySearchFilters()
            .apply(.toggleJLPTLevel(5))
            .apply(.setScope(.names))
            .apply(.toggleNameType("SURNAME"))
            .apply(.setScope(.words))
            .apply(.setScope(.names))

        #expect(nameExcursion.nameTypes == ["SURNAME"])
        #expect(nameExcursion.jlptLevels == [5])
    }
}

/// Deterministic splitmix64 so the sequence walk is a fixed, reproducible
/// sample rather than a fresh draw every run.
private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// One uniform draw across every `FilterEvent` case, so a walk reaches the
/// whole transition surface: scope moves, every toggle family, every clear,
/// the match-group restore, the common toggle, and reset. Split in two so both
/// dispatches stay inside the size budget — the branches still cover all
/// eleven events, five selection draws plus the six value draws.
private func randomEvent(using generator: inout SplitMix64) -> DictionarySearchFilters.FilterEvent {
    switch Int.random(in: 0 ..< 11, using: &generator) {
    case 0:
        .setScope(randomElement(DictionarySearchFilters.Scope.allCases, using: &generator))
    case 1:
        .toggleJLPTLevel(Int.random(in: 1 ... 5, using: &generator))
    case 2:
        .toggleNameType(randomNameTypeBadge(using: &generator))
    case 3:
        .togglePOS(randomElement(DictionarySearchFilters.POSGroup.allCases, using: &generator))
    case 4:
        .toggleMatchGroup(randomElement(DictionarySearchFilters.MatchGroup.allCases, using: &generator))
    default:
        randomValueEvent(using: &generator)
    }
}

private func randomValueEvent(using generator: inout SplitMix64) -> DictionarySearchFilters.FilterEvent {
    switch Int.random(in: 0 ..< 6, using: &generator) {
    case 0:
        .clearJLPTLevels
    case 1:
        .clearNameTypes
    case 2:
        .clearPOS
    case 3:
        .selectAllMatchGroups
    case 4:
        .toggleCommonOnly
    default:
        .reset
    }
}

private func randomElement<T>(_ values: [T], using generator: inout SplitMix64) -> T {
    values[Int.random(in: 0 ..< values.count, using: &generator)]
}

private func randomNameTypeBadge(using generator: inout SplitMix64) -> String {
    let badges = DictionaryContent.allNameTypeBadges
    guard !badges.isEmpty else { return "SURNAME" }
    return randomElement(badges, using: &generator)
}
