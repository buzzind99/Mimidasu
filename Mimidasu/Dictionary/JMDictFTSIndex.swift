import Foundation

/// The runtime FTS5 index over `senses.gloss`, built once per prepared database
/// and never shipped in the bundle.
///
/// The gloss stage used to answer Latin queries with
/// `WHERE gloss LIKE '%q%' ESCAPE '\'`, which no index can serve: SQLite's own
/// documentation states the FTS index is unusable for a `LIKE` carrying an
/// `ESCAPE` clause, and short of that the predicate is a full walk of all
/// 656,706 `senses` rows on every keystroke — measured at 25–69 ms per query,
/// including ~34 ms for a Names-scope search that returns nothing.
///
/// This is a **derived** artifact, not a new input. The bundled `.zst` is
/// unchanged; the index is built into the decompressed copy
/// (`DictionaryStore.prepareArtifact`) and lives only in Application Support, so
/// the bundle costs nothing. Nothing here runs on a database the app did not
/// just prepare.
enum JMDictFTSIndex {
    /// The virtual table's name. `sqlite_master` is probed for it both to build
    /// and to decide whether an already-prepared database carries the index.
    static let tableName = "gloss_fts"

    /// Trigram index, contentless, and no column sizes.
    ///
    /// Both tokenizer options are **pinned, not defaulted**, because the search
    /// depends on the exact fold they describe:
    ///
    /// - `case_sensitive 0` routes matching through SQLite's Unicode case fold,
    ///   which reaches rows the old `LIKE` could not: `LIKE` folds ASCII only,
    ///   and because `normalize` lowercases every query, the 35,714 sense rows
    ///   carrying uppercase non-ASCII (`École`, `ÉCOLE`) were unreachable from
    ///   *any* query. A default that ever changed would silently change recall.
    /// - `remove_diacritics 0` is verified off on the linked SQLite (3.54.0) —
    ///   `ecole` matches `École` under neither the index nor `LIKE`. It is
    ///   pinned anyway rather than trusted, because that default has moved
    ///   between SQLite releases and a version-dependent default is exactly the
    ///   silent divergence this index is meant to settle.
    ///
    /// `content=''` drops the duplicate copy of every gloss (measured 141 MB
    /// contentless vs 160 MB contentful on the pinned build) and `columnsize=0`
    /// because nothing calls `bm25()`. `detail` stays at its default `full`:
    /// `detail=none`/`column` reject any full-text query whose phrase is longer
    /// than three characters, which is every query worth running.
    static let createSQL = """
    CREATE VIRTUAL TABLE \(tableName) USING fts5(
      gloss,
      tokenize='trigram case_sensitive 0 remove_diacritics 0',
      content='', columnsize=0)
    """

    /// `rowid` carries `(entry_id, ord)`.
    ///
    /// A contentless table exposes nothing but `rowid`, so the pair needed to
    /// read a gloss back out of `senses` has to be encoded into it. `ord` needs
    /// 7 bits (the measured `MAX(ord)` is 26) and the stride is 128 rather than
    /// 64 purely because it is free — same int64 headroom, twice the room for
    /// senses per entry.
    static let insertSQL = """
    INSERT INTO \(tableName)(rowid, gloss)
    SELECT entry_id * \(ordStride) + ord, gloss FROM senses
    """

    /// Merges the index's b-trees. A measurable part of the build time and no
    /// effect on what the index answers.
    static let optimizeSQL = "INSERT INTO \(tableName)(\(tableName)) VALUES('optimize')"

    /// Clears any index already on the database before rebuilding.
    ///
    /// `build` normally runs against a freshly decompressed copy that has never
    /// carried one, so this matches nothing. It exists because `CREATE VIRTUAL
    /// TABLE` on an occupied name is an error, which would turn "this database
    /// has an index built from different constants" into a hard failure instead
    /// of the re-stage it is supposed to be. Production reaches `build` only
    /// through `DictionaryStore.prepareArtifact`'s staging window, never on a
    /// promoted path.
    static let dropSQL = "DROP TABLE IF EXISTS \(tableName)"

    /// The stride `insertSQL` encodes `ord` with. Changing it invalidates every
    /// `rowid` already written, so it is a schema-level constant and not a
    /// tuning knob.
    static let ordStride = 128

    /// `ordStride` as a shift, which is how SQL decodes the pair back out of a
    /// `rowid`. Derived from the stride and asserted against it, because the two
    /// disagreeing would silently read the wrong `ord` off every row.
    static let ordShift = 7

    /// The highest `ord` the encoding can represent. An entry with more senses
    /// than this would silently alias its `rowid`s onto other entries' and
    /// return another entry's gloss — wrong results with no error anywhere, so
    /// the build refuses instead (`guardMaxOrd`).
    static let maxEncodableOrd = ordStride - 1

