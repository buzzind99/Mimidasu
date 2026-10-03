import Foundation
@testable import Mimidasu
import Testing

/// The store's durable side: the SQLite file, the in-memory match set that
/// must track it, the ordering, the search, and the cap. Every test owns a
/// private temp directory and removes it with `defer` — Swift Testing has no
/// `tearDown`, and the store opens its file eagerly in `init`.
@MainActor
@Suite("FavoritesStore")
struct FavoritesStoreTests {

    private static let miru = FavoriteWord(
        headword: "見る", reading: "みる", romaji: "miru", addedAt: 1000
    )
    private static let taberu = FavoriteWord(
        headword: "食べる", reading: "たべる", romaji: "taberu", addedAt: 1001
    )
    private static let ko = FavoriteWord(
        headword: "50%", reading: nil, romaji: nil, addedAt: 1002
    )
    /// A word whose kanji spelling is what the user starred while the
    /// transcript spells it in kana — the reported miss.
    private static let arigatou = FavoriteWord(
        headword: "有難う", reading: "ありがとう", romaji: "arigatou", addedAt: 1003
    )
    private static let arigatouKana = FavoriteWord(
        headword: "ありがとう", reading: "ありがとう", romaji: "arigatou", addedAt: 1004
    )
    /// The reported counter-case: 置く must stay dark for this favorite, while
    /// a kana おい surface lights up. The two words share a reading and nothing
    /// else.
    private static let oi = FavoriteWord(
        headword: "おい", reading: "おい", romaji: "oi", addedAt: 1005
    )
    /// Carries the one character a user can type that would otherwise match
    /// every row.
    private static let underscored = FavoriteWord(
        headword: "A_B", reading: nil, romaji: nil, addedAt: 1006
    )

