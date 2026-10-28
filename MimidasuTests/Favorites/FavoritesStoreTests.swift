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

    @Test("adding a word records it and publishes a new snapshot")
    func addRecordsWord() {
        let (store, cleanup) = makeStore()
        defer { cleanup() }
        let before = store.snapshot

        store.add(Self.miru)

        #expect(store.snapshot.count == 1)
        #expect(store.snapshot.rows.map(\.headword) == ["見る"])
        #expect(store.snapshot != before)
    }

    @Test("removing a starred word removes it and publishes the empty list")
    func removeStarredWordRemovesIt() {
        let (store, cleanup) = makeStore()
        defer { cleanup() }
        store.add(Self.miru)
        let before = store.snapshot

        let outcome = store.remove(headword: Self.miru.headword)

        #expect(outcome == .removed)
        #expect(store.snapshot != before)
        #expect(store.snapshot.rows.isEmpty)
        #expect(!store.snapshot.identity.isFavorite(headword: Self.miru.headword))
    }

    @Test("a removed word stops matching, so the transcript drops its color")
    func removeClearsMatchKey() {
        let (store, cleanup) = makeStore()
        defer { cleanup() }
        store.add(Self.miru)

        store.remove(headword: "見る")

        #expect(!store.matches(segment: segment("見た", lemma: "見る")))
    }

    @Test("a word whose stored spelling folds onto another form is still deletable")
    func removeThroughNormalizedKey() {
        let (location, cleanup) = makeLocation()
        defer { cleanup() }
        let store = FavoritesStore(location: location)
        store.add(
            FavoriteWord(headword: "ｺｰﾋｰ", reading: nil, romaji: nil, addedAt: 1)
        )

        let outcome = store.remove(headword: "コーヒー")

        // The reopen is the assertion that matters: membership is probed by
        // normalized key, but the row was stored halfwidth, so a delete by the
        // requested spelling would match nothing in the file and the favorite
        // would come back on the next launch.
        #expect(outcome == .removed)
        #expect(store.snapshot.rows.isEmpty)
        #expect(FavoritesStore(location: location).snapshot.rows.isEmpty)
    }

    @Test("a removal the file refuses reports unavailable and changes nothing")
    func refusedRemovalReportsUnavailable() throws {
        let (location, cleanup) = makeLocation()
        defer { cleanup() }
        let store = FavoritesStore(location: location)
        store.add(Self.miru)
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
        #expect(store.snapshot.identity.isFavorite(headword: "見る"))
        #expect(store.snapshot.rows.map(\.headword) == ["見る"])

        try blocker.execute("ROLLBACK")
        // Not terminal: the next press commits, costing this one press only.
        #expect(store.remove(headword: "見る") == .removed)
        #expect(store.snapshot.rows.isEmpty)
    }

    // MARK: - Reading arm

    @Test("a word spelled in kana matches a favorite starred in kanji")
    func matchesReadingOfDifferentSpelling() {
        let (store, cleanup) = makeStore()
        defer { cleanup() }
        store.add(Self.arigatou)

        #expect(store.matches(segment: segment("ありがとう")))
    }

    @Test("a removed word stops matching on its reading too")
    func removeClearsReadingKey() {
        let (store, cleanup) = makeStore()
        defer { cleanup() }
        store.add(Self.arigatou)

        store.remove(headword: "有難う")

        #expect(!store.matches(segment: segment("ありがとう")))
    }

    @Test("removing one of two words sharing a reading leaves the other's match")
    func removeKeepsSharedReading() {
        let (store, cleanup) = makeStore()
        defer { cleanup() }
        store.add(Self.arigatou)
        store.add(Self.arigatouKana)

        store.remove(headword: "有難う")

        #expect(store.matches(segment: segment("ありがとう")))
    }

    @Test("a favorite lights its own kana spelling but stays dark for a kanji surface")
    func kanaSpellingMatches() {
        let (store, cleanup) = makeStore()
        defer { cleanup() }
        store.add(Self.oi)

        #expect(!store.matches(segment: segment("置く", lemma: "置く", furigana: "おく")))
        #expect(store.matches(segment: segment("おい")))
    }

    @Test("membership stays keyed on the headword, never on the reading")
    func membershipIgnoresReadingMatch() {
        let (store, cleanup) = makeStore()
        defer { cleanup() }
        store.add(Self.arigatou)

        #expect(!store.isFavorite(headword: "ありがとう"))
    }

    @Test("a reloaded store still matches on the reading")
    func persistsReadingKeys() {
        let (location, cleanup) = makeLocation()
        defer { cleanup() }
        FavoritesStore(location: location).add(Self.arigatou)
        let reopened = FavoritesStore(location: location)

        #expect(reopened.matches(segment: segment("ありがとう")))
    }

    // MARK: - Persistence

    @Test("a second store over the same file sees the rows and matches them")
    func persistsAcrossInstances() {
        let (location, cleanup) = makeLocation()
        defer { cleanup() }
        FavoritesStore(location: location).add(Self.miru)
        let reopened = FavoritesStore(location: location)

        #expect(reopened.snapshot.rows.map(\.headword) == ["見る"])
        #expect(reopened.matches(segment: segment("見た", lemma: "見る")))
    }

    // MARK: - Ordering

    @Test("two words added together come back newest-first")
    func ordersNewestFirst() {
        let (store, cleanup) = makeStore()
        defer { cleanup() }

        store.add(Self.miru)
        store.add(Self.taberu)

        #expect(store.snapshot.rows.map(\.headword) == ["食べる", "見る"])
    }

    @Test("a reopened store orders by the file's timestamp, not by insertion")
    func reopenedOrderFollowsTimestamps() {
        let (location, cleanup) = makeLocation()
        defer { cleanup() }
        let store = FavoritesStore(location: location)
        // Starred in the opposite order to their timestamps: the newer word
        // goes in first, so an insert-at-zero list reads the other way round
        // and only the file's ordering can produce this answer.
        store.add(Self.taberu)
        store.add(Self.miru)

        let reopened = FavoritesStore(location: location)

        #expect(reopened.snapshot.rows.map(\.headword) == ["食べる", "見る"])
    }

    @Test("a backdated star lands where the file would put it, not at the top")
    func backdatedStarKeepsFileOrdering() {
        let (store, cleanup) = makeStore()
        defer { cleanup() }

        store.add(Self.miru)
        store.add(Self.ko)
        store.add(Self.taberu)

        // Timestamps 1000, 1002, 1001: the newest leads and the backdated
        // word slots between it and the oldest — what a reopen reads back,
        // so the list never reshuffles under the user on relaunch.
        #expect(store.snapshot.rows.map(\.headword) == ["50%", "食べる", "見る"])
    }

    @Test("two stars in the same millisecond order by headword and read back in that order")
    func sameTimestampOrdersByHeadword() {
        let (location, cleanup) = makeLocation()
        defer { cleanup() }
        let store = FavoritesStore(location: location)

        store.add(FavoriteWord(headword: "そら", reading: nil, romaji: nil, addedAt: 500))
        store.add(FavoriteWord(headword: "あめ", reading: nil, romaji: nil, addedAt: 500))

        #expect(store.snapshot.rows.map(\.headword) == ["あめ", "そら"])
        #expect(FavoritesStore(location: location).snapshot.rows.map(\.headword) == ["あめ", "そら"])
    }

    // MARK: - Degraded store

    @Test("a store whose file cannot open degrades every file-backed answer")
    func failedLoadReportsDegraded() {
        // A regular file sitting where the store's directory belongs: the
        // open cannot create its parent, the first read fails, and the store
        // degrades terminally.
        let (store, cleanup) = makeDegradedStore()
        defer { cleanup() }

        #expect(store.snapshot.availability == .unavailable)
        #expect(store.snapshot.rows.isEmpty)
        #expect(store.add(Self.miru) == .failed)
        #expect(store.search("見る").isEmpty)
        #expect(!store.matches(segment: segment("見た", lemma: "見る")))
    }

    // MARK: - Ghost rows

    @Test("a legacy empty-headword row in the file is deleted at load, not merely hidden")
    func loadDeletesGhostRowsFromTheFile() throws {
        let (location, cleanup) = makeLocation()
        defer { cleanup() }
        // Seeded straight into the file: a ghost row carrying a real reading —
        // the shape an older writer leaves — next to one healthy row.
        let seeder = FavoritesDatabase(location: location)
        try seeder.insert(FavoriteWord(headword: "", reading: "みる", romaji: "miru", addedAt: 999))
        try seeder.insert(Self.miru)

        let store = FavoritesStore(location: location)

        #expect(store.snapshot.rows == [Self.miru])
        // The reopen is the assertion that matters: a raw handle reads the
        // file without the store's in-memory filter, so a ghost still on disk
        // would show up here — the deletion persisted, not a load-time hiding.
        #expect(FavoritesStore(location: location).snapshot.rows == [Self.miru])
        #expect(try FavoritesDatabase(location: location).all() == [Self.miru])
    }

    @Test("a ghost row written underneath the open store never answers a search")
    func searchDropsGhostRowsWrittenUnderneath() throws {
        let (location, cleanup) = makeLocation()
        defer { cleanup() }
        let store = FavoritesStore(location: location)
        store.add(Self.miru)
        // A second handle on the same file plays the older or parallel
        // writer: the load-time sweep already ran, so only the search filter
        // stands between this row and the list.
        let seeder = FavoritesDatabase(location: location)
        try seeder.insert(FavoriteWord(headword: "", reading: "みる", romaji: "miru", addedAt: 999))

        #expect(store.search("みる") == [Self.miru])
    }

    // MARK: - Search

    @Test(
        "search hits the headword, the kana reading, and the romaji",
        arguments: [("見る", "見る"), ("みる", "見る"), ("miru", "見る")]
    )
    func searchByHeadword(query: String, expectedHeadword: String) {
        let (store, cleanup) = makeStore()
        defer { cleanup() }
        store.add(Self.miru)
        store.add(Self.taberu)

        #expect(store.search(query).map(\.headword) == [expectedHeadword])
    }

    @Test("an empty query returns everything")
    func emptySearchReturnsAll() {
        let (store, cleanup) = makeStore()
        defer { cleanup() }
        store.add(Self.miru)
        store.add(Self.taberu)

        #expect(store.search("   ").count == 2)
    }

    @Test("a query nothing matches returns nothing")
    func searchMissReturnsEmpty() {
        let (store, cleanup) = makeStore()
        defer { cleanup() }
        store.add(Self.miru)

        #expect(store.search("鋼").isEmpty)
    }

    @Test("a percent sign is matched literally, not as a wildcard")
    func searchEscapesWildcards() {
        let (store, cleanup) = makeStore()
        defer { cleanup() }
        store.add(Self.miru)
        store.add(Self.ko)

        #expect(store.search("%").map(\.headword) == ["50%"])
    }

    @Test("an underscore is matched literally, not as a single-character wildcard")
    func searchEscapesUnderscore() {
        let (store, cleanup) = makeStore()
        defer { cleanup() }
        store.add(Self.miru)
        store.add(Self.underscored)

        #expect(store.search("_").map(\.headword) == ["A_B"])
    }

    // MARK: - Cap

    /// A store seeded to the cap through `seededFavorites` — one transaction
    /// for the fixture rows; the deciding press still runs through the
    /// production `add`/`remove` cap paths.
    private func makeFullStore() -> (FavoritesStore, () -> Void) {
        seededFavorites(count: FavoritesStore.limit)
    }

    @Test("the 8193rd distinct add is refused instead of evicting anything")
    func refusesPastTheCap() {
        let (store, cleanup) = makeFullStore()
        defer { cleanup() }
        let before = store.snapshot

        let outcome = store.add(
            FavoriteWord(headword: "overflow", reading: nil, romaji: nil, addedAt: 99999)
        )

        #expect(outcome == .limitReached)
        #expect(!store.snapshot.identity.isFavorite(headword: "overflow"))
        #expect(store.snapshot.count == FavoritesStore.limit)
        #expect(store.snapshot == before)
    }
}

