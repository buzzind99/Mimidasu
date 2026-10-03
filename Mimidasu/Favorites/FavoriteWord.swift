import Foundation

/// One starred word. Identity is the dictionary headword (`keb ?? reb`),
/// which is also the database's primary key: two entries sharing a `keb` are
/// one favorite, and starring the same word twice is idempotent.
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

    /// The NFKC-decompose-then-compose fold the dictionary probe uses at its
    /// SQL boundary. Stored headwords arrive from JMDict already folded, but
    /// the probe side comes from ASR output, which can emit halfwidth
    /// katakana (`ｶﾞ` vs `ガ`).
    ///
    /// No memo: a transcript re-diff folds a couple of thousand short
    /// strings — microseconds of work, an order of magnitude below the `Set`
    /// probe it feeds. A process-global cache would add an `@unchecked
    /// Sendable` box and shared mutable state for no measurable gain.
    static func normalize(_ text: String) -> String {
        ReadingAlignment.compatibilityComposed(text)
    }

    /// The comparable form of a stored reading, or nil when it carries no kana
    /// and so can never equal a kana surface. Kana-folded, so カタカナ,
    /// halfwidth katakana, and decomposed voicing marks all compare equal
    /// against a hiragana surface.
    static func readingKey(_ reading: String?) -> String? {
        guard let reading, KanaClassification.containsKana(reading) else { return nil }
        return ReadingAlignment.foldedKana(reading)
    }

    /// Whether a rendered segment counts as this word: its surface, its lemma,
    /// or — written in kana, where the surface *is* the reading — a stored
    /// reading. Favouring 見る therefore lights up 見た / 見ます / 見ている, and
    /// favouring 有難う lights up ありがとう, which shares no written form with
    /// it.
    ///
    /// The lemma arm skips bound tokens: they lemmatize away from what is on
    /// screen, so favouring ない would otherwise light ねえ / なきゃ / なし —
    /// conjugates the dictionary resolves to entirely different entries. A
    /// bound token still matches on its exact surface, so spoken ない — a
    /// bound token itself — lights as before.
    static func matches(
        _ segment: ReadingSegment, keys: Set<String>, readings: Set<String>
    ) -> Bool {
        if keys.contains(normalize(segment.surface)) {
            return true
        }
        if let lemma = segment.lemma, !segment.isBound, keys.contains(normalize(lemma)) {
            return true
        }
        // Kana surfaces only. A kana-written surface carries its own
        // pronunciation, so this arm is an exact text comparison against the
        // favorites' kana spellings. A surface with kanji in it never matches
        // here: 置く stays dark for a favorite read おい, and a word's reading
        // is the dictionary's business, not this list's.
        guard !readings.isEmpty, !segment.surface.isEmpty,
              segment.surface.unicodeScalars.allSatisfy(KanaClassification.isKana)
        else { return false }
        return readings.contains(ReadingAlignment.foldedKana(segment.surface))
    }
}

/// What a star press did. `limitReached` (the user's list is full),
/// `pendingRemoval` (an un-star the user must now confirm), and `failed`
/// (the store is degraded) are distinct because one is a refusal the user
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
