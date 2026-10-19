import Foundation
import Synchronization

/// Read-only lookup engine over the prepared JMDict SQLite database
/// (`jmdict-<tag>.<rev>.sqlite`). Uses the system SQLite through `SQLiteDatabase` —
/// no new dependency — and every candidate resolves through an exact
/// `headwords.text = ?` hit on the build's B-tree index.
///
/// Sendable by construction: the only mutable state is the lazily opened
/// database, held in a `Mutex`-guarded `State`, and every query runs inside
/// its `withLock` scope.
final class JMDictLookup: Sendable {
    private enum State {
        case idle
        case open(SQLiteDatabase)
        case closed
    }

    private let state: Mutex<State>
    private let resolveDatabase: @Sendable () -> URL?

    /// Where the prepared JMDict database lives: the location `DictionaryStore`
    /// promotes into (repo-local `build/prepared/` in debug checkouts,
    /// Application Support in release), or — debug checkouts only — the
    /// uncompressed intermediate `scripts/build_dictionary.sh` leaves in `build/`.
    static var defaultDatabaseURL: URL? {
        defaultDatabaseURL(
            destination: DictionaryStore.defaultDestinationDirectory,
            fileExists: { url in FileManager.default.fileExists(atPath: url.path) }
        )
    }

    /// Injected core of `defaultDatabaseURL`: the prepared Application
    /// Support location first, then the debug checkout, then none.
    static func defaultDatabaseURL(
        destination: URL, fileExists: (URL) -> Bool
    ) -> URL? {
        let prepared = destination.appendingPathComponent(JMDictPin.preparedFileName)
        if fileExists(prepared) {
            return prepared
        }
        #if DEBUG
            let checkout = DictionaryStore.debugRepoURL(JMDictPin.debugCheckoutPath)
            if fileExists(checkout) {
                return checkout
            }
        #endif
        return nil
    }

    /// `resolveDatabase` is injectable for tests; the default resolves the
    /// prepared database location above. The mutex-guarded `State` opens the
    /// database lazily on the first query and keeps it warm; a failed open is
    /// never cached, so a later call retries naturally (the database may
    /// still be preparing). `close()` is permanent for this instance —
    /// subsequent queries throw `.databaseClosed`.
    init(resolveDatabase: @escaping @Sendable () -> URL? = { JMDictLookup.defaultDatabaseURL }) {
        self.resolveDatabase = resolveDatabase
        state = Mutex(.idle)
    }

    deinit {
        close()
    }

    // MARK: - Queries

    /// Looks up a single candidate as the tapped word itself; nil when
    /// nothing matches.
    func lookup(_ candidate: LookupCandidate) throws -> LookupResult? {
        let expansion = ExpansionCandidate(candidate: candidate, origin: .tappedSurface)
        guard case let .found(outcome) = try lookup([expansion]) else { return nil }
        return outcome.display
    }

    /// Resolves expansion candidates in order, classifying by origin: the
    /// tapped word's surface or lemma — or the join it leads — makes the
    /// found outcome (first hit displays; later hits adding new entries are
    /// retained as "also:", longest match first with ties keeping candidate
    /// order, and a candidate that only re-hits already-returned entries is
    /// redundant and skipped). A split can never lead: a tap whose first
    /// hit is a split resolves not-found, every split hit demoted to the
    /// related list (same redundancy rule — a hit only re-resolving known
    /// entries is skipped), longest match first. Every candidate missing →
    /// `.notFound(related: [])`; any infrastructure error aborts the whole
    /// lookup as a throw (never downgraded to a miss). Each candidate
    /// checks for cancellation before its indexed query, and each row
    /// drain checks per row — defensive today, since no caller cancels the
    /// detached tasks that run the engine, but a future caller that retains
    /// a task handle gets a prompt abort instead of a run to completion.
    /// Stale landings drop via the host generation guard; a cancelled query
    /// drops silently at its landing site.
    func lookup(_ candidates: [ExpansionCandidate]) throws -> LookupResolution {
        var display: LookupResult?
        var displayOrigin: ExpansionOrigin?
        var also: [LookupResult] = []
        var related: [LookupResult] = []
        var seenEntryIDs: Set<Int> = []
        for expansion in candidates {
            try Task.checkCancellation()
            guard let result = try lookupResult(for: expansion.candidate) else { continue }
            let entryIDs = Set(result.entries.map(\.entSeq))
            if display == nil, expansion.origin == .split {
                // Same redundancy rule as "also": a hit whose every entry
                // was already resolved is a duplicate pill, not new
                // information.
                if !entryIDs.isSubset(of: seenEntryIDs) {
                    related.append(result)
                }
            } else if display == nil {
                // Expansion order places every non-split candidate before
                // the splits, but a caller that violates it must not
                // silently drop the split hits already collected — fold them
                // into also so they survive as fallback pills rather than
                // vanishing. No redundancy rule on the fold, deliberately:
                // defensive path only, unreachable in production —
                // candidates emit surface/lemma/joins strictly before
                // splits, so `seenEntryIDs` is empty at the first non-split.
                if !related.isEmpty {
                    also.append(contentsOf: related)
                    related.removeAll()
                }
                display = result
                displayOrigin = expansion.origin
            } else if !entryIDs.isSubset(of: seenEntryIDs) {
                also.append(result)
            }
            seenEntryIDs.formUnion(entryIDs)
        }
        if let display, let displayOrigin {
            return .found(LookupOutcome(
                display: display, displayOrigin: displayOrigin,
                also: Self.longestFirst(also)
            ))
        }
        return .notFound(related: Self.longestFirst(related))
    }

