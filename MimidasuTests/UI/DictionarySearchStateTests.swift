import Foundation
@testable import Mimidasu
import Testing

/// Dictionary mode's search state: the debounce, the immediate re-run a filter
/// change demands, the load-more that widens the window, the generation guard
/// that keeps a superseded keystroke's results off the screen, and the fault the
/// view has to name (a missing dictionary) rather than show as an empty result.
@MainActor
@Suite("DictionarySearchState")
struct DictionarySearchStateTests {
    /// A state over the fixture database, so every landing in this suite is a
    /// real result set rather than a fault. Internal so the split-out pager
    /// file shares it.
    func makeState(
        tokenize: @escaping @Sendable (String) -> [DictionaryToken]? = { _ in nil }
    ) throws -> DictionarySearchStateFixture {
        try DictionarySearchStateFixture(tokenize: tokenize)
    }

    /// A state whose engine answers one prefix with more rows than a single
    /// page of results holds — the only shape in which load-more is reachable.
    private func makePagedState(count: Int) throws -> DictionarySearchStateFixture {
        try DictionarySearchStateFixture(
            extraWords: JMDictFixtureDatabase.bulkWords(
                count: count, readingPrefix: "かん", startingAt: 9_991_000
            )
        )
    }

    /// A state whose 60 entries read exactly `かんそう` and 200 more start with it:
    /// the first search saturates on the exact tier and skips the prefix scan, so
    /// this is the only shape in which load-more has to re-search.
    private func makeSkippedStageState() throws -> DictionarySearchStateFixture {
        try DictionarySearchStateFixture(
            extraWords: JMDictFixtureDatabase.bulkWords(
                reading: "かんそう", exactCount: 60, prefixCount: 200, startingAt: 9_992_000
            )
        )
    }

    /// A state over 120 rows under `かん`, a third of them common — the shape a
    /// `mak` search has, where the prefix tier fills the window while the
    /// common filter holds the answer well short of it.
    private func makeCommonFilteredState() throws -> DictionarySearchStateFixture {
        try DictionarySearchStateFixture(
            extraWords: JMDictFixtureDatabase.bulkWords(
                count: 120, readingPrefix: "かん", startingAt: 9_993_000
            )
        )
    }

    /// A state over `headroom + 1` rows under `かん` — one row past what the
    /// prefix stage's own `prefixFetchHeadroom` keeps. It is the only shape in
    /// which `matchedCount` is a floor with no stage having been skipped, which
    /// is the reported `ま` case: a truncated total read as the whole answer.
    /// Shared with the paging suite's twin, so neither can drift past the name
    /// boundary the other already moved below.
    private func makeHeadroomBoundState() throws -> DictionarySearchStateFixture {
        try DictionarySearchStateFixture(
            extraWords: JMDictFixtureDatabase.headroomBoundWords()
        )
    }

    /// A state whose engine points at a path that is not there, so every search
    /// lands as the missing-database fault.
    private func makeUnavailableState() -> DictionarySearchState {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("mimidasu-search-state-missing-\(UUID().uuidString).sqlite")
        let model = AppModel(
            favorites: isolatedFavorites(),
            dictionarySearch: DictionarySearchEngine(resolveDatabase: { missing })
        )
        return DictionarySearchState(model: model)
    }

    @Test("a whitespace-only field restores the hint")
    func whitespaceRestoresTheHint() async throws {
        let fixture = try makeState()
        let state = fixture.state

        state.query = "食べる"

        #expect(await pollUntil { state.debouncedQuery == "食べる" })
        #expect(await pollUntil { state.outcome.hits.isEmpty == false })
        #expect(state.isSearching == false)
        #expect(state.unavailable == false)

        // A field cleared to whitespace only: the hint comes back, and nothing
        // is published as a result of the old query.
        state.query = "   "

        #expect(await pollUntil { state.debouncedQuery.isEmpty })
        #expect(state.outcome.isEmpty)
        #expect(state.isSearching == false)
    }

    @Test("debounces the query and publishes the ranked rows")
    func debounceAndPublish() async throws {
        let fixture = try makeState()
        let state = fixture.state

        state.query = "たべる"

        #expect(state.outcome.isEmpty)
        #expect(await pollUntil { state.debouncedQuery == "たべる" })
        #expect(await pollUntil { state.outcome.hits.isEmpty == false })
        #expect(state.outcome.hits.map(\.entSeq) == [1_358_280])
        #expect(state.isSearching == false)
    }

