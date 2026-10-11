import Foundation
@testable import Mimidasu
import Testing

/// Regressions for dictionary-mode search state that outgrew the main suite:
/// a fault that is not a missing database names itself, a filter press answers
/// the debounced query rather than the live field, a successful landing prunes
/// the expansions its rows dropped, a floor total still counts at the ceiling,
/// and the close wipes the query and the filters together without letting the
/// filters resurrect the search. Split from `DictionarySearchStateTests` so
/// neither suite exceeds the type-body budget.
@MainActor
@Suite("DictionarySearchStateFaults")
struct DictionarySearchStateFaultTests {
    private func makeState() throws -> DictionarySearchStateFixture {
        try DictionarySearchStateFixture()
    }

    @Test("a closed-database fault names itself instead of showing no matches")
    func closedDatabaseIsAFault() async {
        let engine = DictionarySearchEngine(resolveDatabase: {
            FileManager.default.temporaryDirectory
                .appendingPathComponent("mimidasu-search-state-closed-\(UUID().uuidString).sqlite")
        })
        engine.close()
        let model = AppModel(
            favorites: isolatedFavorites(), dictionarySearch: engine
        )
        let state = DictionarySearchState(model: model)
        state.query = "食べる"

        #expect(await pollUntil { state.fault == .databaseClosed })
        #expect(state.unavailable == false)
        #expect(state.outcome.isEmpty)
        #expect(state.isSearching == false)

        // A cleared field resets the fault, so the next fault is the next
        // search's own landing.
        state.query = "   "
        #expect(await pollUntil { state.debouncedQuery.isEmpty })
        #expect(state.fault == nil)
    }

    @Test("a filter press re-runs the debounced query, not the cleared field")
    func filterPressUsesDebouncedQuery() async throws {
        let fixture = try makeState()
        let state = fixture.state

        state.query = "あめ"
        #expect(await pollUntil { state.outcome.hits.count == 4 })

        // Clear the field, then press a filter before the debounce lands: the
        // re-run still answers the debounced query, so the rows survive until
        // the debounce itself clears them. Searching the live text instead
        // would empty the outcome here while `debouncedQuery` still reads
        // "あめ" — a "No matches for あめ" flash for a deleted query.
        state.query = ""
        state.filters = DictionarySearchFilters(scope: .words)
        #expect(state.outcome.hits.count == 4)
        #expect(state.debouncedQuery == "あめ")

        // The debounce then clears the field for real.
        #expect(await pollUntil { state.debouncedQuery.isEmpty })
        #expect(state.outcome.isEmpty)
    }

    @Test("the close resets the filters, so a reopen never hides a scope")
    func resetForCloseResetsFilters() throws {
        let fixture = try makeState()
        let state = fixture.state

        state.filters = DictionarySearchFilters(scope: .names)
        state.resetForClose()

        #expect(state.filters == DictionarySearchFilters())
    }

    @Test("the close wipes a live query, and its filters cannot resurrect it")
    func resetForCloseBeatsALiveQuery() async throws {
        let fixture = try makeState()
        let state = fixture.state

        state.query = "あめ"
        #expect(await pollUntil { state.outcome.hits.count == 4 })
        state.filters = DictionarySearchFilters(scope: .names)
        #expect(await pollUntil { state.outcome.hits.map(\.entSeq) == [15_668_307] })

        // Both halves of the hazard at once: a wiped query and a filter reset
        // in the same close. If the filters were restored before the query,
        // their didSet would re-run the search the close just wiped and a
        // reopened window would find rows nobody asked for.
        state.resetForClose()

        #expect(state.query.isEmpty)
        #expect(state.debouncedQuery.isEmpty)
        #expect(state.filters == DictionarySearchFilters())
        #expect(state.outcome.isEmpty)
        #expect(state.isSearching == false)

        // Past the debounce and any scan the Names press left in flight:
        // nothing repopulates the screen the user just closed.
        try await Task.sleep(for: DictionarySearchState.searchDebounce * 4)
        #expect(state.debouncedQuery.isEmpty)
        #expect(state.outcome.isEmpty)
        #expect(state.isSearching == false)
    }

    @Test("a new query's landing prunes the expansions its rows dropped")
    func landingPrunesExpansions() async throws {
        let fixture = try makeState()
        let state = fixture.state

        state.query = "あめ"
        #expect(await pollUntil { state.outcome.hits.count == 4 })
        state.lookupState.toggle(FavoriteWord(
            headword: "飴", reading: "あめ", romaji: "ame", addedAt: 0
        ))
        #expect(state.lookupState.expanded == ["飴"])

        // A new query, no filter press: nothing prunes until the landing,
        // which drops 飴 — its row is not in 食べる's result. Without the
        // landing pass the expansion outlives the rows that made it.
        state.query = "たべる"
        #expect(await pollUntil { state.outcome.hits.map(\.entSeq) == [1_358_280] })
        #expect(state.lookupState.expanded.isEmpty)
    }

    @Test("a saturated ceiling counts its own rows, so hidden rows still read")
    func floorTotalCountsAtTheCeiling() async throws {
        let ceiling = DictionarySearchEngine.maxRows
        let fixture = try DictionarySearchStateFixture(
            extraWords: JMDictFixtureDatabase.bulkWords(
                reading: "かんそう", exactCount: ceiling, prefixCount: 40, startingAt: 9_995_000
            )
        )
        let state = fixture.state

        state.query = "かんそう"
        #expect(await pollUntil { state.outcome.saturated && state.isSearching == false })

        // Every click re-searches (a skipped stage is the only way a deeper
        // window finds anything), so each page waits for its landing.
        while state.canLoadMore {
            state.loadMore()
            #expect(await pollUntil { state.isSearching == false })
        }

        // The exact tier filled the window at every depth, so the outcome is a
        // floor with `matchedCount` landed exactly on the ceiling: the old
        // `matchedCount > visibleLimit` condition alone said "nothing hidden"
        // and the footer vanished over a list whose prefix stage never ran.
        #expect(state.visibleLimit == ceiling)
        #expect(state.visibleHits.count == ceiling)
        #expect(state.outcome.hits.count == ceiling)
        #expect(state.outcome.matchedCount == ceiling)
        #expect(state.outcome.isFloor)
        #expect(state.canLoadMore == false)
        #expect(state.isAtCeiling)
    }
}