    /// Longest match first, explicitly stable: candidates arrive in
    /// expansion order (longest-first joins, then splits), so equal lengths
    /// keep that order.
    private static func longestFirst(_ results: [LookupResult]) -> [LookupResult] {
        results.enumerated().sorted(using: [
            KeyPathComparator(\.element.matched.count, order: .reverse),
            KeyPathComparator(\.offset)
        ]).map(\.element)
    }

    /// Releases the database handle. The instance stays closed permanently —
    /// a testing seam for the closed-handle error path (the app never closes).
    func close() {
        state.withLock { current in
            if case let .open(database) = current {
                database.close()
            }
            current = .closed
        }
    }

    // MARK: - Reading fallback

    /// The kana reading of the best kanji-writing entry for `writing`, or nil
    /// when no kanji-writing headword matches. The annotator's fallback for
    /// kanji surfaces the tokenizer lexicon can't read (IPADIC has no
    /// standalone entry for 圧, 灼, … — they tokenize as unknown words with a
    /// `*` reading; JMDict covers them). Deliberately minimal — one indexed
    /// `headwords` hit plus one `entries` row, no sense fetching — ranked
    /// common-first then `ent_seq`, the same leading order the display lookup
    /// ranks to. The entry reading folds to hiragana so the fallback meets
    /// the annotator's kana contracts (IPADIC readings arrive hiragana via
    /// the runtime; KanaRomaji and the furigana alignment fold anyway).
    /// Throws on infrastructure failure; callers degrade to unannotated.
    func reading(forWriting writing: String) throws -> String? {
        do {
            return try state.withLock { current -> String? in
                let db = try openedDatabase(&current)
                let statement = try db.statement(Self.readingSQL)
                statement.bind(Self.probeText(writing), at: 1)
                guard try statement.step(), let reb = statement.optionalText(0) else {
                    return nil
                }
                return ReadingAlignment.foldedKana(reb)
            }
        } catch let error as SQLiteDatabase.Error {
            throw JMDictLookupError(error)
        }
    }

    /// Whether any headword row (kanji or kana spelling) matches `text` —
    /// the annotator's entry gate for long unknown segments, which must not
    /// fragment a surface JMDict/JMnedict actually covers (long katakana
    /// names the tokenizer lexicon lacks). Deliberately kind-free: a
    /// kana-written word carries only a `reb` row, so filtering on `keb`
    /// would misclassify it as entry-less. Throws on infrastructure
    /// failure; callers treat a throw as "has entry" (fail-safe: no
    /// fragmentation).
    func hasHeadword(_ text: String) throws -> Bool {
        do {
            return try state.withLock { current -> Bool in
                let db = try openedDatabase(&current)
                let statement = try db.statement(Self.headwordProbeSQL)
                statement.bind(Self.probeText(text), at: 1)
                return try statement.step()
            }
        } catch let error as SQLiteDatabase.Error {
            throw JMDictLookupError(error)
        }
    }

    // MARK: - Core (mutex-held)

