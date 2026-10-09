import Foundation
@testable import Mimidasu
import Testing

/// The Favorites mode's hoisted state: the debounce that turns keystrokes into
/// one query, the mutation handler that has to survive the mode switch (three
/// different controls can remove a word now), and the close-time reset that
/// must not respawn the debounce task it just cancelled.
@MainActor
@Suite("FavoritesWindowState")
struct FavoritesWindowStateTests {
    private static let miru = FavoriteWord(
        headword: "見る", reading: "みる", romaji: "miru", addedAt: 1000
    )
    private static let taberu = FavoriteWord(
        headword: "食べる", reading: "たべる", romaji: "taberu", addedAt: 1001
    )
    private static let oi = FavoriteWord(
        headword: "おい", reading: "おい", romaji: "oi", addedAt: 1002
    )

    /// A model over a private favorites file and a lookup pointed at a database
    /// that is not there — expanding a row is then observable without a fixture,
    /// because `FavoritesLookupState` moves the row to `.loading` synchronously
    /// before the query runs.
    private func makeModel() -> AppModel {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("mimidasu-window-state-missing-\(UUID().uuidString).sqlite")
        return AppModel(
            favorites: isolatedFavorites(),
            jmDictLookup: JMDictLookup(resolveDatabase: { missing })
        )
    }

    private func makeState() -> (FavoritesWindowState, AppModel) {
        let model = makeModel()
        return (FavoritesWindowState(model: model), model)
    }

    @Test("starts on the store's words, with an empty query and a count")
    func startsOnTheStore() {
        let model = makeModel()
        model.favorites.toggle(Self.miru)
        model.favorites.toggle(Self.taberu)
        // The state snapshots the store at init, so a word starred afterwards
        // does not silently rewrite the rows: only `favoritesChanged()` may.
        model.favorites.toggle(Self.oi)

        let state = FavoritesWindowState(model: model)

        // Newest first — the store's own order (`added_at DESC`).
        #expect(state.results.map(\.headword) == ["おい", "食べる", "見る"])
        #expect(state.query.isEmpty)
        #expect(state.debouncedQuery.isEmpty)
        #expect(state.countText() == "3 / \(FavoritesStore.limit)")
        model.favorites.remove(headword: "おい")
        #expect(state.results.count == 3)
    }

    @Test("debounces the query, and trails the rows by the debounce")
    func debouncesQuery() async {
        let (state, model) = makeState()
        model.favorites.toggle(Self.miru)
        model.favorites.toggle(Self.taberu)

        state.favoritesChanged()
        state.query = "見る"

        // Nothing runs yet: the rows still describe the previous query.
        #expect(state.results.count == 2)
        #expect(state.debouncedQuery.isEmpty)
        #expect(await pollUntil { state.debouncedQuery == "見る" })
        #expect(state.results.map(\.headword) == ["見る"])
        #expect(state.countText() == "1 entry")
    }

    @Test("a keystroke inside the window replaces the pending query")
    func pendingQueryReplaced() async {
        let (state, model) = makeState()
        model.favorites.toggle(Self.miru)
        model.favorites.toggle(Self.taberu)

        state.favoritesChanged()
        state.query = "見る"
        #expect(await pollUntil { state.debouncedQuery == "見る" })

        // A keystroke inside the debounce window replaces the pending query
        // rather than queueing a second one.
        state.query = "食べ"
        state.query = "食べる"
        #expect(state.debouncedQuery == "見る")
        #expect(await pollUntil { state.results.map(\.headword) == ["食べる"] })
        #expect(state.debouncedQuery == "食べる")
    }

    @Test("treats a whitespace-only query as no query")
    func whitespaceQueryIsNoQuery() async {
        let (state, model) = makeState()
        model.favorites.toggle(Self.miru)
        model.favorites.toggle(Self.taberu)

        state.favoritesChanged()
        state.query = "   "

        #expect(await pollUntil { state.debouncedQuery == "   " })
        #expect(state.results.count == 2)
        #expect(state.countText() == "2 / \(FavoritesStore.limit)")
    }

    @Test("counts a single filtered row in the singular")
    func countsFilteredRow() async {
        let (state, model) = makeState()
        model.favorites.toggle(Self.miru)
        model.favorites.toggle(Self.taberu)
        model.favorites.toggle(Self.oi)

        state.favoritesChanged()
        state.query = "おい"

        #expect(await pollUntil { state.debouncedQuery == "おい" })
        #expect(state.results.map(\.headword) == ["おい"])
        #expect(state.countText() == "1 entry")
    }

