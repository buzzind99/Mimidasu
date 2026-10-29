@testable import Mimidasu
import Testing

/// The one publication value: rows, the identity derived from them, and
/// whether the store could read its file. Pure value semantics — no store and
/// no database.
@MainActor
@Suite("FavoritesSnapshot")
struct FavoritesSnapshotTests {

    private static let miru = FavoriteWord(
        headword: "見る", reading: "みる", romaji: "miru", addedAt: 1000
    )
    private static let taberu = FavoriteWord(
        headword: "食べる", reading: "たべる", romaji: "taberu", addedAt: 1001
    )
    private static let arigatou = FavoriteWord(
        headword: "有難う", reading: "ありがとう", romaji: "arigatou", addedAt: 1002
    )
    private static let arigatouKana = FavoriteWord(
        headword: "ありがとう", reading: "ありがとう", romaji: "arigatou", addedAt: 1003
    )
    private static let coffee = FavoriteWord(
        headword: "コーヒー", reading: "こーひー", romaji: "koohii", addedAt: 1004
    )

    private func snapshot(
        rows: [FavoriteWord], availability: FavoritesAvailability = .available
    ) -> FavoritesSnapshot {
        FavoritesSnapshot(
            rows: rows, identity: FavoriteIdentity(words: rows), availability: availability
        )
    }

    @Test("snapshots compare by rows and availability")
    func equalityComparesRowsAndAvailability() {
        let first = snapshot(rows: [Self.taberu, Self.miru])
        let same = snapshot(rows: [Self.taberu, Self.miru])
        let reordered = snapshot(rows: [Self.miru, Self.taberu])
        let unavailable = snapshot(rows: [Self.taberu, Self.miru], availability: .unavailable)

        #expect(first == same)
        #expect(first != reordered)
        #expect(first != unavailable)
    }

    @Test("count is the number of rows")
    func countFollowsRows() {
        #expect(snapshot(rows: []).count == 0)
        #expect(snapshot(rows: [Self.taberu, Self.miru]).count == 2)
    }

    @Test("empty is a healthy, available, empty list")
    func emptyIsAvailableAndEmpty() {
        #expect(FavoritesSnapshot.empty.availability == .available)
        #expect(FavoritesSnapshot.empty.isAvailable)
        #expect(FavoritesSnapshot.empty.rows.isEmpty)
        #expect(FavoritesSnapshot.empty.count == 0)
    }

    @Test("unavailable is a distinct, empty list")
    func unavailableIsUnavailableAndEmpty() {
        #expect(FavoritesSnapshot.unavailable.availability == .unavailable)
        #expect(!FavoritesSnapshot.unavailable.isAvailable)
        #expect(FavoritesSnapshot.unavailable.rows.isEmpty)
        #expect(FavoritesSnapshot.unavailable.count == 0)
        #expect(FavoritesSnapshot.unavailable != FavoritesSnapshot.empty)
    }

    @Test("identity follows rows, including two favorites sharing a reading")
    func identityFollowsRows() {
        let rows = [Self.arigatou, Self.arigatouKana, Self.miru]
        let snapshot = snapshot(rows: rows)

        #expect(snapshot.identity.isFavorite(headword: "有難う"))
        #expect(snapshot.identity.isFavorite(headword: "ありがとう"))
        #expect(snapshot.identity.isFavorite(headword: "見る"))
        #expect(!snapshot.identity.isFavorite(headword: "食べる"))
        #expect(snapshot.identity.keys.count == 3)
        #expect(snapshot.identity.readings == ["ありがとう", "みる"])
    }

    @Test("identity membership is normalized")
    func identityMembershipIsNormalized() {
        let snapshot = snapshot(rows: [Self.coffee])

        #expect(snapshot.identity.isFavorite(headword: "コーヒー"))
        #expect(snapshot.identity.isFavorite(headword: "ｺｰﾋｰ"))
    }
}