    private func lookupResult(for candidate: LookupCandidate) throws -> LookupResult? {
        do {
            return try state.withLock { current -> LookupResult? in
                let db = try openedDatabase(&current)
                var rowByEntry: [Int: HeadwordRow] = [:]
                for row in try headwordRows(matching: Self.probeText(candidate.text), db: db)
                    where rowByEntry[row.entryID] == nil
                {
                    // Multiple headword rows can reference one entry (kanji and
                    // kana spellings coincide); the first row wins for JLPT/pitch.
                    rowByEntry[row.entryID] = row
                }
                var entries: [JMDictEntry] = []
                entries.reserveCapacity(rowByEntry.count)
                for (entSeq, row) in rowByEntry {
                    if let entry = try entry(
                        entSeq: entSeq, headword: row, candidate: candidate, db: db
                    ) {
                        entries.append(entry)
                    }
                }
                // An entry whose every sense was restriction-filtered away has
                // no displayable definition and contributes nothing.
                guard !entries.isEmpty else { return nil }
                // The tapped surface names the writing in context, so the entry
                // written the way the tap is written leads the pager (a kana
                // tap leads with the kana-only entry, a kanji tap with its own
                // kanji writing); the furigana names the reading, and
                // commonness and ent_seq break the remaining ties.
                let surface = ReadingAlignment.foldedKana(candidate.text)
                let expected = candidate.reading.map(ReadingAlignment.foldedKana)
                let ranked = entries.map { entry -> RankedEntry in
                    let matchesSurface = (entry.keb ?? entry.reb).map { writing in
                        ReadingAlignment.foldedKana(writing) == surface
                    } ?? false
                    let matchesReading: Bool = if let expected, let reb = entry.reb {
                        ReadingAlignment.foldedKana(reb) == expected
                    } else {
                        false
                    }
                    return RankedEntry(
                        surface: matchesSurface, reading: matchesReading, entry: entry
                    )
                }.sorted { lhs, rhs in
                    if lhs.surface != rhs.surface {
                        return lhs.surface
                    }
                    if lhs.reading != rhs.reading {
                        return lhs.reading
                    }
                    if lhs.entry.common != rhs.entry.common {
                        return lhs.entry.common
                    }
                    return lhs.entry.entSeq < rhs.entry.entSeq
                }
                return LookupResult(matched: candidate.text, entries: ranked.map(\.entry))
            }
        } catch let error as SQLiteDatabase.Error {
            throw JMDictLookupError(error)
        }
    }

    private struct HeadwordRow {
        let entryID: Int
        let jlpt: Int?
        let hatsuon: String?
        let accPatts: String?
        let zoPatts: String?
    }

    private struct RankedEntry {
        let surface: Bool
        let reading: Bool
        let entry: JMDictEntry
    }

    private func headwordRows(matching text: String, db: SQLiteDatabase) throws -> [HeadwordRow] {
        let statement = try db.statement(Self.headwordRowsSQL)
        statement.bind(text, at: 1)
        var rows: [HeadwordRow] = []
        while try statement.step() {
            try Task.checkCancellation()
            rows.append(HeadwordRow(
                entryID: statement.requiredInt(0),
                jlpt: statement.optionalInt(1),
                hatsuon: statement.optionalText(2),
                accPatts: statement.optionalText(3),
                zoPatts: statement.optionalText(4)
            ))
        }
        return rows
    }

    private func entry(
        entSeq: Int, headword: HeadwordRow, candidate: LookupCandidate, db: SQLiteDatabase
    ) throws -> JMDictEntry? {
        let entryStatement = try db.statement(Self.entrySQL)
        entryStatement.bind(entSeq, at: 1)
        guard try entryStatement.step() else {
            // A headword row always references an existing entry; a missing
            // parent is a corrupt database, not a miss — and never a
            // code-0 sqliteError (a clean SQLITE_DONE leaves "not an error"
            // in lastError, which mislabels the toast).
            throw JMDictLookupError.databaseCorrupt
        }
        let keb = entryStatement.optionalText(0)
        let reb = entryStatement.optionalText(1)
        let common = entryStatement.bool(2)

        let senses = try senses(entSeq: entSeq, candidate: candidate, db: db)
        if senses.isEmpty {
            return nil
        }
        return JMDictEntry(
            entSeq: entSeq,
            keb: keb,
            reb: reb,
            common: common,
            jlpt: headword.jlpt,
            hatsuon: headword.hatsuon,
            accPatts: headword.accPatts,
            zoPatts: headword.zoPatts,
            senses: senses
        )
    }