    @Test("a filter change re-runs immediately, without the debounce")
    func filterChangeRunsImmediately() async throws {
        let fixture = try makeState()
        let state = fixture.state

        state.query = "あめ"
        #expect(await pollUntil { state.outcome.hits.count == 4 })

        // All → Words keeps both あめ entries and both あめむら entries, and
        // the debounced query is untouched by a filter press.
        state.apply(.setScope(.words))
        #expect(await pollUntil { state.outcome.hits.allSatisfy { hit in !hit.isName } })
        #expect(state.outcome.hits.map(\.entSeq) == [1_153_520, 9_990_030, 9_990_100])
        #expect(state.debouncedQuery == "あめ")
    }

    @Test("writing the same filter again does not supersede the running search")
    func repeatedFilterPressDoesNotSupersede() async throws {
        let fixture = try makeState()
        let state = fixture.state

        state.query = "あめ"
        #expect(await pollUntil { state.outcome.hits.count == 4 })

        // Two presses inside one tick: the second is an equality no-op, so the
        // first press's search lands unsuperseded and no landing is discarded.
        state.apply(.setScope(.words))
        state.apply(.setScope(.words))
        #expect(await pollUntil { state.outcome.hits.allSatisfy { hit in !hit.isName } })
        #expect(state.discardedLandings == 0)
    }

    @Test("a filter press prunes the expansion of a row it removed")
    func filterChangePrunesExpansions() async throws {
        let fixture = try makeState()
        let state = fixture.state

        state.query = "あめ"
        #expect(await pollUntil { state.outcome.hits.count == 4 })
        // One row on the current screen, one that is not: the prune runs on
        // the filter press, against the rows on screen *now*. 飴 is a row of
        // the あめ result; 食べる's key stands for a row that result does not
        // hold.
        let ame = try #require(state.outcome.hits.first { hit in hit.headword == "飴" })
        let ameKey = DictionarySearchState.lookupKey(for: ame)
        let goneKey = "1358280"
        state.lookupState.toggle(
            key: ameKey, candidate: LookupCandidate(text: "飴", reading: "あめ")
        )
        state.lookupState.toggle(
            key: goneKey, candidate: LookupCandidate(text: "食べる", reading: "たべる")
        )
        #expect(state.lookupState.expanded == [goneKey, ameKey])

        state.apply(.setScope(.names))
        // 食べる is gone from the rows; 飴 is still on screen (under All), so
        // its expansion survives this press even though Names will drop it.
        #expect(state.lookupState.expanded == [ameKey])
        #expect(await pollUntil { state.outcome.hits.map(\.entSeq) == [15_668_307] })
        // The Names landing is what drops it: no row of the new result holds
        // 飴, so the expansion cannot outlive the rows that made it.
        #expect(state.lookupState.expanded.isEmpty)
    }

    @Test("switching back prunes against the screen the press left behind")
    func switchingBackPrunesAgain() async throws {
        let fixture = try makeState()
        let state = fixture.state

        state.query = "あめ"
        #expect(await pollUntil { state.outcome.hits.count == 4 })
        state.apply(.setScope(.names))
        #expect(await pollUntil { state.outcome.hits.map(\.entSeq) == [15_668_307] })

        // An expansion the Names screen never held: switching back to All
        // prunes against the Names rows still on screen, so it dies at the
        // press — before the All landing can land at all. (The landing pass
        // cannot be what drops it: for the same query the Names rows are a
        // subset of the All rows, so a way-back landing never prunes.) 飴's
        // entry key is one of the All rows, none of which the Names screen
        // holds.
        state.lookupState.toggle(
            key: "1153520", candidate: LookupCandidate(text: "飴", reading: "あめ")
        )
        state.apply(.setScope(.all))
        #expect(state.lookupState.expanded.isEmpty)
        #expect(await pollUntil { state.outcome.hits.count == 4 })
    }