/// Split out of `FavoritesStoreTests` to keep the suite body small; shares
/// the parent's location helpers.
extension FavoritesStoreTests {
    /// A store whose file cannot open, so every file-backed answer is a stub.
    /// Shares the blocked-regular-file shape with `failedLoadReportsDegraded`.
    private func makeDegradedStore() -> (FavoritesStore, () -> Void) {
        let blocked = FileManager.default.temporaryDirectory
            .appendingPathComponent("mimidasu-favorites-degraded-\(UUID().uuidString)")
        #expect(FileManager.default.createFile(atPath: blocked.path, contents: nil))
        let store = FavoritesStore(location: blocked.appendingPathComponent("favorites.sqlite"))
        return (store, { try? FileManager.default.removeItem(at: blocked) })
    }

    @Test("adding an empty headword changes nothing")
    func addEmptyHeadwordIsNoOp() {
        let (location, cleanup) = makeLocation()
        defer { cleanup() }
        let store = FavoritesStore(location: location)

        let outcome = store.add(
            FavoriteWord(headword: "", reading: nil, romaji: nil, addedAt: 0)
        )

        #expect(outcome == .failed)
        #expect(store.snapshot.count == 0)
        #expect(store.snapshot.rows.isEmpty)
        #expect(!store.snapshot.identity.isFavorite(headword: ""))
        #expect(FavoritesStore(location: location).snapshot.rows.isEmpty)
    }

