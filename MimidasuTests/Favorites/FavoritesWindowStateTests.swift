import Foundation
@testable import Mimidasu
import Testing

/// One pending-removal row: the favorites on screen, the query still inside
/// its debounce, the row expanded before the removal, and the two visible
/// lists the removal must produce — immediately, and once the query lands.
struct PendingRemovalCase: Sendable {
    let favorites: [FavoriteWord]
    let query: String
    let expanded: FavoriteWord?
    let removedHeadword: String
    let visibleAfterRemoval: [String]
    let visibleAfterDebounce: [String]
}

private let pendingRemovalCases: [PendingRemovalCase] = [
    PendingRemovalCase(
        favorites: [
            FavoriteWord(headword: "見る", reading: "みる", romaji: "miru", addedAt: 1000),
            FavoriteWord(headword: "食べる", reading: "たべる", romaji: "taberu", addedAt: 1001)
        ],
        query: "食べ",
        expanded: FavoriteWord(
            headword: "食べる", reading: "たべる", romaji: "taberu", addedAt: 1001
        ),
        removedHeadword: "食べる",
        visibleAfterRemoval: ["見る"],
        visibleAfterDebounce: []
    ),
    PendingRemovalCase(
        favorites: [
            FavoriteWord(headword: "見る", reading: "みる", romaji: "miru", addedAt: 1000),
            FavoriteWord(headword: "食べる", reading: "たべる", romaji: "taberu", addedAt: 1001),
            FavoriteWord(headword: "おい", reading: "おい", romaji: "oi", addedAt: 1002)
        ],
        query: "おい",
        expanded: nil,
        removedHeadword: "見る",
        visibleAfterRemoval: ["おい", "食べる"],
        visibleAfterDebounce: ["おい"]
    )
]

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

    /// A lookup pointed at a database file that is not there — expanding a
    /// row is then observable without a fixture, because
    /// `FavoritesLookupState` moves the row to `.loading` synchronously
    /// before the query runs.
    private func makeMissingLookup() -> JMDictLookup {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("mimidasu-window-state-missing-\(UUID().uuidString).sqlite")
        return JMDictLookup(resolveDatabase: { missing })
    }

    /// A model over a private favorites file and the missing-database lookup.
    private func makeModel() -> AppModel {
        AppModel(
            favorites: isolatedFavorites(),
            archive: isolatedArchive(),
            jmDictLookup: makeMissingLookup()
        )
    }

    /// The window state receives the same missing-database lookup the model
    /// holds: the injectable parameter is the fixture seam, and the default
    /// would build a production resolver — reading the developer's real
    /// dictionary from a unit test.
    private func makeState() -> (FavoritesWindowState, AppModel) {
        let lookup = makeMissingLookup()
        let model = AppModel(
            favorites: isolatedFavorites(), archive: isolatedArchive(),
            jmDictLookup: lookup
        )
        return (FavoritesWindowState(model: model, lookup: lookup), model)
    }

    /// A window state over a store that cannot open its file: a regular file
    /// sits where the store's directory belongs, so the first read fails and
    /// the store degrades terminally.
    private func makeDegradedState() -> (FavoritesWindowState, () -> Void) {
        let blocked = FileManager.default.temporaryDirectory
            .appendingPathComponent("mimidasu-favorites-degraded-\(UUID().uuidString)")
        #expect(FileManager.default.createFile(atPath: blocked.path, contents: nil))
        let favorites = FavoritesStore(location: blocked.appendingPathComponent("favorites.sqlite"))
        let lookup = makeMissingLookup()
        let model = AppModel(
            favorites: favorites, archive: isolatedArchive(), jmDictLookup: lookup
        )
        return (
            FavoritesWindowState(model: model, lookup: lookup),
            { try? FileManager.default.removeItem(at: blocked) }
        )
    }

    @Test("starts on the store's words, with an empty query and a count")
    func startsOnTheStore() {
        let model = makeModel()
        model.favorites.add(Self.miru)
        model.favorites.add(Self.taberu)
        // The state snapshots the store at init, so a word starred afterwards
        // does not silently rewrite the rows: only `favoritesChanged()` may.
        model.favorites.add(Self.oi)

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
        model.favorites.add(Self.miru)
        model.favorites.add(Self.taberu)

        state.favoritesChanged()
        state.query = "見る"

        // Nothing runs yet: the rows still describe the previous query.
        #expect(state.results.count == 2)
        #expect(state.debouncedQuery.isEmpty)
        #expect(await pollUntil(timeout: 5) { state.debouncedQuery == "見る" }, "the debounced query lands")
        #expect(state.results.map(\.headword) == ["見る"])
        #expect(state.countText() == "1 entry")
    }

    @Test("a keystroke inside the window replaces the pending query")
    func pendingQueryReplaced() async {
        let (state, model) = makeState()
        model.favorites.add(Self.miru)
        model.favorites.add(Self.taberu)

        state.favoritesChanged()
        state.query = "見る"
        #expect(await pollUntil(timeout: 5) { state.debouncedQuery == "見る" }, "the first query lands")

        // A keystroke inside the debounce window replaces the pending query
        // rather than queueing a second one.
        state.query = "食べ"
        state.query = "食べる"
        #expect(state.debouncedQuery == "見る")
        #expect(await pollUntil(timeout: 5) { state.results.map(\.headword) == ["食べる"] }, "the replacement query lands")
        #expect(state.debouncedQuery == "食べる")
    }

    @Test("treats a whitespace-only query as no query")
    func whitespaceQueryIsNoQuery() async {
        let (state, model) = makeState()
        model.favorites.add(Self.miru)
        model.favorites.add(Self.taberu)

        state.favoritesChanged()
        state.query = "   "

        #expect(await pollUntil(timeout: 5) { state.debouncedQuery == "   " }, "the whitespace query lands without filtering")
        #expect(state.results.count == 2)
        #expect(state.countText() == "2 / \(FavoritesStore.limit)")
    }

    @Test("recounts the rows after a mutation while a query is live")
    func mutationRecountsRows() async {
        let (state, model) = makeState()
        model.favorites.add(Self.miru)
        model.favorites.add(Self.taberu)
        model.favorites.add(Self.oi)

        state.favoritesChanged()
        state.query = "おい"
        #expect(await pollUntil(timeout: 5) { state.debouncedQuery == "おい" }, "the live query lands before the mutation")

        model.favorites.add(FavoriteWord(
            headword: "追い", reading: "おい", romaji: "oi", addedAt: 1003
        ))
        state.favoritesChanged()
        #expect(state.results.map(\.headword) == ["追い", "おい"])
        #expect(state.countText() == "2 entries")
    }

    @Test("prunes the expansion of a word that left the store, and re-runs the query")
    func mutationPrunesExpandedRows() {
        let (state, model) = makeState()
        model.favorites.add(Self.miru)
        model.favorites.add(Self.taberu)

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

    @Test(
        "a removal while a search is pending keeps both visible lists",
        arguments: pendingRemovalCases
    )
    func removalWhilePending(testCase: PendingRemovalCase) async {
        let (state, model) = makeState()
        for word in testCase.favorites {
            model.favorites.add(word)
        }

        state.favoritesChanged()
        state.query = testCase.query
        if let expanded = testCase.expanded {
            state.lookupState.toggle(expanded)
        }

        model.favorites.remove(headword: testCase.removedHeadword)
        state.favoritesChanged()

        // The debounce has not landed yet, so the rows still describe the
        // *previous* query — the unfiltered list minus the removed row.
        #expect(state.results.map(\.headword) == testCase.visibleAfterRemoval)
        #expect(state.lookupState.expanded.isEmpty)
        // Once the pending query lands over the mutated store, the filter runs
        // against what is actually left.
        #expect(
            await pollUntil(timeout: 5) { state.debouncedQuery == testCase.query },
            "the pending query lands over the mutated store"
        )
        #expect(state.results.map(\.headword) == testCase.visibleAfterDebounce)
    }

    @Test("wipes the query, the rows, and the expansions on close")
    func resetForCloseWipes() {
        let (state, model) = makeState()
        model.favorites.add(Self.miru)
        model.favorites.add(Self.taberu)

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
        model.favorites.add(Self.miru)
        model.favorites.add(Self.taberu)

        state.favoritesChanged()
        state.query = "食べ"
        // Let the debounce land first, so `debouncedQuery` and `query` agree
        // with each other and the reset hits the equality guard.
        #expect(await pollUntil(timeout: 5) { state.debouncedQuery == "食べ" }, "the debounce lands before the reset")

        state.resetForClose()
        // The task the reset would have spawned would fire ~150ms later and
        // write an empty query's rows. Sleeping past the debounce is the only
        // way to see it: a poll cannot observe an absence, so this sleep is
        // the sanctioned exception rather than a wait to convert.
        try await Task.sleep(for: FavoritesWindowState.searchDebounce * 3)
        #expect(state.debouncedQuery.isEmpty)
        #expect(state.results.count == 2)
        #expect(state.lookupState.expanded.isEmpty)
    }

    @Test("a degraded store's header reads Unavailable with and without a query")
    func degradedCountText() async {
        let (state, cleanup) = makeDegradedState()
        defer { cleanup() }

        #expect(state.countText() == "Unavailable")

        state.query = "見る"
        #expect(
            await pollUntil(timeout: 5) { state.debouncedQuery == "見る" },
            "the query lands over the degraded store"
        )
        #expect(state.countText() == "Unavailable")
    }
}
