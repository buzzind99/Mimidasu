import Foundation

/// Reorders a resolved lookup so the words a user has starred lead. Lives in
/// `Favorites/` and stays pure so it is testable without a store, a database,
/// or a model — and so the dictionary engine, which ranks entries for a reason
/// of its own (the writing the tap was written in, then commonness), never has
/// to know that favorites exist.
enum FavoritesPromotion {

    /// `content` with a favorited entry moved to the front of the found
    /// display result's pager. Everything else is untouched: the display
    /// result still leads, `also:` hits stay demoted, and a not-found pin keeps
    /// its related splits as suggestions (a split hit must never present itself
    /// as the tapped word, D9).
    static func promotingFavorites(
        in content: LookupContent, keys: Set<String>
    ) -> LookupContent {
        switch content {
        case let .found(result, also, origin):
            .found(
                result: promotingFavorites(in: result, keys: keys),
                also: also, origin: origin
            )
        case .notFound:
            content
        }
    }

    /// `result` with its first favorited entry promoted to the front; the
    /// identity of the result itself, and so everything else, unchanged. The
    /// first favorite wins a tie and every other entry keeps its order, so
    /// two taps on the same word land on the same entry.
    static func promotingFavorites(
        in result: LookupResult, keys: Set<String>
    ) -> LookupResult {
        guard let index = result.entries.firstIndex(where: { entry in
            isFavorite(entry, keys: keys)
        }), index != 0 else { return result }
        var entries = result.entries
        entries.insert(entries.remove(at: index), at: 0)
        return LookupResult(matched: result.matched, entries: entries)
    }

    /// Headword identity, the same rule the star and the removal path use — so
    /// the entry the pager leads with is the entry whose star reads filled.
    private static func isFavorite(_ entry: JMDictEntry, keys: Set<String>) -> Bool {
        guard let headword = DictionaryContent.headword(of: entry) else { return false }
        return keys.contains(FavoriteWord.normalize(headword))
    }
}
