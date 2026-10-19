import Foundation
@testable import Mimidasu
import Testing

/// A `FavoritesStore` over a private temp file. `FavoritesStore()` defaults
/// to the production Application Support location, so every `AppModel` built
/// in tests must go through this fixture — otherwise the suite opens (and
/// `CREATE TABLE`s in) the developer's real vocabulary, which no later run
/// undoes. Unique per call, so parallel tests never share a file; the files
/// live in the temporary directory, which the OS reclaims.
@MainActor
func isolatedFavorites() -> FavoritesStore {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("mimidasu-favorites-\(UUID().uuidString)", isDirectory: true)
    return FavoritesStore(location: root.appendingPathComponent("favorites.sqlite"))
}

/// A `FavoritesStore` over a private temp file seeded with `count` rows
/// (headword 語<index>, oldest first). The rows go in through one SQLite
/// transaction — a fixture, not the behavior under test: the store's own
/// `toggle` costs one fsync'd insert per row, which makes populating the cap
/// take seconds. Returned with the cleanup that removes the temp directory.
@MainActor
func seededFavorites(count: Int) -> (store: FavoritesStore, cleanup: () -> Void) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("mimidasu-favorites-\(UUID().uuidString)", isDirectory: true)
    let location = root.appendingPathComponent("favorites.sqlite")
    // The store's init creates the file and its schema; the seed then writes
    // into that same schema, and the returned store opens over the result.
    _ = FavoritesStore(location: location)
    do {
        let database = try SQLiteDatabase.writable(path: location.path)
        try database.execute("BEGIN")
        let insertSQL =
            "INSERT OR IGNORE INTO favorites (headword, reading, romaji, added_at) "
                + "VALUES (:headword, :reading, :romaji, :added_at)"
        for index in 0 ..< count {
            // Per-row `statement(_:)` is what resets the cached statement for
            // the next bind/step, exactly as `FavoritesDatabase.insert` does.
            let insert = try database.statement(insertSQL)
            insert.bind("語\(index)", at: 1)
            insert.bind("", at: 2)
            insert.bind("", at: 3)
            insert.bind(index, at: 4)
            _ = try insert.step()
        }
        try database.execute("COMMIT")
    } catch {
        Issue.record("seeding \(count) favorites failed: \(error)")
    }
    return (
        FavoritesStore(location: location),
        { try? FileManager.default.removeItem(at: root) }
    )
}
