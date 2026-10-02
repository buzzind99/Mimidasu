import Foundation
import SQLite3

/// `SQLITE_TRANSIENT` — SQLite's destructor constant is not exposed to Swift
/// directly; -1 instructs SQLite to copy the bound string immediately.
private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// A SQLite connection owning a prepared-statement cache — the only type in
/// the app that imports SQLite3. Engines drive it through `statement(_:)`
/// and the row accessors on `Statement`, so the raw C handle never escapes.
///
/// Thread-safety is the caller's concern: `JMDictLookup` and
/// `FavoritesDatabase` each serialize access under their own mutex, matching
/// the single-handle lifetime they manage. The `@unchecked Sendable` records
/// exactly that contract — the handle and the statement cache may only be
/// touched from the caller's locked scope.
final class SQLiteDatabase: @unchecked Sendable {
    enum Error: Swift.Error, Equatable {
        /// No handle could be created (an unopenable path).
        case unavailable
        /// SQLite reported an error code and message.
        case sqlite(code: Int32, message: String)
    }

    /// A prepared statement in a database's cache. Borrowed for one statement
    /// at a time; a repeat request resets the prior step and bindings.
    final class Statement {
        private let handle: OpaquePointer
        private let database: OpaquePointer

        fileprivate init(_ handle: OpaquePointer, database: OpaquePointer) {
            self.handle = handle
            self.database = database
        }

        /// Binds a string at the 1-based parameter `index`.
        func bind(_ value: String, at index: Int32) {
            sqlite3_bind_text(handle, index, value, -1, sqliteTransient)
        }

        /// Binds an integer at the 1-based parameter `index`.
        func bind(_ value: Int, at index: Int32) {
            sqlite3_bind_int64(handle, index, Int64(value))
        }

        /// Advances the statement: true on a row, false once done.
        func step() throws(Error) -> Bool {
            switch sqlite3_step(handle) {
            case SQLITE_ROW: return true
            case SQLITE_DONE: return false
            default: throw SQLiteDatabase.error(database)
            }
        }

        /// The 0-based column as text, or nil when NULL.
        func optionalText(_ index: Int32) -> String? {
            guard let cString = sqlite3_column_text(handle, index) else { return nil }
            return String(cString: cString)
        }

        /// The 0-based column as an integer, or nil when NULL.
        func optionalInt(_ index: Int32) -> Int? {
            guard sqlite3_column_type(handle, index) != SQLITE_NULL else { return nil }
            return Int(sqlite3_column_int64(handle, index))
        }

        /// The 0-based column as a non-optional integer (a NOT NULL column).
        func requiredInt(_ index: Int32) -> Int {
            Int(sqlite3_column_int64(handle, index))
        }

        /// The 0-based column as a Bool (nonzero = true).
        func bool(_ index: Int32) -> Bool {
            sqlite3_column_int(handle, index) != 0
        }
    }

    private let handle: OpaquePointer
    private var preparedStatements: [String: OpaquePointer] = [:]
    private var isClosed = false

    /// The only initializer that can carry write capability. Private so no
    /// caller can pass flags — a defaulted `init(path:access:)` would put
    /// `READWRITE` one keystroke away from the dictionary's call site.
    private init(opening path: String, flags: Int32) throws(Error) {
        var opened: OpaquePointer?
        guard sqlite3_open_v2(path, &opened, flags, nil) == SQLITE_OK,
              let opened
        else {
            let failure: Error = opened.map(Self.error) ?? .unavailable
            sqlite3_close_v2(opened)
            throw failure
        }
        handle = opened
    }

    /// Read-only. The dictionary's entry point — and every existing call
    /// site's. `query_only` is a second, independent lock: SQLite defines it
    /// as blocking all changes to database files regardless of the open
    /// flags, so a write against a prepared dictionary fails at the engine
    /// even if the flags were ever wrong.
    convenience init(path: String) throws(Error) {
        try self.init(opening: path, flags: SQLITE_OPEN_READONLY)
        do {
            try execute("PRAGMA query_only = 1")
        } catch {
            close()
            throw error
        }
    }

    /// The only route to a writable handle. Favorites own their database;
    /// the prepared dictionary must never be opened this way.
    static func writable(path: String) throws(Error) -> SQLiteDatabase {
        try SQLiteDatabase(opening: path, flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
    }

    deinit {
        close()
    }

    /// Returns the cached statement for `sql`, resetting any prior step and
    /// bindings; compiles it on first use (`sqlite3_prepare_v2` dominates a
    /// repeat query's cost). Callers fully consume each statement before
    /// returning, so reuse is safe.
    func statement(_ sql: String) throws(Error) -> Statement {
        if let cached = preparedStatements[sql] {
            sqlite3_reset(cached)
            sqlite3_clear_bindings(cached)
            return Statement(cached, database: handle)
        }
        var prepared: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &prepared, nil) == SQLITE_OK,
              let prepared
        else {
            throw Self.error(handle)
        }
        preparedStatements[sql] = prepared
        return Statement(prepared, database: handle)
    }

    /// Runs one statement that binds nothing (DDL, or a constant `PRAGMA`):
    /// prepare, step once, discard the row cursor. A step that reports no
    /// row is `SQLITE_DONE`, which for a write is success.
    func execute(_ sql: String) throws(Error) {
        let prepared = try statement(sql)
        _ = try prepared.step()
    }

    /// The connection's current error code and message.
    func lastError() -> Error {
        Self.error(handle)
    }

    /// Finalizes every cached statement and closes the handle. Idempotent, so
    /// an explicit close followed by deinit is safe.
    func close() {
        guard !isClosed else { return }
        isClosed = true
        for statement in preparedStatements.values {
            sqlite3_finalize(statement)
        }
        preparedStatements.removeAll()
        sqlite3_close_v2(handle)
    }

    private static func error(_ db: OpaquePointer) -> Error {
        .sqlite(
            code: sqlite3_errcode(db),
            message: String(cString: sqlite3_errmsg(db))
        )
    }
}