    /// A fresh temp directory, the store file inside it, and the closure that
    /// removes the directory. Unique per call, so parallel tests never share
    /// a file — and the location is handed back so the persistence tests can
    /// open a second store over the same path.
    private func makeLocation() -> (URL, () -> Void) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mimidasu-favorites-store-\(UUID().uuidString)", isDirectory: true)
        return (
            root.appendingPathComponent("favorites.sqlite"),
            { try? FileManager.default.removeItem(at: root) }
        )
    }

    private func makeStore() -> (FavoritesStore, () -> Void) {
        let (location, cleanup) = makeLocation()
        return (FavoritesStore(location: location), cleanup)
    }

    private func segment(
        _ surface: String, lemma: String? = nil, furigana: String? = nil
    ) -> ReadingSegment {
        ReadingSegment(surface: surface, romaji: surface, furigana: furigana, lemma: lemma)
    }

    // MARK: - Membership

    @Test("adding a word records it")
    func addRecordsWord() {
        let (store, cleanup) = makeStore()
        defer { cleanup() }

        store.toggle(Self.miru)

        #expect(store.count == 1)
    }

    @Test("adding a word publishes its headword")
    func addPublishesHeadword() {
        let (store, cleanup) = makeStore()
        defer { cleanup() }

        store.toggle(Self.miru)

        #expect(store.words.map(\.headword) == ["見る"])
    }

    @Test("adding a word bumps the revision the transcript repaints on")
    func addBumpsRevision() {
        let (store, cleanup) = makeStore()
        defer { cleanup() }
        let before = store.revision

        store.toggle(Self.miru)

        #expect(store.revision > before)
    }

    @Test("toggling a starred word removes it")
    func toggleRemovesStarredWord() {
        let (store, cleanup) = makeStore()
        defer { cleanup() }
        store.toggle(Self.miru)

        let outcome = store.toggle(Self.miru)

        #expect(outcome == .removed)
    }

    @Test("a removed word stops matching, so the transcript drops its color")
    func removeClearsMatchKey() {
        let (store, cleanup) = makeStore()
        defer { cleanup() }
        store.toggle(Self.miru)

        store.remove(headword: "見る")

        #expect(!store.matches(segment: segment("見た", lemma: "見る")))
    }

    @Test("a word whose stored spelling folds onto another form is still deletable")
    func removeThroughNormalizedKey() {
        let (location, cleanup) = makeLocation()
        defer { cleanup() }
        let store = FavoritesStore(location: location)
        store.toggle(
            FavoriteWord(headword: "ｺｰﾋｰ", reading: nil, romaji: nil, addedAt: 1)
        )

        store.remove(headword: "コーヒー")

        // The reopen is the assertion that matters: membership is probed by
        // normalized key, but the row was stored halfwidth, so a delete by the
        // requested spelling would match nothing in the file and the favorite
        // would come back on the next launch.
        #expect(FavoritesStore(location: location).words.isEmpty)
    }

    @Test("a removal the file refuses reports unavailable and changes nothing")
    func refusedRemovalReportsUnavailable() throws {
        let (location, cleanup) = makeLocation()
        defer { cleanup() }
        let store = FavoritesStore(location: location)
        store.toggle(Self.miru)
        // A second connection holding an exclusive transaction faults the
        // store's delete immediately — the one way a healthy file refuses a
        // write, and the shape a busy disk or a competing writer produces.
        // Until now this branch was unreachable from a fixture: a degraded
        // store holds no favorites, so its removal never reached the delete.
        let blocker = try SQLiteDatabase.writable(path: location.path)
        try blocker.execute("BEGIN EXCLUSIVE")

        #expect(store.remove(headword: "見る") == .failed)

        // Nothing changed where the user can see: the word stays starred, and
        // the memory the transcript colors still mirrors what the user was
        // shown — the divergence window is the file's, not the list's.
        #expect(store.isFavorite(headword: "見る"))
        #expect(store.words.map(\.headword) == ["見る"])

        try blocker.execute("ROLLBACK")
        // Not terminal: the next press commits, costing this one press only.
        #expect(store.remove(headword: "見る") == .removed)
        #expect(store.words.isEmpty)
    }

    // MARK: - Reading arm

    @Test("a word spelled in kana matches a favorite starred in kanji")
    func matchesReadingOfDifferentSpelling() {
        let (store, cleanup) = makeStore()
        defer { cleanup() }
        store.toggle(Self.arigatou)

        #expect(store.matches(segment: segment("ありがとう")))
    }

    @Test("a removed word stops matching on its reading too")
    func removeClearsReadingKey() {
        let (store, cleanup) = makeStore()
        defer { cleanup() }
        store.toggle(Self.arigatou)

        store.remove(headword: "有難う")

        #expect(!store.matches(segment: segment("ありがとう")))
    }

    @Test("removing one of two words sharing a reading leaves the other's match")
    func removeKeepsSharedReading() {
        let (store, cleanup) = makeStore()
        defer { cleanup() }
        store.toggle(Self.arigatou)
        store.toggle(Self.arigatouKana)

        store.remove(headword: "有難う")

        #expect(store.matches(segment: segment("ありがとう")))
    }

    @Test("a kanji surface stays dark for a favorite sharing only its reading")
    func kanjiSurfaceStaysDark() {
        let (store, cleanup) = makeStore()
        defer { cleanup() }
        store.toggle(Self.oi)

        #expect(!store.matches(segment: segment("置く", lemma: "置く", furigana: "おく")))
    }

    @Test("the same favorite lights up its own kana spelling")
    func kanaSpellingMatches() {
        let (store, cleanup) = makeStore()
        defer { cleanup() }
        store.toggle(Self.oi)

        #expect(store.matches(segment: segment("おい")))
    }

    @Test("membership stays keyed on the headword, never on the reading")
    func membershipIgnoresReadingMatch() {
        let (store, cleanup) = makeStore()
        defer { cleanup() }
        store.toggle(Self.arigatou)

        #expect(!store.isFavorite(headword: "ありがとう"))
    }

    @Test("a reloaded store still matches on the reading")
    func persistsReadingKeys() {
        let (location, cleanup) = makeLocation()
        defer { cleanup() }
        FavoritesStore(location: location).toggle(Self.arigatou)
        let reopened = FavoritesStore(location: location)

        #expect(reopened.matches(segment: segment("ありがとう")))
    }

    // MARK: - Persistence

    @Test("a second store over the same file sees the rows")
    func persistsAcrossInstances() {
        let (location, cleanup) = makeLocation()
        defer { cleanup() }
        FavoritesStore(location: location).toggle(Self.miru)
        let reopened = FavoritesStore(location: location)

        #expect(reopened.words.map(\.headword) == ["見る"])
    }

    @Test("a reloaded store matches the same segments")
    func persistsMatchKeys() {
        let (location, cleanup) = makeLocation()
        defer { cleanup() }
        FavoritesStore(location: location).toggle(Self.miru)
        let reopened = FavoritesStore(location: location)

        #expect(reopened.matches(segment: segment("見た", lemma: "見る")))
    }

    // MARK: - Ordering

    @Test("two words added together come back newest-first")
    func ordersNewestFirst() {
        let (store, cleanup) = makeStore()
        defer { cleanup() }

        store.toggle(Self.miru)
        store.toggle(Self.taberu)

        #expect(store.words.map(\.headword) == ["食べる", "見る"])
    }

    @Test("a reopened store orders by the file's timestamp, not by insertion")
    func reopenedOrderFollowsTimestamps() {
        let (location, cleanup) = makeLocation()
        defer { cleanup() }
        let store = FavoritesStore(location: location)
        // Starred in the opposite order to their timestamps: the newer word
        // goes in first, so an insert-at-zero list reads the other way round
        // and only the file's ordering can produce this answer.
        store.toggle(Self.taberu)
        store.toggle(Self.miru)

        let reopened = FavoritesStore(location: location)

        #expect(reopened.words.map(\.headword) == ["食べる", "見る"])
    }

    // MARK: - Search

    @Test("search hits the headword")
    func searchByHeadword() {
        let (store, cleanup) = makeStore()
        defer { cleanup() }
        store.toggle(Self.miru)
        store.toggle(Self.taberu)

        #expect(store.search("見る").map(\.headword) == ["見る"])
    }

    @Test("search hits the kana reading")
    func searchByReading() {
        let (store, cleanup) = makeStore()
        defer { cleanup() }
        store.toggle(Self.miru)

        #expect(store.search("みる").map(\.headword) == ["見る"])
    }

    @Test("search hits the romaji")
    func searchByRomaji() {
        let (store, cleanup) = makeStore()
        defer { cleanup() }
        store.toggle(Self.miru)

        #expect(store.search("miru").map(\.headword) == ["見る"])
    }

    @Test("an empty query returns everything")
    func emptySearchReturnsAll() {
        let (store, cleanup) = makeStore()
        defer { cleanup() }
        store.toggle(Self.miru)
        store.toggle(Self.taberu)

        #expect(store.search("   ").count == 2)
    }

    @Test("a query nothing matches returns nothing")
    func searchMissReturnsEmpty() {
        let (store, cleanup) = makeStore()
        defer { cleanup() }
        store.toggle(Self.miru)

        #expect(store.search("鋼").isEmpty)
    }

    @Test("a percent sign is matched literally, not as a wildcard")
    func searchEscapesWildcards() {
        let (store, cleanup) = makeStore()
        defer { cleanup() }
        store.toggle(Self.miru)
        store.toggle(Self.ko)

        #expect(store.search("%").map(\.headword) == ["50%"])
    }

    @Test("an underscore is matched literally, not as a single-character wildcard")
    func searchEscapesUnderscore() {
        let (store, cleanup) = makeStore()
        defer { cleanup() }
        store.toggle(Self.miru)
        store.toggle(Self.underscored)

        #expect(store.search("_").map(\.headword) == ["A_B"])
    }

    // MARK: - Cap

    @Test("the 8193rd distinct add is refused instead of evicting anything")
    func refusesPastTheCap() {
        let (store, cleanup) = makeStore()
        defer { cleanup() }
        for index in 0 ..< FavoritesStore.limit {
            store.toggle(FavoriteWord(
                headword: "語\(index)", reading: nil, romaji: nil, addedAt: index
            ))
        }

        let outcome = store.toggle(
            FavoriteWord(headword: "overflow", reading: nil, romaji: nil, addedAt: 99999)
        )

        #expect(outcome == .limitReached)
    }

    @Test("a refused add leaves the list at the cap and nothing evicted")
    func refusalKeepsTheList() {
        let (store, cleanup) = makeStore()
        defer { cleanup() }
        for index in 0 ..< FavoritesStore.limit {
            store.toggle(FavoriteWord(
                headword: "語\(index)", reading: nil, romaji: nil, addedAt: index
            ))
        }
        let before = store.revision

        store.toggle(
            FavoriteWord(headword: "overflow", reading: nil, romaji: nil, addedAt: 99999)
        )

        #expect(store.count == FavoritesStore.limit && store.revision == before)
    }
}
