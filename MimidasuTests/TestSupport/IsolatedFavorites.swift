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
