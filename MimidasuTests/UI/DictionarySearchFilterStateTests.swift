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
}
