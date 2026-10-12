import Foundation
import Synchronization

/// Full-dictionary search over the prepared JMDict SQLite database — the
/// ladder that answers one typed query, whatever script it arrived in.
///
/// Sendable by construction: the only mutable state is the lazily opened
/// read-only handle and the case-bearing spellings read from it, held in a
/// `Mutex`-guarded `State`, and every query runs inside its `withLock` scope.
/// The caller owns threading — the window runs `search` on a detached task
/// behind a debounce and drops stale landings with its own generation
/// counter.
final class DictionarySearchEngine: Sendable {

    // MARK: Tuning

    /// Rows one load-more step reveals — and, as the default `limit`, the rows
    /// the window asks for before anyone has asked for more. The top of a long
    /// result list is what the user reads first; the rest is one click away.
    static let pageSize = 50
    /// The most rows one query may hold open. A single-mora query matches tens
    /// of thousands of entries, and a list nobody stops scrolling is not a
    /// better answer than a ranked thousand — past this the footer says to
    /// refine the search instead.
    static let maxRows = 1000
    /// Prefix survivors kept per candidate for ranking. A 1-mora prefix scan
    /// can match thousands of headwords; keeping the shortest of them is what
    /// makes the tightest ones the ones on screen.
    ///
    /// The headroom truncates on `matchedLength`, a key that exists before the
    /// `entries` join, while `rank` leads with `common` — so a headroom below
    /// the scan's real population discards exactly the common entries the
    /// ranking would have promoted. Measured on a 1-mora query, doubling this
    /// lifts the common entries in the first screen by roughly half again, for
    /// single-digit milliseconds of `assemble` join time.
    ///
    /// Applies only when no entry-level filter is active: a search carrying
    /// `requiresExactCount` scans unbounded (`prefixUnboundedSQL`) and keeps
    /// every row, so its filtered total is exact rather than a floor.
    static let prefixFetchHeadroom = 8000
    /// Raw rows a prefix scan may touch before the fetch is cut. Without it a
    /// single-mora query walks the whole kana block on every keystroke.
    ///
    /// Applies only when no entry-level filter is active, like the headroom
    /// above — a filtered search (`requiresExactCount`) scans unbounded so no
    /// bound can hide rows from the post-join filters.
    static let prefixScanCeiling = 20000
    /// Shortest Latin query the gloss stage will answer.
    ///
    /// This is the trigram tokenizer's expressibility floor, not a quality
    /// preference — and that is why it cannot be relaxed. A trigram index
    /// cannot answer a one- or two-character phrase: FTS5 returns **no rows**
    /// for it, with no error and no warning. Measured against the real prepared
    /// database, query `Ma` matches 78,143 senses under the old `LIKE` scan and
    /// zero of them through the index — a silent, total loss of recall.
    ///
    /// The only way to answer a 1–2 character query would be to keep a full
    /// table `LIKE` scan alongside the index, which is the 25–69 ms walk this
    /// index exists to delete. The secondary argument still stands on its own —
    /// below three letters a substring match is mostly noise — but the tokenizer
    /// is the load-bearing reason, and `glossRows` asserts it.
    static let glossMinLatinLength = 3
    /// `IN`-clause chunk for the deferred `entries`/first-sense joins —
    /// SQLite's default bound-parameter limit is 999, so this stays well under.
    static let entryChunkSize = 500
    /// Rows between `Task.isCancelled` checks inside a drain loop. The engine
    /// runs synchronously on the caller's task, so this is what lets a
    /// keystroke's cancel abandon a 20k-row scan in milliseconds rather than
    /// letting the next keystroke queue behind it.
    static let scanCancelCheckInterval = 512

    /// The scalar appended to a prefix to form a B-tree range's exclusive
    /// upper bound. `headwords` is WITHOUT ROWID keyed `(text, entry_id, kind)`,
    /// so the table *is* a B-tree over `text` under BINARY collation and a
    /// range scan rides the key order directly.
    static let scalarRangeCeiling = "\u{10FFFF}"

    // MARK: Lifecycle

    /// The opened handle and the spellings read from it — one ladder
    /// parameter rather than two, because the two are opened together and
    /// always travel together.
    struct Open: Sendable {
        let db: SQLiteDatabase
        let caseHeadwords: CaseHeadwordSpellings
    }

    private enum State {
        case idle
        /// The read-only handle plus the spellings it carries: the case-bearing
        /// headwords are read once, beside the open, because they answer from
        /// memory and nothing else in the engine needs them.
        case open(SQLiteDatabase, CaseHeadwordSpellings)
        case closed
    }

    private let state: Mutex<State>
    private let resolveDatabase: @Sendable () -> URL?
    /// The tokenizer behind the lemma retry. Injectable so tests can drive the
    /// ladder without the dictionary dylib.
    private let tokenize: @Sendable (String) -> [DictionaryToken]?