    /// The highest `entry_id` the packed `rowid` can hold inside int64.
    /// Measured `MAX(entry_id)` on the pinned build is 19,999,990, which packs
    /// to ~2.56e9 — three orders of magnitude of headroom.
    static let maxPackableEntryID = Int64.max / Int64(ordStride)

    /// The build failed for a reason the caller must not paper over.
    ///
    /// Deliberately distinct from `SQLiteDatabase.Error`: the store treats a
    /// missing FTS5 as a soft degradation (the dictionary still works, the
    /// gloss stage does not), so it has to tell "this platform cannot build the
    /// index" apart from "this row would corrupt it".
    enum IndexError: Error, Equatable {
        /// The rowid encoding would alias: some entry carries more senses than
        /// `ordStride` can address. Fail the build; never write a wrong index.
        case senseCountOverflow(maxOrd: Int)
    }

    /// Builds the index over an already-decompressed, writable database.
    ///
    /// Called inside `DictionaryStore.prepareArtifact`'s staging window, on the
    /// temporary copy, before the smoke check and before the promote into
    /// Application Support. A failure here throws, the `defer` discards the
    /// staging directory, and the next launch retries from scratch — so a
    /// half-built index is never promotable.
    ///
    /// The stamp goes last. `isPresent` is what decides whether an already
    /// promoted database is adopted, and a stamp written before the rows were
    /// in would mark a partial index as current.
    static func build(at url: URL) throws {
        let database = try SQLiteDatabase.writable(path: url.path)
        defer { database.close() }
        assert(1 << ordShift == ordStride, "ordShift and ordStride must agree")
        try guardMaxOrd(db: database)
        try database.execute(dropSQL)
        try database.execute(createSQL)
        try database.execute(insertSQL)
        try database.execute(optimizeSQL)
        try database.execute(stampSQL)
    }

    /// Whether `url`'s database already carries **this** index.
    ///
    /// This is what makes adoption index-aware, and it is the second half of
    /// the self-heal for a database promoted before the index existed — such a
    /// database answers every Latin query with zero rows and no error, because
    /// the `LIKE` fallback is gone.
    ///
    /// Two conditions, not one. `sqlite_master` must carry the table *and* the
    /// database must carry the current `schemaVersion`. Name presence alone is
    /// not enough: the rowid pack, the tokenizer options and the contentless
    /// setting are all part of the index's contract with the `rowid >> 7` /
    /// `rowid & 127` decode in the search stage's statement, and an index built
    /// from a different version of those constants reports present while
    /// decoding the wrong `ord` off every row — wrong glosses, no error
    /// anywhere in the stack. A stamp is exact where matching the stored DDL
    /// text would be brittle against emitter formatting, and it covers a future
    /// core-schema change with the same re-prepare lever.
    ///
    /// The stamp cannot see a present-but-**empty** index, which is what
    /// `answers(at:)` is for. Both are needed.
    static func isPresent(at url: URL) -> Bool {
        guard let database = try? SQLiteDatabase(path: url.path) else { return false }
        defer { database.close() }
        guard let stamp = try? database.statement(schemaVersionSQL),
              (try? stamp.step()) == true,
              stamp.requiredInt(0) == schemaVersion,
              let presence = try? database.statement(presenceSQL)
        else { return false }
        return (try? presence.step()) == true
    }

    static let presenceSQL =
        "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = '\(tableName)'"

    /// Bumped whenever anything about the index's shape changes — the `rowid`
    /// pack, the tokenizer options, `content`/`columnsize`, the table name. A
    /// prepared database stamped with a different value is re-prepared rather
    /// than adopted, which is why this rides `user_version` (database-wide and
    /// stampable in one statement) instead of a comparison against the stored
    /// DDL text.
    static let schemaVersion = 1

    /// Written last, after `optimize`, so a database carrying the stamp has
    /// also had a complete build behind it.
    static let stampSQL = "PRAGMA user_version = \(schemaVersion)"

    static let schemaVersionSQL = "PRAGMA user_version"

    /// Whether this platform's SQLite can create an FTS5 table at all.
    ///
    /// The adoption check needs it: the build is deliberately **fail-soft** on a
    /// missing FTS5 (the dictionary is still usable, only Latin gloss search is
    /// not), which means a promoted database can legitimately have no index. If
    /// "no index" unconditionally meant "re-stage", such a platform would
    /// decompress and rebuild on every single launch forever. This is what
    /// separates "this database is missing an index it should have" from "this
    /// platform cannot have one".
    static let isAvailable: Bool = SQLiteDatabase.supportsFTS5

