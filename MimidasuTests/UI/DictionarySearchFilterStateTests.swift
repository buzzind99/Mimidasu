import Foundation
@testable import Mimidasu
import Testing

/// The filter panel's chrome state: collapsed by default, cleared on close,
/// and every change flows through `state.apply` — the transition's funnel.
/// Kept-but-ignored selections survive a scope excursion, and Common clears
/// entering Names. Split from the search-state suite so both types stay
/// inside the body budget.
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
        fixture.state.apply(.toggleJLPTLevel(1))
        fixture.state.apply(.toggleJLPTLevel(2))

        fixture.state.apply(.setScope(.names))

        #expect(fixture.state.filters.jlptLevels == [1, 2])
    }

    @Test("scope change keeps the name-type selection")
    func scopeChangeKeepsNameTypes() throws {
        let fixture = try makeState()
        fixture.state.apply(.toggleNameType("SURNAME"))

        fixture.state.apply(.setScope(.words))

        #expect(fixture.state.filters.nameTypes == ["SURNAME"])
    }

    @Test("scope change keeps the POS selection but disables its effect under Names")
    func scopeChangeKeepsPOS() throws {
        let fixture = try makeState()
        fixture.state.apply(.togglePOS(.verb))

        fixture.state.apply(.setScope(.names))

        #expect(fixture.state.filters.posGroups == [.verb])
        #expect(fixture.state.filters.filtersPOS == false)
    }

    @Test("a POS selection filters under Words")
    func posFiltersUnderWords() throws {
        let fixture = try makeState()
        fixture.state.apply(.togglePOS(.noun))
        fixture.state.apply(.setScope(.words))

        #expect(fixture.state.filters.filtersPOS)
    }

    @Test("entering Names clears COMMON on scope change")
    func enteringNamesClearsCommonOnScopeChange() throws {
        let fixture = try makeState()
        fixture.state.apply(.toggleCommonOnly)

        fixture.state.apply(.setScope(.names))

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
        state.apply(.toggleCommonOnly)

        #expect(state.visibleLimit == DictionarySearchEngine.pageSize, "a filter press re-pages")
        #expect(
            await pollUntil { state.outcome.matchedCount == 40 && state.isSearching == false },
            "the filtered search lands its exact total"
        )
        #expect(state.outcome.isFloor == false)
    }
}
