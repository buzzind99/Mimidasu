import Foundation
import Synchronization

/// One SQLite file holding the session archive: one row per session, its
/// finalized sentences, and its translations.
///
/// Sendable by construction, mirroring `FavoritesDatabase`: the only mutable
/// state is the lazily opened handle, held in a `Mutex`-guarded `State`, and
/// every query runs inside its `withLock` scope. Failing to open or to create
/// the schema is terminal for the instance — `degraded` — so a corrupt or
/// unwritable file degrades the feature instead of taking the app down. A
/// later operation that fails is *not* terminal: the handle stays open, so a
/// transient fault costs one write rather than the list.
final class ArchiveDatabase: Sendable {
    enum Error: Swift.Error, Equatable {
        /// The database could not be opened or its schema created, or a
        /// later operation failed.
        case degraded
    }

    private enum State {
        case open(SQLiteDatabase)
        case degraded
    }

    private let state: Mutex<State>
    private static let schema = [
        """
        CREATE TABLE IF NOT EXISTS sessions (
            id           INTEGER PRIMARY KEY AUTOINCREMENT,
            status       TEXT NOT NULL,
            started_at   INTEGER NOT NULL,
            ended_at     INTEGER,
            duration_ms  INTEGER,
            paused_ms    INTEGER NOT NULL DEFAULT 0,
            target_lang  TEXT,
            model        TEXT,
            chunk_ms     INTEGER,
            saved        INTEGER NOT NULL DEFAULT 0,
            name         TEXT
        )
        """,
        """
        CREATE INDEX IF NOT EXISTS sessions_list
            ON sessions(saved, status, started_at DESC)
        """,
        """
        CREATE TABLE IF NOT EXISTS sentences (
            session_id   INTEGER NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
            idx          INTEGER NOT NULL,
            start_s      REAL NOT NULL,
            end_s        REAL NOT NULL,
            lang         TEXT NOT NULL,
            transcript   TEXT NOT NULL,
            PRIMARY KEY (session_id, idx)
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS translations (
            session_id   INTEGER NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
            idx          INTEGER NOT NULL,
            lang         TEXT NOT NULL,
            text         TEXT NOT NULL,
            engine       TEXT,
            PRIMARY KEY (session_id, idx, lang)
        )
        """,
        // Membership, so an added language persists before any translation
        // lands (unused until multi-language archive translation).
        """
        CREATE TABLE IF NOT EXISTS session_languages (
            session_id   INTEGER NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
            lang         TEXT NOT NULL,
            PRIMARY KEY (session_id, lang)
        )
        """
    ]