    /// Proves the index is not merely present but answering, before a staged
    /// database is promoted.
    ///
    /// A present-but-empty index is the failure this catches: it would pass a
    /// `sqlite_master` probe and then answer every query with zero rows, which
    /// looks exactly like "this word has no gloss". A row count cannot detect
    /// it — a contentless FTS5 table rejects `SELECT count(*)` outright
    /// (*"table does not support scanning"*) — so the probe is derived from the
    /// data itself: take a gloss that exists and ask the index for a trigram of
    /// it. A missing row, a partial build, or a tokenizer mismatch all answer
    /// zero, and any of them is exactly the silent failure worth refusing to
    /// promote over.
    ///
    /// The probe has to be one the index *can* answer, which shapes the pick
    /// two ways while leaving the corpus otherwise untouched — `probeSourceSQL`
    /// excludes glosses too short to form a trigram, and a quote in the gloss
    /// it lands on is neutralised at bind time by `phrase()` rather than
    /// forced out of the pick. Whitespace needs no filter here:
    /// the trigram tokenizer indexes every three-scalar window, whitespace
    /// included (probed on the pinned build — `'ab cd'` yields `ab␣`,
    /// `b␣c`, `␣cd`), and there is no shell here to strip a trailing newline
    /// the way the build scripts' command substitution does.
    static func answers(at url: URL) -> Bool {
        guard let database = try? SQLiteDatabase(path: url.path) else { return false }
        defer { database.close() }
        guard let source = try? database.statement(probeSourceSQL),
              (try? source.step()) == true,
              let gloss = source.optionalText(0),
              let probe = firstTrigram(of: gloss)
        else { return false }
        guard let match = try? database.statement(
            "SELECT 1 FROM \(tableName) WHERE \(tableName) MATCH ?1 LIMIT 1"
        ) else { return false }
        match.bind(phrase(probe), at: 1)
        return (try? match.step()) == true
    }

    /// One gloss the probe can actually be built from: its first three scalars
    /// have to exist.
    ///
    /// FTS5 answers a phrase shorter than three characters with zero rows and
    /// no error, so such a gloss could never stand in: `firstTrigram` cannot
    /// build a three-scalar phrase from it and `answers(at:)` — and the
    /// caller with it, as `smokeTestFailed` — fails on a perfectly healthy
    /// index.
    /// The corpus is not shy about them: 1,252 of the pinned build's 656,706
    /// `senses` gloss columns are one or two scalars long. They simply do not
    /// happen to be the `LIMIT 1` row, so this is a guard against a future
    /// corpus rather than a fix for a live failure. `length(substr(…, 1, 3))`
    /// rather than `length(gloss)` so the predicate means *at least* three
    /// scalars — the prefix `firstTrigram` takes — rather than exactly three.
    static let probeSourceSQL = """
    SELECT gloss FROM senses
    WHERE length(substr(gloss, 1, 3)) = 3
    LIMIT 1
    """

    /// The shortest thing the trigram tokenizer can express: the first three
    /// scalars of `gloss`.
    ///
    /// Three scalars of *any* script form a trigram — punctuation and
    /// whitespace are indexed too — so this needs no knowledge of the corpus
    /// and cannot pick a probe the index would legitimately not hold. The one
    /// shape it cannot answer is fewer than three scalars, which
    /// `probeSourceSQL` now filters out before this ever runs; the optional
    /// stays because a nil here is a refused promotion, not a trap.
    static func firstTrigram(of gloss: String) -> String? {
        let scalars = Array(gloss.unicodeScalars.prefix(3))
        guard scalars.count == 3 else { return nil }
        return String(String.UnicodeScalarView(scalars))
    }

    /// The build refuses rather than writing an index whose `rowid`s alias.
    ///
    /// Every gloss row's text has to be read back out of `senses` by primary
    /// key, so `rowid` is load-bearing: two senses colliding onto one `rowid`
    /// means the join returns the wrong entry's gloss, with no error raised
    /// anywhere in the stack. Measured `MAX(ord)` is 26 against a stride of
    /// 128, so this is a guard against a future corpus, not a live constraint.
    static func guardMaxOrd(db: SQLiteDatabase) throws {
        guard let statement = try? db.statement("SELECT MAX(ord) FROM senses"),
              (try? statement.step()) == true,
              let maxOrd = statement.optionalInt(0)
        else { return }
        guard maxOrd > maxEncodableOrd else { return }
        throw IndexError.senseCountOverflow(maxOrd: maxOrd)
    }

    /// The user's text as a literal FTS5 phrase.
    ///
    /// Inside a double-quoted phrase every metacharacter is already literal —
    /// `%`, `_`, `*`, `?`, `(`, `)`, `:` and the keyword words (`NEAR`, `AND`,
    /// `OR`, `NOT`) carry no meaning — so the only character needing care is
    /// the quote itself, which FTS5 escapes by doubling. That is what replaces
    /// `likeEscaped`, and it is verified rather than assumed: a query of `100%`
    /// or `a_b` matches literally, and neither opens a pattern.
    ///
    /// Anything shorter than three characters produces a phrase the trigram
    /// tokenizer cannot express, and FTS5 answers it with no rows and no error.
    /// `glossMinLatinLength` is what keeps that query from ever arriving.
    static func phrase(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