    @Test("names the missing dictionary instead of showing no matches")
    func missingDictionary() async {
        let state = makeUnavailableState()
        state.query = "食べる"

        #expect(await pollUntil { state.unavailable })
        #expect(state.isSearching == false)
        #expect(state.outcome.isEmpty)

        // A cleared field resets the fault, so the next fault below is the
        // second search's own landing — the banner flag genuinely re-publishes
        // rather than surviving from the first query.
        state.query = "   "
        #expect(await pollUntil { state.unavailable == false })

        state.query = "たべる"
        #expect(await pollUntil { state.unavailable })
        #expect(state.outcome.isEmpty)
    }

    @Test("shows the newest query's rows, never an older one's")
    func newestQueryWins() async throws {
        let fixture = try makeState()
        let state = fixture.state

        // Three queries inside one debounce window: only the last one ever
        // reaches the engine, so the screen cannot show a mix of the three.
        state.query = "あめ"
        state.query = "あめむ"
        state.query = "たべる"

        #expect(await pollUntil { state.debouncedQuery == "たべる" })
        #expect(await pollUntil { state.outcome.hits.isEmpty == false })
        #expect(state.outcome.hits.map(\.entSeq) == [1_358_280])
        #expect(state.isSearching == false)
    }

    @Test("a search started before the close does not land afterwards")
    func landingAfterCloseIsDropped() async throws {
        let fixture = try makeState()
        let state = fixture.state

        state.query = "あめ"
        state.resetForClose()
        // Past the debounce *and* past any in-flight scan: nothing repopulates
        // the screen the user just closed.
        try await Task.sleep(for: DictionarySearchState.searchDebounce * 4)

        #expect(state.debouncedQuery.isEmpty)
        #expect(state.outcome.isEmpty)
        #expect(state.isSearching == false)
    }

    @Test("wipes everything on close, and does not respawn the debounce")
    func resetForCloseWipes() async throws {
        let fixture = try makeState()
        let state = fixture.state

        state.query = "たべる"
        #expect(await pollUntil { state.outcome.hits.isEmpty == false })
        let taberu = try #require(state.outcome.hits.first { hit in hit.headword == "食べる" })
        let taberuKey = DictionarySearchState.lookupKey(for: taberu)
        state.lookupState.toggle(
            key: taberuKey, candidate: LookupCandidate(text: "食べる", reading: "たべる")
        )
        state.stepEntry(taberuKey, to: 3, in: result(entries: 2))
        state.resetForClose()

        #expect(state.query.isEmpty)
        #expect(state.debouncedQuery.isEmpty)
        #expect(state.outcome.isEmpty)
        #expect(state.isSearching == false)
        #expect(state.unavailable == false)
        #expect(state.lookupState.expanded.isEmpty)
        #expect(state.entryIndex(for: taberuKey) == 0)
        // The reset's own `query = ""` write must not leave a pending task that
        // fires 150ms later.
        try await Task.sleep(for: DictionarySearchState.searchDebounce * 3)
        #expect(state.debouncedQuery.isEmpty)
        #expect(state.outcome.isEmpty)
    }

    @Test("a query that fits one page offers nothing to load")
    func nothingToLoadOnASmallResult() async throws {
        let fixture = try makeState()
        let state = fixture.state

        state.query = "たべる"
        #expect(await pollUntil { state.outcome.hits.isEmpty == false })
        #expect(state.canLoadMore == false)

        // A click with nothing behind it is a no-op, not a re-search.
        state.loadMore()
        #expect(state.visibleLimit == DictionarySearchEngine.pageSize)
    }

    @Test("load-more reveals rows the search already holds, without re-running it")
    func loadMoreRevealsWithoutSearching() async throws {
        let fixture = try makePagedState(count: 120)
        let state = fixture.state

        state.query = "かん"
        #expect(await pollUntil { state.outcome.hits.isEmpty == false })
        // Every one of the 120 rows is in the outcome; the window is a slice of
        // them, so the first page costs nothing to hold.
        #expect(state.outcome.hits.count == 120)
        #expect(state.visibleHits.count == DictionarySearchEngine.pageSize)
        #expect(state.canLoadMore)

        state.loadMore()
        // Nothing was searched: the rows were already built, so no page is
        // loading and the control never dims.
        #expect(state.isSearching == false)
        #expect(state.outcome.hits.count == 120)
        #expect(state.visibleLimit == DictionarySearchEngine.pageSize * 2)
        #expect(state.visibleHits.count == DictionarySearchEngine.pageSize * 2)

        // Past the last row the button goes away rather than re-running a search
        // that already saw everything it can see.
        state.loadMore()
        #expect(state.isSearching == false)
        #expect(state.visibleLimit == DictionarySearchEngine.pageSize * 3)
        #expect(state.visibleHits.count == 120)
        #expect(state.canLoadMore == false)
    }