    /// `SQLITE_OPEN_CREATE` makes the *file*, not its parent directories, so
    /// the Application Support tree is created first — on a machine that has
    /// never downloaded a model or prepared a dictionary it does not exist,
    /// and the archive would otherwise never work on exactly the fresh
    /// install most likely to try the feature.
    init(location: URL) {
        let directory = location.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
            let db = try SQLiteDatabase.writable(path: location.path)
            // Cascade deletes are opt-in per connection; without this a
            // session delete would strand its sentences and translations.
            try db.execute("PRAGMA foreign_keys = ON")
            for statement in Self.schema {
                try db.execute(statement)
            }
            state = Mutex(.open(db))
        } catch {
            print("archive: database unavailable at \(location.path): \(error)")
            state = Mutex(.degraded)
        }
    }

    // MARK: - Session rows

    /// Whether the instance is terminal-degraded (open/schema failure):
    /// every write on it fails, which the store surfaces as "archive
    /// unavailable" rather than retrying per operation.
    var isDegraded: Bool {
        state.withLock { current in
            if case .degraded = current {
                return true
            }
            return false
        }
    }

    /// Inserts the `recording` session row and returns its id. Called with
    /// the first finalized sentence — an empty session never creates a row.
    func insertRecordingSession(
        startedAt: Date, targetLang: String?, model: String?, chunkMS: Int?
    ) throws(Error) -> Int64 {
        try locked { db in
            let statement = try db.statement(
                "INSERT INTO sessions (status, started_at, paused_ms, target_lang, model, chunk_ms, saved) "
                    + "VALUES ('recording', :started_at, 0, :target_lang, :model, :chunk_ms, 0)"
            )
            statement.bind(Int(startedAt.timeIntervalSince1970), at: 1)
            statement.bind(targetLang ?? "", at: 2)
            statement.bind(model ?? "", at: 3)
            statement.bind(chunkMS ?? 0, at: 4)
            _ = try statement.step()
            return db.lastInsertRowID()
        }
    }

    func insertSentence(sessionID: Int64, sentence: Sentence) throws(Error) {
        try locked { db in
            let statement = try db.statement(
                "INSERT OR REPLACE INTO sentences (session_id, idx, start_s, end_s, lang, transcript) "
                    + "VALUES (:session_id, :idx, :start_s, :end_s, :lang, :transcript)"
            )
            statement.bind(Int(sessionID), at: 1)
            statement.bind(sentence.index, at: 2)
            statement.bind(sentence.startS, at: 3)
            statement.bind(sentence.endS, at: 4)
            statement.bind(sentence.lang, at: 5)
            statement.bind(sentence.text, at: 6)
            _ = try statement.step()
        }
    }

    func upsertTranslation(
        sessionID: Int64, index: Int, translation: SentenceTranslation
    ) throws(Error) {
        try locked { db in
            let statement = try db.statement(
                "INSERT OR REPLACE INTO translations (session_id, idx, lang, text, engine) "
                    + "VALUES (:session_id, :idx, :lang, :text, :engine)"
            )
            statement.bind(Int(sessionID), at: 1)
            statement.bind(index, at: 2)
            statement.bind(translation.lang, at: 3)
            statement.bind(translation.text, at: 4)
            // The statement binder is string-only, so an absent engine
            // stores "" — read back as nil (one representation in the model).
            statement.bind(translation.engine?.rawValue ?? "", at: 5)
            _ = try statement.step()
        }
    }

    func updatePaused(sessionID: Int64, pausedMS: Int) throws(Error) {
        try locked { db in
            let statement = try db.statement(
                "UPDATE sessions SET paused_ms = :paused_ms WHERE id = :id"
            )
            statement.bind(pausedMS, at: 1)
            statement.bind(Int(sessionID), at: 2)
            _ = try statement.step()
        }
    }

    func finalize(
        sessionID: Int64, endedAt: Date, durationMS: Int, saved: Bool
    ) throws(Error) {
        try locked { db in
            let statement = try db.statement(
                "UPDATE sessions SET status = 'complete', ended_at = :ended_at, "
                    + "duration_ms = :duration_ms, saved = :saved WHERE id = :id"
            )
            statement.bind(Int(endedAt.timeIntervalSince1970), at: 1)
            statement.bind(durationMS, at: 2)
            statement.bind(saved ? 1 : 0, at: 3)
            statement.bind(Int(sessionID), at: 4)
            _ = try statement.step()
        }
    }

    /// Deletes the oldest finalized recents beyond `keeping`. Recents only:
    /// Saved rows and an in-flight `recording` row never count and are never
    /// evicted.
    func enforceRecentCap(keeping: Int) throws(Error) {
        try locked { db in
            let statement = try db.statement(
                "DELETE FROM sessions WHERE saved = 0 AND status != 'recording' "
                    + "AND id NOT IN ("
                    + "SELECT id FROM sessions WHERE saved = 0 AND status != 'recording' "
                    + "ORDER BY started_at DESC, id DESC LIMIT :keeping)"
            )
            statement.bind(keeping, at: 1)
            _ = try statement.step()
        }
    }

    /// Flips an abandoned `recording` row to `interrupted`, dating the end at
    /// now. Its duration is the last sentence's engine-relative end when no
    /// finalized duration exists: an interrupted session has no stop
    /// timestamp, so the last sentence's span is the honest reading.
    func sweepInterrupted(endedAt: Date) throws(Error) {
        try locked { db in
            let statement = try db.statement(
                "UPDATE sessions SET status = 'interrupted', ended_at = :ended_at, "
                    + "duration_ms = COALESCE(duration_ms, ("
                    + "SELECT CAST(MAX(end_s) * 1000 AS INTEGER) FROM sentences "
                    + "WHERE session_id = sessions.id)) "
                    + "WHERE status = 'recording'"
            )
            statement.bind(Int(endedAt.timeIntervalSince1970), at: 1)
            _ = try statement.step()
        }
    }

    /// Registers a language on the session. Idempotent: the language set is
    /// set-valued, and a re-add of an existing membership is a no-op.
    func insertLanguage(sessionID: Int64, lang: String) throws(Error) {
        try locked { db in
            let statement = try db.statement(
                "INSERT OR IGNORE INTO session_languages (session_id, lang) "
                    + "VALUES (:session_id, :lang)"
            )
            statement.bind(Int(sessionID), at: 1)
            statement.bind(lang, at: 2)
            _ = try statement.step()
        }
    }

    // MARK: - Reads

    /// Every finalized and interrupted session, newest first.
    func summaries() throws(Error) -> [ArchivedSessionSummary] {
        try locked { db in
            let statement = try db.statement(Self.summarySQL + " WHERE s.status != 'recording' "
                + "ORDER BY s.started_at DESC, s.id DESC")
            return try Self.summariesWithLanguages(statement, db: db)
        }
    }

    func summary(id: Int64) throws(Error) -> ArchivedSessionSummary? {
        try locked { db in
            // No status filter: the list is what excludes `recording` rows,
            // while a direct load by id (tests, and the opened archive's
            // refresh) reads whatever is stored.
            let statement = try db.statement(Self.summarySQL + " WHERE s.id = :id")
            statement.bind(Int(id), at: 1)
            return try Self.summariesWithLanguages(statement, db: db).first
        }
    }

    // MARK: - Mutations by id

    /// Stores the trimmed name; empty clears to nil (the auto-title).
    func rename(id: Int64, name: String?) throws(Error) {
        try locked { db in
            let statement = try db.statement("UPDATE sessions SET name = :name WHERE id = :id")
            statement.bind(name ?? "", at: 1)
            statement.bind(Int(id), at: 2)
            _ = try statement.step()
        }
    }

    func promote(id: Int64) throws(Error) {
        try locked { db in
            let statement = try db.statement("UPDATE sessions SET saved = 1 WHERE id = :id")
            statement.bind(Int(id), at: 1)
            _ = try statement.step()
        }
    }

    func delete(id: Int64) throws(Error) {
        try locked { db in
            let statement = try db.statement("DELETE FROM sessions WHERE id = :id")
            statement.bind(Int(id), at: 1)
            _ = try statement.step()
        }
    }

    // MARK: - Core (mutex-held)

    /// The shared summary projection: the session row's scalar columns plus
    /// its sentence count and first transcript (the auto-title snippet).
    private static let summarySQL = """
    SELECT s.id, s.status, s.saved, s.started_at, s.ended_at, s.duration_ms,
           s.target_lang, s.model, s.chunk_ms, s.name, s.paused_ms,
           (SELECT COUNT(*) FROM sentences WHERE session_id = s.id),
           (SELECT transcript FROM sentences WHERE session_id = s.id ORDER BY idx ASC LIMIT 1)
    FROM sessions s
    """

    /// Drains a summary cursor. `ended_at`-derived duration: a finalized row
    /// carries `duration_ms` (pause-excluded); a swept one may instead carry
    /// only the last sentence's end.
    private static func summaries(
        _ statement: SQLiteDatabase.Statement
    ) throws -> [ArchivedSessionSummary] {
        var summaries: [ArchivedSessionSummary] = []
        while try statement.step() {
            let status = statement.optionalText(1)
                .flatMap(ArchiveStatus.init(rawValue:)) ?? .complete
            summaries.append(ArchivedSessionSummary(
                id: Int64(statement.requiredInt(0)),
                status: status,
                saved: statement.bool(2),
                startedAt: Date(timeIntervalSince1970: TimeInterval(statement.requiredInt(3))),
                durationS: statement.optionalInt(5).map { durationMS in durationMS / 1000 },
                pausedMS: statement.requiredInt(10),
                sentenceCount: statement.requiredInt(11),
                targetLang: emptyToNil(statement.optionalText(6)),
                model: emptyToNil(statement.optionalText(7)),
                chunkMS: statement.optionalInt(8),
                name: emptyToNil(statement.optionalText(9)),
                firstSentence: emptyToNil(statement.optionalText(12))
            ))
        }
        return summaries
    }

    /// Loads one session's rows: sentences in index order, each translation
    /// folded in through `SessionEntry.replaceTranslation` so the joined
    /// display strings stay consistent with the live pipeline's.
    func entries(sessionID: Int64) throws(Error) -> [SessionEntry] {
        try locked { db in
            var entries: [SessionEntry] = []
            var positionByIndex: [Int: Int] = [:]
            let sentenceStatement = try db.statement(
                "SELECT idx, start_s, end_s, lang, transcript FROM sentences "
                    + "WHERE session_id = :session_id ORDER BY idx ASC"
            )
            sentenceStatement.bind(Int(sessionID), at: 1)
            while try sentenceStatement.step() {
                let sentence = Sentence(
                    index: sentenceStatement.requiredInt(0),
                    startS: sentenceStatement.requiredDouble(1),
                    endS: sentenceStatement.requiredDouble(2),
                    lang: sentenceStatement.optionalText(3) ?? "ja",
                    text: sentenceStatement.optionalText(4) ?? ""
                )
                positionByIndex[sentence.index] = entries.count
                entries.append(SessionEntry(sentence: sentence))
            }
            let translationStatement = try db.statement(
                "SELECT idx, lang, text, engine FROM translations WHERE session_id = :session_id"
            )
            translationStatement.bind(Int(sessionID), at: 1)
            while try translationStatement.step() {
                guard let index = translationStatement.optionalInt(0),
                      let position = positionByIndex[index],
                      let lang = translationStatement.optionalText(1),
                      let text = translationStatement.optionalText(2)
                else { continue }
                let engine = Self.emptyToNil(translationStatement.optionalText(3))
                    .flatMap(TranslationEngineKind.init(rawValue:))
                entries[position].replaceTranslation(
                    SentenceTranslation(lang: lang, text: text, engine: engine)
                )
            }
            return entries
        }
    }

    /// Runs one operation under the mutex, mapping every failure onto the
    /// single degradation case: a caller only needs to know the store did
    /// nothing. `Result` rather than a bare `rethrows` because
    /// `Mutex.withLock` throws untyped, which cannot cross a `throws(Error)`
    /// boundary.
    private func locked<T>(_ body: (SQLiteDatabase) throws -> T) throws(Error) -> T {
        let result: Result<T, Error> = state.withLock { current in
            guard case let .open(db) = current else { return .failure(.degraded) }
            do {
                return try .success(body(db))
            } catch {
                print("archive: database error: \(error)")
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

    /// The writer stores "" for absent text (the statement binder is
    /// string-only), so empty reads back as nil — one representation in the
    /// model, whichever column it came from.
    private static func emptyToNil(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        return text
    }
}

// MARK: - Language set (summary payload)

extension ArchiveDatabase {
    /// Drains a summary cursor and attaches each row's language set. The
    /// set's order: the stored target first (the default viewing language),
    /// then membership rows in add order, then translation-only languages
    /// (a phase-1 archive has no membership rows, but still lists whatever
    /// it was translated to).
    private static func summariesWithLanguages(
        _ statement: SQLiteDatabase.Statement, db: SQLiteDatabase
    ) throws -> [ArchivedSessionSummary] {
        var summaries = try summaries(statement)
        var targets: [Int64: String?] = [:]
        for summary in summaries {
            targets[summary.id] = summary.targetLang
        }
        let counts = try languageCounts(db: db, targets: targets)
        for index in summaries.indices {
            summaries[index].langs = counts[summaries[index].id] ?? []
        }
        return summaries
    }

    /// Two batched passes (membership rows, per-language translation counts)
    /// for a whole request, composed in Swift; the reads are small at
    /// archive scale, and a per-id variant would grow the prepared-statement
    /// cache with every distinct id set.
    private static func languageCounts(
        db: SQLiteDatabase, targets: [Int64: String?]
    ) throws -> [Int64: [ArchiveLanguageCount]] {
        var membership: [Int64: [String]] = [:]
        let membershipStatement = try db.statement(
            "SELECT session_id, lang FROM session_languages ORDER BY session_id, rowid"
        )
        while try membershipStatement.step() {
            guard let id = membershipStatement.optionalInt(0),
                  let lang = membershipStatement.optionalText(1), !lang.isEmpty
            else { continue }
            membership[Int64(id), default: []].append(lang)
        }
        var translated: [Int64: [ArchiveLanguageCount]] = [:]
        let countStatement = try db.statement(
            "SELECT session_id, lang, COUNT(*) FROM translations "
                + "GROUP BY session_id, lang ORDER BY session_id, MIN(rowid)"
        )
        while try countStatement.step() {
            guard let id = countStatement.optionalInt(0),
                  let lang = countStatement.optionalText(1), !lang.isEmpty
            else { continue }
            translated[Int64(id), default: []].append(
                ArchiveLanguageCount(lang: lang, translated: countStatement.requiredInt(2))
            )
        }
        var result: [Int64: [ArchiveLanguageCount]] = [:]
        for (id, target) in targets {
            var order: [String] = []
            if let target, !target.isEmpty {
                order.append(target)
            }
            for lang in membership[id] ?? [] where !order.contains(lang) {
                order.append(lang)
            }
            let counts = translated[id] ?? []
            for entry in counts where !order.contains(entry.lang) {
                order.append(entry.lang)
            }
            let countByLang = Dictionary(
                uniqueKeysWithValues: counts.map { entry in (entry.lang, entry.translated) }
            )
            result[id] = order.map { lang in
                ArchiveLanguageCount(lang: lang, translated: countByLang[lang] ?? 0)
            }
        }
        return result
    }
}
