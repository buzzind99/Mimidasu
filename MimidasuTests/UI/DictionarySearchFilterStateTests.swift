import Foundation
@testable import Mimidasu
import Testing

/// The filter panel's chrome state: collapsed by default, cleared on close,
/// and never normalized by scope changes — the JLPT and name-type selections
/// survive a scope excursion because the engine ignores them out-of-domain
/// instead of dropping them. Split from the search-state suite so both types
/// stay inside the body budget.
@MainActor
@Suite("DictionarySearchFilterState")
struct DictionarySearchFilterStateTests {
    private func makeState(
        tokenize: @escaping @Sendable (String) -> [DictionaryToken]? = { _ in nil }
    ) throws -> DictionarySearchStateFixture {
        try DictionarySearchStateFixture(tokenize: tokenize)
    }

    @Test("filters start collapsed")
    func filtersStartCollapsed() throws {
        let fixture = try makeState()

        let expanded = fixture.state.filtersExpanded

        #expect(expanded == false)
    }

    @Test("the close clears the expanded filters")
    func resetForCloseClearsFiltersExpanded() throws {
        let fixture = try makeState()
        fixture.state.filtersExpanded = true

        fixture.state.resetForClose()

        #expect(fixture.state.filtersExpanded == false)
    }

    @Test("scope change keeps the JLPT selection")
    func scopeChangeKeepsJLPT() throws {
        let fixture = try makeState()
        fixture.state.filters = DictionarySearchFilters(jlptLevels: [1, 2])

        fixture.state.filters.scope = .names

        #expect(fixture.state.filters.jlptLevels == [1, 2])
    }

    @Test("scope change keeps the name-type selection")
    func scopeChangeKeepsNameTypes() throws {
        let fixture = try makeState()
        fixture.state.filters = DictionarySearchFilters(nameTypes: ["SURNAME"])

        fixture.state.filters.scope = .words

        #expect(fixture.state.filters.nameTypes == ["SURNAME"])
    }

    @Test("entering Names clears COMMON on scope change")
    func enteringNamesClearsCommonOnScopeChange() throws {
        let fixture = try makeState()
        fixture.state.filters = DictionarySearchFilters(commonOnly: true)

        fixture.state.filters.scope = .names

        #expect(fixture.state.filters.commonOnly == false)
    }

    @Test("entering Names clears COMMON on direct assignment too")
    func enteringNamesClearsCommonOnDirectAssignment() throws {
        // The member-write above and the whole-struct write below funnel
        // through the same `didSet`, but only the second exercises the
        // normalize-then-early-return path — pin both shapes.
        let fixture = try makeState()

        fixture.state.filters = DictionarySearchFilters(scope: .names, commonOnly: true)

        #expect(fixture.state.filters.scope == .names)
        #expect(fixture.state.filters.commonOnly == false)
    }

    @Test("a filter press re-pages to the first page")
    func filterPressResetsVisibleLimit() async throws {
        let fixture = try DictionarySearchStateFixture(extraWords: JMDictFixtureDatabase.bulkWords(
            count: 120, readingPrefix: "かん", startingAt: 9_993_000
        ))
        let state = fixture.state

        state.query = "かん"
        #expect(await pollUntil { state.outcome.hits.count == 120 }, "the paged search lands")
        state.loadMore()
        #expect(state.visibleHits.count == 2 * DictionarySearchEngine.pageSize)

        // Without the reset this press runs a 100-row scan and shows 100
        // rows; with it the filtered answer starts one page deep.
        state.filters = DictionarySearchFilters(commonOnly: true)

        #expect(state.visibleLimit == DictionarySearchEngine.pageSize, "a filter press re-pages")
        #expect(
            await pollUntil { state.outcome.matchedCount == 40 && state.isSearching == false },
            "the filtered search lands its exact total"
        )
        #expect(state.outcome.isFloor == false)
    }
}
