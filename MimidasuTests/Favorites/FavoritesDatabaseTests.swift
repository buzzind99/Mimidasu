import Foundation
@testable import Mimidasu
import Testing

/// The SQL boundary itself: the two guarantees the store's API cannot reach.
/// Through `FavoritesStore` a headword that is already present removes on the
/// next toggle, so the idempotent insert — the primary key doing the work — is
/// only observable here. Each test owns a private temp directory and removes it
/// with `defer`; the database creates its parent directories on open.
@Suite("FavoritesDatabase")
struct FavoritesDatabaseTests {

    private static let ko = FavoriteWord(
        headword: "見る", reading: "みる", romaji: "miru", addedAt: 1000
    )

    private func makeDatabase() -> (FavoritesDatabase, () -> Void) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mimidasu-favorites-db-\(UUID().uuidString)", isDirectory: true)
        return (
            FavoritesDatabase(location: root.appendingPathComponent("favorites.sqlite")),
            { try? FileManager.default.removeItem(at: root) }
        )
    }

    @Test("inserting a starred headword again leaves one row")
    func insertIsIdempotent() throws {
        let (database, cleanup) = makeDatabase()
        defer { cleanup() }

        try database.insert(Self.ko)
        try database.insert(Self.ko)

        #expect(try database.all().count == 1)
    }

    @Test("a delete of a spelling the row does not carry removes nothing")
    func deleteMatchesStoredSpelling() throws {
        let (database, cleanup) = makeDatabase()
        defer { cleanup() }
        try database.insert(Self.ko)

        try database.delete(headword: "みる")

        #expect(try database.all().count == 1)
    }

    @Test("a database that cannot be opened degrades every operation")
    func unopenableLocationDegrades() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mimidasu-favorites-blocked-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let blocked = root.appendingPathComponent("blocked.sqlite")
        try Data().write(to: blocked)

        let database = FavoritesDatabase(location: blocked.appendingPathComponent("nested.sqlite"))

        let error = await #expect(throws: FavoritesDatabase.Error.degraded) {
            try database.all()
        }
        #expect(error == .degraded)
    }
}
