import Foundation
import Observation

/// The user's starred words, and the render-path answer to "is this segment a
/// favorite?".
///
/// Two read paths on purpose. `words` and `search` are durable — the file is
/// the record and the SQL owns ordering and filtering. `matchKeys` is an
/// in-memory `Set` of *normalized* headwords probed by the transcript twice
/// per segment per re-diff; it must never touch SQLite. Every mutation keeps
/// the set and `words` consistent, which is otherwise invisible: a stale key
/// means a word simply never lights up.
@Observable
@MainActor
final class FavoritesStore {
    /// Hard cap on the list. The next star past it is refused with a visible
    /// warning — nothing is ever silently evicted, because an evicted word is
    /// worse than a refused one.
    static let limit = 8192

    /// Every favorite, newest first. Held in memory (≤`limit` rows of three
    /// short strings) so the window renders without touching the disk.
    private(set) var words: [FavoriteWord] = []
    /// `words.count`, kept as its own property because the header renders it
    /// on every tick of a search.
    private(set) var count = 0
    /// Bumped on every mutation that changed what is on screen. This is the
    /// only mechanism that repaints the transcript, and it travels down to
    /// `RubyTextView` as a plain `Int` because a matcher closure carries no
    /// value identity and can never break an `Equatable` comparison.
    private(set) var revision = 0

    /// Normalized headwords — the hot path. Raw spellings live in `words`.
    private var matchKeys: Set<String> = []
    /// Kana-folded readings of the same words — the kana spelling a favorited
    /// word can also be written as. Kept apart from `matchKeys` on purpose: a
    /// kana-written segment matches one of these, while star membership and
    /// removal stay exact headword operations (D8/D23). One set for both would
    /// let a spelling hit fill a star, and would let `remove(headword:)` delete
    /// a row nobody named.
    private var readingKeys: Set<String> = []

    /// Favorites are authored user data that must survive a clean, so they
    /// live in Application Support in **both** configurations — unlike the
    /// prepared dictionary artifacts, which are derived and belong in the
    /// gitignored `build/` in debug. Debug and release still resolve to
    /// different files: only release is sandboxed.
    static var defaultLocation: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Mimidasu/favorites.sqlite")
    }

    private let database: FavoritesDatabase

    /// Opens the database and loads the match set synchronously: ~`limit`
    /// short rows parse well under a millisecond. `location` is the whole
    /// test-isolation seam — the default is the real production file, so a
    /// test that forgets to inject one writes to the developer's own
    /// vocabulary.
    init(location: URL = FavoritesStore.defaultLocation) {
        database = FavoritesDatabase(location: location)
        if let loaded = try? database.all() {
            words = loaded
            count = loaded.count
            matchKeys = Set(loaded.map { word in FavoriteWord.normalize(word.headword) })
            readingKeys = Self.readingKeys(for: loaded)
        } else {
            print("favorites: load failed, starting empty")
        }
    }

    var isFull: Bool {
        count >= Self.limit
    }

    func isFavorite(headword: String?) -> Bool {
        guard let headword else { return false }
        return matchKeys.contains(FavoriteWord.normalize(headword))
    }

    /// The render-path probe. Static so it is directly unit-testable without
    /// a store or a database.
    func matches(segment: ReadingSegment) -> Bool {
        FavoriteWord.matches(segment, keys: matchKeys, readings: readingKeys)
    }

    /// The lookup content with a favorited entry moved to the front of the
    /// display result's pager. A thin forwarder so `AppModel` never reads
    /// `matchKeys` itself.
    func promotingFavorites(in content: LookupContent) -> LookupContent {
        FavoritesPromotion.promotingFavorites(in: content, keys: matchKeys)
    }

    /// The comparable readings of a row set. A set, so two favorites sharing a
    /// reading collapse onto one key and neither is counted twice.
    private static func readingKeys(for words: [FavoriteWord]) -> Set<String> {
        Set(words.compactMap { word in FavoriteWord.readingKey(word.reading) })
    }

    /// Stars the word, or unstars it when already present. The cap is checked
    /// against the in-memory count on the main actor, so it is race-free
    /// without a transaction.
    @discardableResult
    func toggle(_ word: FavoriteWord) -> FavoriteToggle {
        let key = FavoriteWord.normalize(word.headword)
        if matchKeys.contains(key) {
            return remove(headword: word.headword)
        }
        guard !isFull else { return .limitReached }
        do {
            try database.insert(word)
        } catch {
            return .failed
        }
        words.insert(word, at: 0)
        count = words.count
        matchKeys.insert(key)
        if let reading = FavoriteWord.readingKey(word.reading) {
            readingKeys.insert(reading)
        }
        revision += 1
        return .added
    }

    /// Removes by the *raw* spelling while probing the normalized set, so a
    /// row whose stored headword folds onto another form is still removable.
    @discardableResult
    func remove(headword: String) -> FavoriteToggle {
        let key = FavoriteWord.normalize(headword)
        guard matchKeys.contains(key) else { return .removed }
        do {
            try database.delete(headword: headword)
        } catch {
            return .failed
        }
        matchKeys.remove(key)
        words.removeAll { word in FavoriteWord.normalize(word.headword) == key }
        count = words.count
        // Rebuilt rather than key-by-key: two favorites can share a reading
        // (有難う and ありがとう both read the same), and dropping the removed
        // row's key alone would strand the survivor's highlight.
        readingKeys = Self.readingKeys(for: words)
        revision += 1
        return .removed
    }

    /// Filtering and ordering stay the database's job, so they stay testable
    /// against a real file.
    func search(_ query: String) -> [FavoriteWord] {
        (try? database.search(query)) ?? []
    }
}