    @Test("recounts the rows after a mutation while a query is live")
    func mutationRecountsRows() async {
        let (state, model) = makeState()
        model.favorites.toggle(Self.miru)
        model.favorites.toggle(Self.taberu)
        model.favorites.toggle(Self.oi)

        state.favoritesChanged()
        state.query = "おい"
        #expect(await pollUntil { state.debouncedQuery == "おい" })

        model.favorites.toggle(FavoriteWord(
            headword: "追い", reading: "おい", romaji: "oi", addedAt: 1003
        ))
        state.favoritesChanged()
        #expect(state.results.map(\.headword) == ["追い", "おい"])
        #expect(state.countText() == "2 entries")
    }

    @Test("prunes the expansion of a word that left the store, and re-runs the query")
    func mutationPrunesExpandedRows() {
        let (state, model) = makeState()
        model.favorites.toggle(Self.miru)
        model.favorites.toggle(Self.taberu)

        state.favoritesChanged()
        state.lookupState.toggle(Self.miru)
        state.lookupState.toggle(Self.taberu)
        #expect(state.lookupState.expanded.count == 2)

        model.favorites.remove(headword: "見る")
        state.favoritesChanged()
        // The removed word's row is collapsed rather than left expanding over a
        // row that is no longer on screen.
        #expect(state.lookupState.expanded == ["食べる"])
        #expect(state.results.map(\.headword) == ["食べる"])
    }

    @Test("keeps the search live across a mutation")
    func mutationKeepsQuery() async {
        let (state, model) = makeState()
        model.favorites.toggle(Self.miru)
        model.favorites.toggle(Self.taberu)

        state.favoritesChanged()
        state.query = "食べ"
        state.lookupState.toggle(Self.taberu)

        model.favorites.remove(headword: "食べる")
        state.favoritesChanged()
        // The debounce has not landed yet, so the rows still describe the
        // *previous* query — which is the unfiltered list.
        #expect(state.results.map(\.headword) == ["見る"])
        #expect(state.lookupState.expanded.isEmpty)
        // Once the pending query lands over the mutated store, the filter runs
        // against what is actually left.
        #expect(await pollUntil { state.debouncedQuery == "食べ" })
        #expect(state.results.isEmpty)
    }

    @Test("wipes the query, the rows, and the expansions on close")
    func resetForCloseWipes() {
        let (state, model) = makeState()
        model.favorites.toggle(Self.miru)
        model.favorites.toggle(Self.taberu)

        state.favoritesChanged()
        state.query = "見る"
        state.lookupState.toggle(Self.miru)
        state.resetForClose()

        #expect(state.query.isEmpty)
        #expect(state.debouncedQuery.isEmpty)
        #expect(state.lookupState.expanded.isEmpty)
        // The rows fall back to the store's full list, not to empty: the next
        // open shows what is starred.
        #expect(state.results.map(\.headword) == ["食べる", "見る"])
        #expect(state.countText() == "2 / \(FavoritesStore.limit)")
    }

    @Test("the close reset does not respawn the debounce it just cancelled")
    func resetDoesNotRespawnTheDebounce() async throws {
        let (state, model) = makeState()
        model.favorites.toggle(Self.miru)
        model.favorites.toggle(Self.taberu)

        state.favoritesChanged()
        state.query = "食べ"
        // Let the debounce land first, so `debouncedQuery` and `query` agree
        // with each other and the reset hits the equality guard.
        #expect(await pollUntil { state.debouncedQuery == "食べ" })

        state.resetForClose()
        // The task the reset would have spawned would fire ~150ms later and
        // write an empty query's rows. Sleeping past the debounce is the only
        // way to see it.
        try await Task.sleep(for: FavoritesWindowState.searchDebounce * 3)
        #expect(state.debouncedQuery.isEmpty)
        #expect(state.results.count == 2)
        #expect(state.lookupState.expanded.isEmpty)
    }

    @Test("a removal while a search is pending still lands")
    func removalWhilePending() async {
        let (state, model) = makeState()
        model.favorites.toggle(Self.miru)
        model.favorites.toggle(Self.taberu)
        model.favorites.toggle(Self.oi)

        state.favoritesChanged()
        state.query = "おい"
        model.favorites.remove(headword: "見る")
        state.favoritesChanged()

        // The removal is not debounced: 見る is gone now, and the pending query
        // has not run yet — 食べる is still on screen although "おい" excludes it.
        #expect(state.results.map(\.headword) == ["おい", "食べる"])

        // The pending query lands over the mutated store.
        #expect(await pollUntil { state.debouncedQuery == "おい" })
        #expect(state.results.map(\.headword) == ["おい"])
    }
}
