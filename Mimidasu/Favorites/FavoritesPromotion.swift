import Foundation

/// Reorders a resolved lookup so a starred entry written or read as the
/// looked-up word leads. Lives in `Favorites/` and stays pure so it is
/// testable without a store, a database, or a model — and so the dictionary
/// engine, which ranks entries for a reason of its own (the writing the tap
/// was written in, then commonness), never has to know that favorites exist.
enum FavoritesPromotion {

    /// `content` with an eligible favorited entry moved to the front of the
    /// found display result's pager and of every demoted fallback result's
    /// pager. A fallback pill labels itself with its result's lead entry, so
    /// promotion inside an `also:` result is what makes a buried eligible
    /// favorite readable there — the pill relabels to the starred word and
    /// opens on it, instead of the homograph the dictionary ranked first. A
    /// favorite matched through another spelling (a starred sibling) stays
    /// where the engine ranked it. A not-found pin stays not-found with no
    /// display result, but each related suggestion is promoted the same way,
    /// so a buried eligible favorite leads its pill before any re-select.
    /// Everything else is untouched: the display result still leads, and a
    /// not-found pin keeps its related splits as suggestions (a split hit
    /// never presents as the tapped word).
    static func promotingFavorites(
        in content: LookupContent, identity: FavoriteIdentity
    ) -> LookupContent {
        switch content {
        case let .found(result, also, origin):
            .found(
                result: promotingFavorites(in: result, identity: identity),
                also: also.map { fallback in promotingFavorites(in: fallback, identity: identity) },
                origin: origin
            )
        case let .notFound(surface, related):
            .notFound(
                surface: surface,
                related: related.map { result in
                    promotingFavorites(in: result, identity: identity)
                }
            )
        }
    }

    /// `result` with its first favorited entry promoted to the front, among
    /// the entries that carry the matched text as a writing or a reading;
    /// the identity of the result itself, and so everything else, unchanged.
    /// A favorited sibling spelling — an entry the engine matched through
    /// some other writing, like 辺/へ inside a 方 result — never displaces
    /// the entry the lookup was written with. The first favorite wins a tie
    /// and every other entry keeps its order, so two lookups of the same
    /// word land on the same entry.
    static func promotingFavorites(
        in result: LookupResult, identity: FavoriteIdentity
    ) -> LookupResult {
        guard let index = result.entries.firstIndex(where: { entry in
            identity.isFavorite(entry) && carriesMatchedWritingOrReading(entry, matched: result.matched)
        }), index != 0 else { return result }
        var entries = result.entries
        entries.insert(entries.remove(at: index), at: 0)
        return LookupResult(matched: result.matched, entries: entries)
    }

    /// Whether the entry's primary writing or primary reading folds onto
    /// `matched` — the two spellings a lookup of `matched` is written or
    /// read as. `(keb ?? reb)` is the engine's surface tier, so a kana
    /// `matched` also admits an entry whose writing differs but whose
    /// reading is it — the kana-shared homograph the promotion exists for —
    /// while a kanji `matched` reduces this to the surface tier, so a
    /// starred sibling spelling can never lead.
    private static func carriesMatchedWritingOrReading(
        _ entry: JMDictEntry, matched: String
    ) -> Bool {
        let target = ReadingAlignment.foldedKana(matched)
        if let keb = entry.keb, ReadingAlignment.foldedKana(keb) == target {
            return true
        }
        if let reb = entry.reb, ReadingAlignment.foldedKana(reb) == target {
            return true
        }
        return false
    }
}
