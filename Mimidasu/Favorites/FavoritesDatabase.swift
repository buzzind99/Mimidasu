import Foundation
import Synchronization

/// One SQLite file holding the user's starred words.
///
/// Sendable by construction, mirroring `JMDictLookup`: the only mutable state
/// is the lazily opened handle, held in a `Mutex`-guarded `State`, and every
/// query runs inside its `withLock` scope. Failing to open or to create the
/// schema is terminal for the instance — `degraded` — so a corrupt or
/// unwritable file degrades the feature instead of taking the app down. A
/// later operation that fails is *not* terminal: the handle stays open, so a
/// transient fault (a busy or full disk) costs one press rather than the list.
/// The one exception is `degrade()`, which makes an otherwise healthy instance
/// terminal at the store's request.
final class FavoritesDatabase: Sendable {
    enum Error: Swift.Error, Equatable {
        /// The database could not be opened or its schema created.
        case degraded
    }

    private enum State {
        case open(SQLiteDatabase)
        case degraded
    }

    private let state: Mutex<State>
    private static let schema = [
        """
        CREATE TABLE IF NOT EXISTS favorites (
            headword TEXT PRIMARY KEY NOT NULL,
            reading  TEXT,
            romaji   TEXT,
            added_at INTEGER NOT NULL
        )
        """,
        "CREATE INDEX IF NOT EXISTS favorites_recent ON favorites(added_at DESC)"
    ]

    /// `SQLITE_OPEN_CREATE` makes the *file*, not its parent directories, so
    /// the Application Support tree is created first — on a machine that has
    /// never downloaded a model or prepared a dictionary it does not exist,
    /// and favorites would otherwise never work on exactly the fresh install
    /// most likely to try the feature.
    init(location: URL) {
        let directory = location.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
            let db = try SQLiteDatabase.writable(path: location.path)
            for statement in Self.schema {
                try db.execute(statement)
            }
            state = Mutex(.open(db))
        } catch {
            print("favorites: database unavailable at \(location.path): \(error)")
            state = Mutex(.degraded)
        }
    }

    /// Makes the instance terminal-degraded at the store's request. The store
    /// calls this when its *initial load* fails: a transient fault on the first
    /// read would otherwise leave the handle answering a file the store's
    /// memory no longer mirrors — `isFavorite` denying rows that are on disk,
    /// the cap counting memory only. After this every operation reports
    /// `degraded`, which is the designed surface for a store that cannot be
    /// trusted.
    func degrade() {
        state.withLock { current in
            if case let .open(db) = current {
                db.close()
            }
            current = .degraded
        }
    }

    // MARK: - Mutations

    /// Adds a word, or leaves the existing row alone if its headword is
    /// already starred (the primary key makes the repeat a no-op).
    func insert(_ word: FavoriteWord) throws(Error) {
        try locked { db in
            let statement = try db.statement(
                "INSERT OR IGNORE INTO favorites (headword, reading, romaji, added_at) "
                    + "VALUES (:headword, :reading, :romaji, :added_at)"
            )
            statement.bind(word.headword, at: 1)
            statement.bind(word.reading ?? "", at: 2)
            statement.bind(word.romaji ?? "", at: 3)
            statement.bind(word.addedAt, at: 4)
            _ = try statement.step()
        }
    }

    func delete(headword: String) throws(Error) {
        try locked { db in
            let statement = try db.statement("DELETE FROM favorites WHERE headword = :headword")
            statement.bind(headword, at: 1)
            _ = try statement.step()
        }
    }

    // MARK: - Queries

    /// Every row, newest first.
    func all() throws(Error) -> [FavoriteWord] {
        try locked { db in
            try Self.rows(db.statement(Self.selectAllSQL))
        }
    }

    /// Rows whose headword, reading, or romaji contains `query`. An empty
    /// query returns everything, so the caller need not branch.
    ///
    /// `%`, `_`, and `\` in the query are escaped and `ESCAPE '\'` declared:
    /// without it a user typing `%` gets a wildcard. A nullable `reading` or
    /// `romaji` makes its `OR` arm NULL — not a match — and the remaining
    /// arms still decide the row.
    func search(_ query: String) throws(Error) -> [FavoriteWord] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return try all() }
        return try locked { db in
            let statement = try db.statement(Self.selectSearchSQL)
            statement.bind("%\(Self.escaped(trimmed))%", at: 1)
            return try Self.rows(statement)
        }
    }

    // MARK: - Core (mutex-held)

    private static let selectAllSQL =
        "SELECT headword, reading, romaji, added_at FROM favorites "
            + "ORDER BY added_at DESC, headword ASC"
    private static let selectSearchSQL =
        "SELECT headword, reading, romaji, added_at FROM favorites "
            + "WHERE headword LIKE :q ESCAPE '\\' "
            + "OR reading LIKE :q ESCAPE '\\' "
            + "OR romaji LIKE :q ESCAPE '\\' "
            + "ORDER BY added_at DESC, headword ASC"

    /// Runs one operation under the mutex, mapping every failure onto the single
    /// degradation case: a caller only needs to know the store did nothing.
    /// `Result` rather than a bare `rethrows` because `Mutex.withLock` throws
    /// untyped, which cannot cross a `throws(Error)` boundary.
    private func locked<T>(_ body: (SQLiteDatabase) throws -> T) throws(Error) -> T {
        let result: Result<T, Error> = state.withLock { current in
            guard case let .open(db) = current else { return .failure(.degraded) }
            do {
                return try .success(body(db))
            } catch {
                return .failure(.degraded)
            }
        }
        switch result {
        case let .success(value):
            return value
        case let .failure(error):
            throw error
        }
    }

    /// Drains a cursor into rows; the caller has already bound its parameters.
    private static func rows(_ statement: SQLiteDatabase.Statement) throws -> [FavoriteWord] {
        var words: [FavoriteWord] = []
        while try statement.step() {
            guard let headword = statement.optionalText(0) else { continue }
            words.append(FavoriteWord(
                headword: headword,
                reading: emptyToNil(statement.optionalText(1)),
                romaji: emptyToNil(statement.optionalText(2)),
                addedAt: statement.requiredInt(3)
            ))
        }
        return words
    }

    /// `SQLITE_OPEN_CREATE` and the schema allow NULL, but the writer stores
    /// "" for an absent reading or romaji (the statement binder is
    /// string-only), so empty reads back as nil — one representation in the
    /// model, whichever column it came from.
    private static func emptyToNil(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        return text
    }

    private static func escaped(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }
}
