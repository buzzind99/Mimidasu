import Foundation

/// The derived index over the headwords that carry case, built by the
/// ingestion pipeline and shipped inside the bundled artifact.
///
/// `CaseHeadwordSpellings` reads those spellings through `loadSQL`, and that
/// predicate has no index to ride: `headwords` is keyed
/// `(text, entry_id, kind)`, so without one the load walks the whole
/// 1,289,637-row B-tree, measured at ~100 ms. This index is that predicate, so
/// SQLite can serve the load as a scan of the 2,465 rows that satisfy it —
/// measured at 0.8 ms — for **57,344 bytes** on the pinned build (~18 KB
/// compressed, measured against the shipped artifact). The second load,
/// `nonASCIICaseLoadSQL`, is a primary-key range scan over 94 rows and needs
/// no index at all.
///
/// A database without the index answers identically — the same rows off a
/// full `headwords` scan — so the index is only ever a speed-up for the
/// load. That is why its absence is a degradation the app tolerates rather
/// than a state it repairs: the index is built once by
/// `scripts/jmdict_build.py` from `createSQL` (the DDL source of truth,
/// mirrored and drift-guarded by `scripts/build_dictionary.sh`), and nothing
/// in the app writes it. Unlike the gloss index there is no stamp:
/// `user_version` belongs to the gloss build, and none is needed — the DDL
/// cannot drift (the range bounds live in the load, not the index), and the
/// versioned artifact filename is the staleness key that retires databases
/// from before the index shipped.
enum JMDictCaseIndex {
    /// The index's name, pinned in `scripts/build_dictionary.sh` because the
    /// ingestion build and the probes key on it.
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

    /// The catch-all range's bounds, chosen against the **shipped corpus** rather
    /// than against Unicode: it spans every block the pinned artifact needs (the
    /// JMnedict Greek-capital names live at U+0391) and, on the way, sweeps
    /// every case-bearing block that happens to sit below the ceiling —
    /// Cherokee (U+13A0) rides inside the scan — none of which the corpus
    /// carries a single row in. It stops short of the later case-bearing
    /// scripts — among them Glagolitic (U+2C00), Adlam (U+1E900) and Deseret
    /// (U+10400); Coptic, Latin Extended-C/D, Old Hungarian, Cherokee's
    /// lowercase block (U+AB70) and others lie beyond it too. Widening past
    /// them is not a correctness fix for this load, it is a range scan over
    /// more of the B-tree; a corpus that ever does carry one turns
    /// `DictionarySearchEngineLiveTests.caseSetCoversEveryCaseFoldedSpelling`
    /// red, which is the tripwire that raises the ceiling on purpose.
    static let nonASCIICaseFloor = "\u{00C0}"
    static let nonASCIICaseCeiling = "\u{1FFF}"

    static let nonASCIICaseLoadSQL = """
    SELECT DISTINCT text FROM headwords
    WHERE text >= '\(nonASCIICaseFloor)' AND text < '\(nonASCIICaseCeiling)'
    """
}