    /// `resolveDatabase` defaults to the prepared location
    /// (`DictionaryStore.resolveJMDict`), so the search warms the same
    /// database the tap lookup reads — two independent read-only handles, both
    /// opened `SQLITE_OPEN_READONLY` with `PRAGMA query_only`. A failed open
    /// is never cached, so a later call retries naturally (the database may
    /// still be preparing). `close()` is permanent for this instance.
    init(
        resolveDatabase: @escaping @Sendable () -> URL? = { DictionaryStore.resolveJMDict() },
        tokenize: @escaping @Sendable (String) -> [DictionaryToken]? = { text in
            DictionaryEngine.shared.tokenize(text)
        }
    ) {
        self.resolveDatabase = resolveDatabase
        self.tokenize = tokenize
        state = Mutex(.idle)
    }

    deinit {
        close()
    }

    /// Releases the handle. The instance stays closed permanently — a testing
    /// seam for the closed-handle error path (the app never closes).
    func close() {
        state.withLock { current in
            if case let .open(database, _) = current {
                database.close()
            }
            current = .closed
        }
    }

    // MARK: Search

    /// Runs the ladder for `query` and returns the ranked rows plus the total
    /// behind them. Throws only for infrastructure failure — a query with no
    /// answer is an empty outcome, never an error.
    ///
    /// `limit` is the **window**: how many ranked rows the caller may *see*. It
    /// decides which stages may run and which may be skipped, because a stage
    /// is skipped only when its rows would rank below every row already in the
    /// window — and that stays true only for the window the caller asked for.
    ///
    /// It does **not** bound what comes back. The result is every row the
    /// stages that ran found (up to `maxRows`), because a row this search
    /// already has costs two lookups to build, while finding one costs a scan:
    /// the window is the caller's slice, not the engine's payload. `limit` is
    /// clamped to `maxRows`, so a window past the ceiling costs nothing to ask
    /// for and returns nothing more.
    ///
    /// Cancellation propagates as `CancellationError`: `search` runs
    /// synchronously on the caller's task, so throwing here releases the
    /// engine's mutex immediately instead of parking the next keystroke's
    /// search behind the abandoned scan.
    func search(
        _ query: String, filters: DictionarySearchFilters, limit: Int = pageSize
    ) throws -> DictionarySearchOutcome {
        let normalized = Self.normalize(query)
        guard !normalized.isEmpty else { return .empty }
        let window = min(max(limit, 0), Self.maxRows)
        do {
            return try state.withLock { current -> DictionarySearchOutcome in
                let open = try openedDatabase(&current)
                return try Self.ladder(
                    normalized: normalized, filters: filters, open: open,
                    tokenize: tokenize, limit: window
                )
            }
        } catch let error as SQLiteDatabase.Error {
            throw DictionarySearchError(error)
        }
    }

    /// The SQL boundary fold every probe shares: NFKC (halfwidth katakana and
    /// every other compatibility spelling onto the precomposed fullwidth form
    /// the database stores) then lowercase, so `MAKERU` and `Makeru` reach the
    /// same rows as `makeru` and an English gloss search is case-insensitive
    /// without a per-query `lower()` on the table.
    static func normalize(_ query: String) -> String {
        ReadingAlignment.compatibilityComposed(query)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    // MARK: - Database lifecycle (mutex-held)

    private func openedDatabase(_ current: inout State) throws -> Open {
        switch current {
        case let .open(database, spellings):
            return Open(db: database, caseHeadwords: spellings)
        case .closed:
            throw DictionarySearchError.databaseClosed
        case .idle:
            break
        }
        guard let url = resolveDatabase(), FileManager.default.fileExists(atPath: url.path) else {
            throw DictionarySearchError.databaseMissing
        }
        let database: SQLiteDatabase
        do {
            database = try SQLiteDatabase(path: url.path)
        } catch {
            throw DictionarySearchError(error)
        }
        // Read once, here, where the handle first exists: the case-bearing
        // spellings are 2,357 rows of the pinned corpus, answered by binary
        // search from here on. A database without `JMDictCaseIndex` — one
        // whose artifact regressed, since the index ships in it and the app
        // builds nothing — answers off a full scan of `headwords` (~100 ms)
        // on the first search, and never again.
        let spellings = try CaseHeadwordSpellings(db: database)
        current = .open(database, spellings)
        return Open(db: database, caseHeadwords: spellings)
    }
}

// MARK: - Cancellation

extension DictionarySearchEngine {
    /// The ladder's only early exit is cancellation. Every stage boundary and
    /// every drain loop checks it, because the scan that must die is the one
    /// the user already typed past.
    static func checkCancellation() throws {
        if Task.isCancelled {
            throw CancellationError()
        }
    }

    /// DEBUG per-stage timing, and nothing in release. This is the tripwire for
    /// the bounded-fetch decisions above: a stage that grows past its budget
    /// shows up here per keystroke, long before a user would call it slow.
    static func stage<T>(_ label: String, _ body: () throws -> T) rethrows -> T {
        #if DEBUG
            let started = ContinuousClock.now
            let value = try body()
            print("[dictionary-search] \(label): \(ContinuousClock.now - started)")
            return value
        #else
            return try body()
        #endif
    }
}