    @Test("load-more re-searches only when a stage was skipped, and appends")
    func loadMoreProbesASkippedStage() async throws {
        let fixture = try makeSkippedStageState()
        let state = fixture.state

        state.query = "かんそう"
        #expect(await pollUntil { state.outcome.saturated })
        // The window of 50 is full of exact rows and the prefix tier was
        // declared invisible, so the outcome holds every exact row and nothing
        // else — and says so, rather than claiming 50 was all there is.
        #expect(state.outcome.hits.count == 60)
        #expect(state.outcome.matchedCount == 60)
        #expect(state.countText == "50 / 60+")
        let firstPage = Array(state.visibleHits)

        // This click is the one that pays: the window now outgrows the rows in
        // hand, so the skipped stage runs.
        state.loadMore()
        #expect(state.isSearching)
        #expect(await pollUntil { state.isSearching == false })
        #expect(state.outcome.saturated == false)
        #expect(state.outcome.hits.count == 260)
        #expect(state.visibleHits.count == DictionarySearchEngine.pageSize * 2)
        // The rows on screen did not move to make room for the stage the
        // narrower window had skipped.
        #expect(Array(state.visibleHits.prefix(firstPage.count)) == firstPage)
        #expect(state.countText == "100 / 260")
    }

    @Test("a complete answer says so, with no `+`")
    func completeAnswerHasNoSaturationMark() async throws {
        let fixture = try makePagedState(count: 120)
        let state = fixture.state

        state.query = "かん"
        #expect(await pollUntil { state.outcome.hits.isEmpty == false })
        #expect(state.countText == "50 / 120")

        state.loadMore()
        #expect(state.countText == "100 / 120")
    }

    @Test("a truncated total is marked, and paging it never re-runs the search")
    func truncatedTotalIsMarkedAndPagingReveals() async throws {
        let headroom = DictionarySearchEngine.prefixFetchHeadroom
        let fixture = try makeHeadroomBoundState()
        let state = fixture.state

        state.query = "かん"
        #expect(await pollUntil { state.outcome.hits.isEmpty == false })
        #expect(await pollUntil { state.isSearching == false })

        // The header says the total is short of the answer. Without the `+` this
        // reads as `50 / 8000` and `8000` is the entire truth about `ま`, which
        // is 21,532 entries.
        #expect(state.countText == "50 / \(headroom)+")
        // No stage was skipped, so the button is a reveal rather than a probe:
        // a re-search would run the same scan, stop at the same constant, and
        // land on the same rows for full price.
        #expect(state.outcome.saturated == false)
        state.loadMore()
        #expect(state.isSearching == false)
        #expect(state.countText == "100 / \(headroom)+")
    }

    @Test("a new query starts one page deep again")
    func newQueryResetsTheDepth() async throws {
        let fixture = try makePagedState(count: 120)
        let state = fixture.state

        state.query = "かん"
        #expect(await pollUntil { state.outcome.hits.isEmpty == false })
        state.loadMore()
        #expect(state.visibleLimit == DictionarySearchEngine.pageSize * 2)

        state.query = "あめ"
        #expect(await pollUntil { state.debouncedQuery == "あめ" })
        #expect(state.visibleLimit == DictionarySearchEngine.pageSize)
        #expect(await pollUntil { state.outcome.hits.isEmpty == false && state.isSearching == false })
        #expect(state.visibleHits.count <= DictionarySearchEngine.pageSize)
        #expect(state.canLoadMore == false)
    }

