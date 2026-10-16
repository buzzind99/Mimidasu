import Foundation
import Observation

/// The user's starred words, and the render-path answer to "is this segment a
/// favorite?".
///
/// Two read paths on purpose. `words` and `search` are durable — the file is
/// the record and the SQL owns ordering and filtering. `identity` is the
/// in-memory Favorite identity probed by the transcript twice per segment per
/// re-diff; it must never touch SQLite. Load and removal rebuild it from
/// `words` while each add folds one row in, which is otherwise invisible: a
/// stale identity means a word simply never lights up.
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
    /// Bumped on every mutation that changed what is on screen. Host bodies
    /// read it — `TranscriptView`, `ContentView`, `HUDView` — and discard the
    /// number: it registers an `@Observable` dependency at the surface that
    /// hands the matcher down. `RubyTextView` would repaint without it (its
    /// body invokes the matcher, so it observes `identity` itself), which
    /// makes these reads redundant rather than wrong — they keep the
    /// dependence on favorite state visible where the matcher is supplied.
    private(set) var revision = 0
    /// Whether the database failed on its first read and was degraded
    /// terminally: every file-backed answer is now a stub (empty list, empty
    /// search). The window reads this to say "unavailable" instead of
    /// rendering that stub as "No favorites yet" over data the file may still
    /// hold.
    private(set) var isDegraded = false

    /// One Favorite identity, kept current with `words` on every mutation
    /// that changed what is on screen. Star, Highlight, and Promotion read
    /// this value instead of re-deriving the headword rule each.
    private(set) var identity = FavoriteIdentity.empty

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

    /// Opens the database, deletes the legacy empty-headword rows out of the
    /// file, and loads the word rows synchronously, building the identity
    /// snapshot from them: ~`limit` short rows parse well under a millisecond.
    /// The load still drops empty headwords from memory — belt-and-braces for
    /// a row an older or parallel process writes underneath the store after
    /// the sweep.
    /// `location` is the whole test-isolation seam — the default is the real
    /// production file, so a test that forgets to inject one writes to the
    /// developer's own vocabulary.
    ///
    /// A failed load degrades the database terminally. The store's contract is
    /// that memory mirrors the file, and a transient fault on the very first
    /// read would break exactly that: membership would be answered from empty
    /// memory while the handle went on serving a file the store can no longer
    /// see. Degraded, every mutation that reaches the file fails into the
    /// `.failed` paths instead; `remove` answers `.removed` at its membership
    /// guard first, because a degraded store holds no favorites to remove.
    /// The sweep is best-effort by contrast: a failed sweep only logs,
    /// because the load filter and the search filter still drop empty
    /// headwords from memory.
    init(location: URL = FavoritesStore.defaultLocation) {
        let database = FavoritesDatabase(location: location)
        self.database = database
        do {
            try database.deleteEmptyHeadwords()
        } catch {
            print("favorites: ghost-row sweep skipped: \(error)")
        }
        do {
            let loaded = try database.all().filter { word in !word.headword.isEmpty }
            words = loaded
            count = loaded.count
            identity = FavoriteIdentity(words: loaded)
        } catch {
            print("favorites: load failed, degrading: \(error)")
            isDegraded = true
            database.degrade()
        }
    }

    var isFull: Bool {
        count >= Self.limit
    }

    func isFavorite(headword: String?) -> Bool {
        identity.isFavorite(headword: headword)
    }

    /// The render-path probe over the current identity.
    func matches(segment: ReadingSegment) -> Bool {
        identity.matches(segment)
    }

    /// Stars the word, or unstars it when already present. The cap is checked
    /// against the in-memory count on the main actor, so it is race-free
    /// without a transaction.
    @discardableResult
    func toggle(_ word: FavoriteWord) -> FavoriteToggle {
        guard !word.headword.isEmpty else { return .failed }
        if identity.isFavorite(headword: word.headword) {
            return remove(headword: word.headword)
        }
        guard !isFull else { return .limitReached }
        do {
            try database.insert(word)
        } catch {
            return .failed
        }
        // The position the file would give the row — `added_at DESC,
        // headword ASC` under BINARY collation. The window renders `words`
        // directly, so an off-order insert would reshuffle under the user on
        // the next launch's reload. The tiebreak compares UTF-8 bytes, which
        // is what BINARY means; Swift's canonical ordering can disagree.
        let index = words.firstIndex { element in
            element.addedAt < word.addedAt
                || (element.addedAt == word.addedAt
                    && word.headword.utf8.lexicographicallyPrecedes(element.headword.utf8))
        } ?? words.count
        words.insert(word, at: index)
        count = words.count
        identity.insert(word)
        revision += 1
        return .added
    }

    /// Removes by the spellings the rows were *stored* under, while membership
    /// is probed by the normalized form — the two are different questions, and
    /// the file has to answer the delete in its own terms. A row stored as
    /// `ｺｰﾋｰ` and removed as `コーヒー` is the same word, but `DELETE` matches
    /// the stored text exactly: deleting by the requested spelling would match
    /// no row, clear the memory, and let the favorite reappear on the next
    /// launch.
    @discardableResult
    func remove(headword: String) -> FavoriteToggle {
        let key = FavoriteIdentity.normalize(headword)
        guard identity.keys.contains(key) else { return .removed }
        // Non-empty: `identity` holds a key only because a loaded row
        // normalizes to it.
        let doomed = words.filter { word in FavoriteIdentity.normalize(word.headword) == key }
        do {
            // One delete per row rather than one statement: the spellings are
            // only known from memory. If a later delete fails the file has lost
            // the rows committed before it while memory still lists them — which
            // heals on the next press, because membership is answered from
            // memory and deleting an already-deleted row is a no-op. Wrapping
            // the loop in a transaction would close the window; transaction
            // support on the shared SQLite type is a separate change.
            for word in doomed {
                try database.delete(headword: word.headword)
            }
        } catch {
            return .failed
        }
        words.removeAll { word in FavoriteIdentity.normalize(word.headword) == key }
        count = words.count
        // Rebuilt rather than key-by-key: two favorites can share a reading
        // (有難う and ありがとう both read the same), and dropping the removed
        // row's key alone would strand the survivor's highlight.
        identity = FavoriteIdentity(words: words)
        revision += 1
        return .removed
    }

    /// Filtering and ordering stay the database's job, so they stay testable
    /// against a real file. A transient fault reads as no match. Empty-headword
    /// rows are dropped from the answer: the load deletes them from the file,
    /// but a row an older or parallel process writes underneath the store
    /// afterwards must not surface as an empty card.
    func search(_ query: String) -> [FavoriteWord] {
        let matches = (try? database.search(query)) ?? []
        return matches.filter { word in !word.headword.isEmpty }
    }
}
