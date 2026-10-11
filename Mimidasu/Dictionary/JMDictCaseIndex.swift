import Foundation

/// The derived index over the headwords that carry case, built once per
/// prepared database and never shipped in the bundle.
///
/// `CaseHeadwordSpellings` reads those spellings through `loadSQL`, and that
/// predicate has no index to ride: `headwords` is keyed
/// `(text, entry_id, kind)`, so without one the load walks the whole
/// 1,289,637-row B-tree, measured at ~100 ms. This index is that predicate, so
/// SQLite can serve the load as a scan of the 2,465 rows that satisfy it —
/// measured at 0.8 ms — for **57,344 bytes** on the pinned build and 114 ms to
/// build. The second load, `nonASCIICaseLoadSQL`, is a primary-key range scan
/// over 94 rows and needs no index at all.
///
/// A database without the index answers identically — the same rows off a
/// full `headwords` scan — so the index is only ever a speed-up for the
/// load. It is nonetheless adoption-load-bearing, exactly the way the
/// gloss index's stamp is: `DictionaryStore.isAdoptable` requires it, so a
/// database promoted before this index existed re-stages once instead of
/// staying on the slow path forever. What it does **not** carry is a
/// stamp: `user_version` belongs to the gloss build, and none is needed —
/// the DDL cannot drift (the range bounds live in the load, not the
/// index), so presence alone is a sound staleness key.
///
/// Same lifecycle as `JMDictFTSIndex`: built on the staged copy inside
/// `DictionaryStore.prepareArtifact`'s window, before the promote, so a
/// half-built index can never reach Application Support.
enum JMDictCaseIndex {
    /// The index's name, pinned in `scripts/build_dictionary.sh` because the
    /// dev artifact is built from a second copy of this DDL.
    static let indexName = "headwords_case"

    /// Partial on the **ASCII** load's own predicate and keyed on `text` alone,
    /// so it is **covering**: that load reads `text` and nothing else, and
    /// SQLite serves it as `SCAN headwords USING COVERING INDEX
    /// headwords_case`. The partial predicate must textually contain the load's
    /// for the planner to accept it, which is why `loadSQL` states the same
    /// comparison rather than a paraphrase.
    ///
    /// The key is still the raw `text`, deliberately. A key on `lower(text)`
    /// would serve folded range scans directly but would have to index all
    /// 1.29M rows (measured 57 KB for 2,465, and the folded form cannot be
    /// smaller), and it would put a second ordering beside the one every other
    /// stage rides. The engine answers from memory instead, so the index only
    /// ever has to make the load cheap.
    static let createSQL = """
    CREATE INDEX IF NOT EXISTS \(indexName) ON headwords(text)
    WHERE text <> lower(text)
    """

    /// The load, in two statements, because SQLite's fold and Swift's do not
    /// agree.
    ///
    /// `lower()` is SQLite's **ASCII-only** fold while `normalize` lowercases
    /// the full Unicode scalar range, so this predicate alone misses any
    /// spelling whose only case is non-ASCII. It is not hypothetical: on the
    /// pinned build it skips **26** headword rows — the JMnedict Greek-capital
    /// names `Α`, `Β`, `Γ`… and `Γ分布`/`Θ関数` — every one of which a query
    /// folding to `α`, `β`, `γ` cannot reach.
    ///
    /// The second statement is the catch-all, and it is a **range scan on the
    /// primary key** rather than another predicate: a spelling that needs
    /// catching has no ASCII case at all, so it opens in a block that carries
    /// case mapping, and `headwords` is ordered by `text`, so those spellings
    /// are contiguous. U+00C0…U+1FFF spans Latin-1 Supplement through Greek
    /// Extended — Latin extended, IPA, Greek, Cyrillic, Armenian, Georgian
    /// Mtavruli, Phonetic Extensions, Latin Extended Additional and Greek
    /// Extended.
    ///
    /// Together the two are a **superset** of what Swift's fold would select:
    /// 2,357 distinct spellings against the 2,289 that actually fold, the
    /// surplus being spellings already reachable by their own name. Carrying a
    /// few unused spellings costs nothing and cannot answer wrongly — a query
    /// matches a spelling only where the two folds actually agree.
    static let loadSQL = "SELECT DISTINCT text FROM headwords WHERE text <> lower(text)"

    static let nonASCIICaseFloor = "\u{00C0}"
    static let nonASCIICaseCeiling = "\u{1FFF}"

    static let nonASCIICaseLoadSQL = """
    SELECT DISTINCT text FROM headwords
    WHERE text >= '\(nonASCIICaseFloor)' AND text < '\(nonASCIICaseCeiling)'
    """

    static let presenceSQL =
        "SELECT 1 FROM sqlite_master WHERE type = 'index' AND name = '\(indexName)'"

    /// Builds the index over an already-decompressed, writable database.
    ///
    /// `IF NOT EXISTS` rather than the gloss index's drop-then-create: this one
    /// carries no rows of its own and no content that a rebuild could
    /// contradict, so an occupied name is the index this statement would have
    /// built, not a stale one to clear first.
    static func build(at url: URL) throws {
        let database = try SQLiteDatabase.writable(path: url.path)
        defer { database.close() }
        try database.execute(createSQL)
    }

    /// Whether `url`'s database already carries the index.
    ///
    /// Load-bearing through `DictionaryStore.isAdoptable`: a promoted database
    /// without the index is re-staged rather than adopted. Presence is the
    /// whole check — the DDL cannot drift (see the type doc), so unlike the
    /// gloss index there is no version to compare.
    static func isPresent(at url: URL) -> Bool {
        guard let database = try? SQLiteDatabase(path: url.path) else { return false }
        defer { database.close() }
        guard let presence = try? database.statement(presenceSQL) else { return false }
        return (try? presence.step()) == true
    }
}