    private func senses(
        entSeq: Int, candidate: LookupCandidate, db: SQLiteDatabase
    ) throws -> [JMDictSense] {
        let statement = try db.statement(Self.senseSQL)
        statement.bind(entSeq, at: 1)
        var senses: [JMDictSense] = []
        while try statement.step() {
            try Task.checkCancellation()
            let pos = statement.optionalText(0)
            let glossText = statement.optionalText(1) ?? ""
            let misc = statement.optionalText(2)
            let restrictedKanji = Self.restrictedWritings(statement.optionalText(3))
            let restrictedKana = Self.restrictedWritings(statement.optionalText(4))
            let restricted = candidate.kind == .kanji ? restrictedKanji : restrictedKana
            if let restricted, !restricted.contains(Self.probeText(candidate.text)) {
                continue
            }
            let split: [String] = glossText.isEmpty
                ? [] : glossText.components(separatedBy: String(JMDictPin.glossJoiner))
            senses.append(JMDictSense(
                pos: pos,
                glosses: split,
                misc: misc,
                restrictedKanji: restrictedKanji,
                restrictedKana: restrictedKana
            ))
        }
        return senses
    }

    // MARK: - Database lifecycle (mutex-held)

    private func openedDatabase(_ current: inout State) throws -> SQLiteDatabase {
        switch current {
        case let .open(database):
            return database
        case .closed:
            throw JMDictLookupError.databaseClosed
        case .idle:
            break
        }
        guard let url = resolveDatabase(), FileManager.default.fileExists(atPath: url.path) else {
            throw JMDictLookupError.databaseMissing
        }
        let database: SQLiteDatabase
        do {
            database = try SQLiteDatabase(path: url.path)
        } catch let error as SQLiteDatabase.Error {
            switch error {
            case .unavailable:
                throw JMDictLookupError.sqliteError(code: -1, message: "failed to open JMDict database")
            case .sqlite:
                throw JMDictLookupError(error)
            }
        }
        current = .open(database)
        return database
    }

    // MARK: - SQL

    private static let readingSQL = """
    SELECT e.reb FROM entries e
    JOIN headwords h ON h.entry_id = e.ent_seq
    WHERE h.text = ? AND h.kind = 'keb'
    ORDER BY e.common DESC, e.ent_seq
    LIMIT 1
    """
    private static let headwordRowsSQL =
        "SELECT entry_id, jlpt, hatsuon, acc, zo FROM headwords WHERE text = ?"
    private static let headwordProbeSQL = "SELECT 1 FROM headwords WHERE text = ? LIMIT 1"
    private static let entrySQL = "SELECT keb, reb, common FROM entries WHERE ent_seq = ?"
    private static let senseSQL =
        "SELECT pos, gloss, misc, skeb, sreb FROM senses WHERE entry_id = ? ORDER BY ord"

    /// True NFKC of a probe input: halfwidth katakana and every other
    /// compatibility spelling fold onto the precomposed fullwidth forms the
    /// database stores, so all `text = ?` compares — headword rows, the
    /// sense-restriction lists, the reading fallback, the headword gate —
    /// answer a halfwidth tap identically to its fullwidth spelling (the
    /// annotator's gate vouching for a surface is never contradicted by the
    /// lookup on the same string). Applied at the SQL boundary only;
    /// candidates keep the surface the user tapped.
    private static func probeText(_ text: String) -> String {
        ReadingAlignment.compatibilityComposed(text)
    }

    /// Parses the build's `skeb`/`sreb` column: NULL = applies to every
    /// writing; otherwise a JSON array of writings (an empty array matches
    /// none — the build's defensive normalization). A stray `"*"` inside the
    /// array is honored as "every writing" as well.
    private static func restrictedWritings(_ raw: String?) -> [String]? {
        guard let raw, let data = raw.data(using: .utf8),
              let list = try? JSONDecoder().decode([String].self, from: data)
        else { return nil }
        return list.contains("*") ? nil : list
    }
}

extension JMDictLookupError {
    /// Maps a generic SQLite failure onto the lookup's typed error surface.
    /// The open path never routes an unopenable handle through here: a file
    /// that exists but fails to open reports `.sqliteError(code: -1, ...)`
    /// there, never `.databaseMissing` — missing stays reserved for a nil
    /// URL or an absent file. This mapping stays as-is for the reading and
    /// headword-probe paths, where `.unavailable` still reads as missing.
    init(_ error: SQLiteDatabase.Error) {
        switch error {
        case .unavailable:
            self = .databaseMissing
        case let .sqlite(code, message):
            self = .sqliteError(code: code, message: message)
        }
    }
}
