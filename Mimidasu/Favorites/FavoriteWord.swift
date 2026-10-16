import Foundation

/// One starred word. Identity is the dictionary headword — the kanji
/// writing when present, else the reading; an empty spelling counts as
/// absent. The headword is also the database's primary key: two entries
/// sharing a `keb` are one favorite, and starring the same word twice is
/// idempotent.
struct FavoriteWord: Identifiable, Equatable, Sendable {
    let headword: String
    /// The entry's kana reading (`reb`).
    let reading: String?
    /// The reading transliterated for the row's mono sub-line.
    let romaji: String?
    /// Epoch **milliseconds**, written once and never updated. Millisecond
    /// resolution keeps two stars made in the same second distinct, so the
    /// newest-first ordering never degrades to an alphabetical tiebreak
    /// among rows the user added together. Persisted for ordering only —
    /// the UI never displays it.
    let addedAt: Int

    var id: String {
        headword
    }

    /// A favorite being starred right now, built the one way every star site
    /// builds it: the headword the star keys on, the entry's kana reading, its
    /// romaji, and the epoch-millisecond stamp the newest-first ordering needs.
    ///
    /// Shared rather than written per site because the stamp is the part that
    /// goes quietly wrong — a favorite written with a second-resolution `addedAt`
    /// reorders against every other favorite added in the same second, and the
    /// list reshuffles under the cursor with nothing to show for it.
    static func starred(headword: String, reading: String?) -> FavoriteWord {
        FavoriteWord(
            headword: headword,
            reading: reading,
            romaji: reading.flatMap(KanaRomaji.romaji(fromKana:)),
            addedAt: Int(Date.now.timeIntervalSince1970 * 1000)
        )
    }
}

/// What a star press did. `limitReached` (the user's list is full),
/// `pendingRemoval` (an un-star the user must now confirm), and `failed`
/// (the store is degraded, or the word carries no headword and the store
/// refuses it defensively) are distinct because one is a refusal the user
/// caused, one is a question, and the other is a fault deserving a persistent
/// surface — only `added` and `removed` changed anything on screen.
///
/// `pendingRemoval` carries its headword so the host can raise the
/// confirmation without re-deriving it, and so nothing has to be stashed on
/// the shared model while the question is open.
enum FavoriteToggle: Equatable, Sendable {
    case added
    case removed
    case pendingRemoval(headword: String)
    case limitReached
    case failed
}