    @Test("a filter press starts one page deep again")
    func filterChangeResetsTheDepth() async throws {
        let fixture = try makePagedState(count: 120)
        let state = fixture.state

        state.query = "かん"
        #expect(await pollUntil { state.visibleHits.count == DictionarySearchEngine.pageSize })
        state.loadMore()
        #expect(state.visibleLimit == DictionarySearchEngine.pageSize * 2)

        // The depth belonged to the unfiltered answer: the filtered search
        // starts one page deep, like a new query, instead of running a
        // 100-row scan and showing 100 rows.
        state.apply(.toggleCommonOnly)
        #expect(state.visibleLimit == DictionarySearchEngine.pageSize)
        #expect(await pollUntil { state.outcome.hits.allSatisfy { hit in hit.common } && state.isSearching == false })
        #expect(state.outcome.hits.isEmpty == false)
    }

    @Test("paging stops at the ceiling and says to refine instead")
    func pagingStopsAtTheCeiling() async throws {
        let pageSize = DictionarySearchEngine.pageSize
        let ceiling = DictionarySearchEngine.maxRows
        let fixture = try makePagedState(count: ceiling + pageSize)
        let state = fixture.state

        state.query = "かん"

        #expect(await pollUntil { state.outcome.hits.isEmpty == false })
        // The whole way down is reveals: the search holds every row it can
        // build, so the clicks land without waiting for a landing.
        while state.canLoadMore {
            state.loadMore()
            #expect(state.isSearching == false)
        }
        #expect(state.visibleLimit == ceiling)
        #expect(state.visibleHits.count == ceiling)
        #expect(state.outcome.hits.count == ceiling)
        #expect(state.canLoadMore == false)
        #expect(state.isAtCeiling)
        // The rows past the ceiling are still there, and still counted.
        #expect(state.outcome.matchedCount == ceiling + pageSize)
    }

    @Test("a common-only answer carries no `+` and offers nothing to load")
    func commonOnlyAnswerIsComplete() async throws {
        let fixture = try makeCommonFilteredState()
        let state = fixture.state

        state.apply(.toggleCommonOnly)
        state.query = "kan"
        #expect(await pollUntil { state.outcome.hits.isEmpty == false })
        #expect(await pollUntil { state.isSearching == false })

        // The reported case: `mak` with COMMON on read `36 / 36+` and its
        // load-more re-ran the same search forever. The count is the whole
        // answer now, so the `+` and the button are both gone.
        #expect(state.countText == "42 / 42")
        #expect(state.canLoadMore == false)
    }

    @Test("entering Names clears COMMON")
    func namesScopeDropsCommonOnly() throws {
        let fixture = try makeState()
        let state = fixture.state

        state.apply(.toggleCommonOnly)
        state.apply(.setScope(.names))

        // The filter pair answers zero rows by construction (no JMnedict entry
        // is marked common) and the chip is disabled in that scope, so a state
        // that kept the flag would be stuck behind chrome that cannot clear it.
        #expect(state.filters.commonOnly == false)
        #expect(state.filters.scope == .names)
    }

    @Test("the close resets the depth a query was paged to")
    func resetForCloseResetsTheDepth() async throws {
        let fixture = try makePagedState(count: 120)
        let state = fixture.state

        state.query = "かん"
        #expect(await pollUntil { state.outcome.hits.isEmpty == false })
        state.loadMore()
        #expect(await pollUntil { state.visibleLimit == DictionarySearchEngine.pageSize * 2 })

        state.resetForClose()
        #expect(state.visibleLimit == DictionarySearchEngine.pageSize)
        #expect(state.canLoadMore == false)
        #expect(state.isAtCeiling == false)
    }
}

/// Stand-ins for pager results, where only the `entSeq` identity and the list
/// position matter. File-scope (shared with the split-out pager file) so they
/// grow no type body.
func searchEntry(seq: Int) -> JMDictEntry {
    JMDictEntry(
        entSeq: seq, keb: "語\(seq)", reb: "ご\(seq)", common: false,
        jlpt: nil, hatsuon: nil, accPatts: nil, zoPatts: nil,
        senses: [JMDictSense(pos: nil, glosses: ["gloss"], misc: nil, restrictedKanji: nil, restrictedKana: nil)]
    )
}

func result(entries: Int) -> LookupResult {
    LookupResult(matched: "あめ", entries: (0 ..< entries).map { index in searchEntry(seq: index + 1) })
}
