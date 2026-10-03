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

    private struct Fixture {
        let location: URL
        let database: FavoritesDatabase
        let cleanup: () -> Void
    }

    private func makeDatabase() -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mimidasu-favorites-db-\(UUID().uuidString)", isDirectory: true)
        let location = root.appendingPathComponent("favorites.sqlite")
        return Fixture(
            location: location,
            database: FavoritesDatabase(location: location),
            cleanup: { try? FileManager.default.removeItem(at: root) }
        )
    }

    @Test("inserting a starred headword again leaves one row")
    func insertIsIdempotent() throws {
        let fixture = makeDatabase()
        defer { fixture.cleanup() }

        try fixture.database.insert(Self.ko)
        try fixture.database.insert(Self.ko)

        #expect(try fixture.database.all().count == 1)
    }

    @Test("a delete of a spelling the row does not carry removes nothing")
    func deleteMatchesStoredSpelling() throws {
        let fixture = makeDatabase()
        defer { fixture.cleanup() }
        try fixture.database.insert(Self.ko)

        try fixture.database.delete(headword: "みる")

        #expect(try fixture.database.all().count == 1)
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

    @Test("an explicitly degraded database fails every operation")
    func explicitDegradeIsTerminal() async throws {
        let fixture = makeDatabase()
        defer { fixture.cleanup() }
        try fixture.database.insert(Self.ko)

        fixture.database.degrade()

        let read = await #expect(throws: FavoritesDatabase.Error.degraded) {
            try fixture.database.all()
        }
        #expect(read == .degraded)
        let write = await #expect(throws: FavoritesDatabase.Error.degraded) {
            try fixture.database.insert(Self.ko)
        }
        #expect(write == .degraded)
    }

    @Test("an operation the file refuses degrades once, and the next one works")
    func refusedOperationDegradesOnce() async throws {
        let fixture = makeDatabase()
        defer { fixture.cleanup() }
        try fixture.database.insert(Self.ko)
        // A second connection holding an exclusive transaction faults the
        // database's next operation immediately — the shape a busy disk or a
        // competing writer produces, and the one a fixture can produce.
        let blocker = try SQLiteDatabase.writable(path: fixture.location.path)
        try blocker.execute("BEGIN EXCLUSIVE")

        let refused = await #expect(throws: FavoritesDatabase.Error.degraded) {
            try fixture.database.all()
        }
        #expect(refused == .degraded)

        try blocker.execute("ROLLBACK")
        #expect(try fixture.database.all().count == 1)
    }
}