    @Test("same-timestamp words order by UTF-8 bytes, as the file does, where canonical order disagrees")
    func sameTimestampOrdersByUtf8Bytes() throws {
        // A + combining ring sorts after A-umlaut under Swift's canonical
        // comparison (the ring composes to A-ring, which is greater than
        // A-umlaut) but before it byte-wise (0x41 < 0xC3) -- and NFKC keeps
        // the two on distinct keys (A-ring vs A-umlaut), so both rows star.
        // The file's BINARY collation is a byte comparison, so only the
        // UTF-8 tiebreak reads back in the order shown. Code points stay
        // ASCII so no precomposed literal can collapse the pair in transit.
        let decomposedRing = try "A" + String(#require(UnicodeScalar(0x30A)))
        let umlaut = try String(#require(UnicodeScalar(0xC4)))
        let (location, cleanup) = makeLocation()
        defer { cleanup() }
        let store = FavoritesStore(location: location)
        store.add(FavoriteWord(headword: decomposedRing, reading: nil, romaji: nil, addedAt: 500))
        store.add(FavoriteWord(headword: umlaut, reading: nil, romaji: nil, addedAt: 500))

        #expect(umlaut < decomposedRing)
        #expect(store.snapshot.rows.map(\.headword) == [decomposedRing, umlaut])
        #expect(FavoritesStore(location: location).snapshot.rows.map(\.headword) == [decomposedRing, umlaut])
    }

    @Test("a removal at the cap still removes")
    func removeAtCapRemoves() {
        let (store, cleanup) = makeFullStore()
        defer { cleanup() }

        let outcome = store.remove(headword: "語0")

        #expect(outcome == .removed)
        #expect(store.snapshot.count == FavoritesStore.limit - 1)
        #expect(!store.snapshot.identity.isFavorite(headword: "語0"))
    }
}

/// Snapshot publication: one new snapshot per successful mutation, while the
/// unchanged, absent, refused, and limit paths leave the previous one intact.
extension FavoritesStoreTests {

    @Test("add publishes one new snapshot and reports added")
    func addPublishesOneSnapshot() {
        let (store, cleanup) = makeStore()
        defer { cleanup() }
        let before = store.snapshot

        let outcome = store.add(Self.miru)

        #expect(outcome == .added)
        #expect(store.snapshot != before)
        #expect(store.snapshot.rows == [Self.miru])
        #expect(store.snapshot.count == 1)
        #expect(store.snapshot.availability == .available)
        #expect(store.snapshot.identity.isFavorite(headword: "見る"))
    }

    @Test("add inserts at the file-order index")
    func addKeepsFileOrder() {
        let (store, cleanup) = makeStore()
        defer { cleanup() }

        store.add(Self.miru)
        store.add(Self.ko)
        store.add(Self.taberu)

        #expect(store.snapshot.rows.map(\.headword) == ["50%", "食べる", "見る"])
        #expect(store.snapshot.count == 3)
    }

    @Test("adding a starred word is unchanged and leaves the snapshot identical")
    func addExistingWordIsUnchanged() {
        let (store, cleanup) = makeStore()
        defer { cleanup() }
        store.add(Self.miru)
        let before = store.snapshot

        let outcome = store.add(Self.miru)

        #expect(outcome == .unchanged)
        #expect(store.snapshot == before)
    }

    @Test("removing a starred word publishes the remaining rows")
    func removePublishesRemainingRows() {
        let (store, cleanup) = makeStore()
        defer { cleanup() }
        store.add(Self.miru)
        store.add(Self.taberu)

        let outcome = store.remove(headword: "見る")

        #expect(outcome == .removed)
        #expect(store.snapshot.rows == [Self.taberu])
        #expect(store.snapshot.count == 1)
        #expect(!store.snapshot.identity.isFavorite(headword: "見る"))
    }

    @Test("removing an absent word keeps the snapshot identical")
    func removeAbsentWordKeepsSnapshot() {
        let (store, cleanup) = makeStore()
        defer { cleanup() }
        store.add(Self.miru)
        let before = store.snapshot

        let outcome = store.remove(headword: "食べる")

        #expect(outcome == .removed)
        #expect(store.snapshot == before)
    }

    @Test("a refused delete leaves the snapshot identical")
    func refusedRemovalKeepsSnapshot() throws {
        let (location, cleanup) = makeLocation()
        defer { cleanup() }
        let store = FavoritesStore(location: location)
        store.add(Self.miru)
        let before = store.snapshot
        let blocker = try SQLiteDatabase.writable(path: location.path)
        try blocker.execute("BEGIN EXCLUSIVE")

        let outcome = store.remove(headword: "見る")

        #expect(outcome == .failed)
        #expect(store.snapshot == before)
        try blocker.execute("ROLLBACK")
    }

    @Test("a refused insert leaves the snapshot identical")
    func refusedAddKeepsSnapshot() throws {
        let (location, cleanup) = makeLocation()
        defer { cleanup() }
        let store = FavoritesStore(location: location)
        store.add(Self.miru)
        let before = store.snapshot
        let blocker = try SQLiteDatabase.writable(path: location.path)
        try blocker.execute("BEGIN EXCLUSIVE")

        let outcome = store.add(Self.taberu)

        #expect(outcome == .failed)
        #expect(store.snapshot == before)
        try blocker.execute("ROLLBACK")
    }

    @Test("add at the cap leaves the snapshot identical")
    func limitReachedKeepsSnapshot() {
        let (store, cleanup) = makeFullStore()
        defer { cleanup() }
        let before = store.snapshot

        let outcome = store.add(
            FavoriteWord(headword: "overflow", reading: nil, romaji: nil, addedAt: 99999)
        )

        #expect(outcome == .limitReached)
        #expect(store.snapshot == before)
    }

    @Test("a degraded store publishes an unavailable snapshot at init")
    func degradedStorePublishesUnavailableSnapshot() {
        let (store, cleanup) = makeDegradedStore()
        defer { cleanup() }

        #expect(store.snapshot.availability == .unavailable)
        #expect(!store.snapshot.isAvailable)
        #expect(store.snapshot.rows.isEmpty)
    }

    @Test("adding on a degraded store fails and keeps the unavailable snapshot")
    func degradedStoreAddFails() {
        let (store, cleanup) = makeDegradedStore()
        defer { cleanup() }
        let before = store.snapshot

        let outcome = store.add(Self.miru)

        #expect(outcome == .failed)
        #expect(store.snapshot == before)
        #expect(store.snapshot.availability == .unavailable)
    }
}
