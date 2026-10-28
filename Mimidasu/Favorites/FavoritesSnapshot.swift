import Foundation

/// Whether the favorites database could be read. A healthy store with no
/// favorites and a store whose file failed to load are different states, not
/// two spellings of "empty".
enum FavoritesAvailability: Equatable, Sendable {
    case available
    case unavailable
}

/// One immutable publication of the favorites list: the rows, the membership
/// identity derived from them, and whether the store could read its file.
///
/// `rows` is newest first — the order SQLite returns and the store's in-memory
/// insert rule mirrors. `identity` is always derived from `rows`: rebuilt with
/// `FavoriteIdentity(words:)` on load and removal, folded with `insert(_:)` on
/// add.
///
/// `empty` and `unavailable` are distinct. A healthy store with no favorites
/// is `.empty`; a store whose file could not be read is `.unavailable`, so the
/// window can say the list is unavailable instead of rendering an empty stub
/// as "No favorites yet".
struct FavoritesSnapshot: Equatable, Sendable {
    let rows: [FavoriteWord]
    let identity: FavoriteIdentity
    let availability: FavoritesAvailability

    static let empty = FavoritesSnapshot(rows: [], identity: .empty, availability: .available)
    static let unavailable = FavoritesSnapshot(rows: [], identity: .empty, availability: .unavailable)

    var count: Int {
        rows.count
    }

    var isAvailable: Bool {
        availability == .available
    }
}
