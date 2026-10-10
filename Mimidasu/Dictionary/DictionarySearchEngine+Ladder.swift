import Foundation

/// Which of the two headword scans a candidate asks for: a single primary-key
/// seek, or a B-tree range scan over the prefix. The lemma retry probes both —
/// it is a lemma *tier*, not a third scan.
enum DictionarySearchProbe: String, Equatable {
    case exact
    case prefix
}

/// The ladder itself: the stage order and the bounded scans that turn
/// candidates into rows. Candidate construction lives in
/// `DictionarySearchEngine+Candidates.swift`; merging, the deferred `entries`
/// join, and ranking in `DictionarySearchEngine+Assemble.swift`.
extension DictionarySearchEngine {
    /// One headword probe. `text` is the writing to seek in `headwords.text`;
    /// `probe` says whether it is a single primary-key seek or a B-tree range
    /// scan; `matchKind` is the tier the hit lands in; `highlightScalars` is
    /// how much of the *typed* input the hit should light up.
    struct HeadwordCandidate: Equatable {
        let text: String
        let probe: DictionarySearchProbe
        let matchKind: DictionarySearchHit.MatchKind
        /// Zero means "no highlight" — the lemma retry matched something the
        /// user never typed, and the badge is the whole explanation (D10).
        let highlightScalars: Int
    }

    /// A hit before the deferred `entries` join. Everything here is known from
    /// `headwords`/`senses` alone, which is what lets one PK seek per
    /// candidate stand in for a join across thousands of rows.
    struct CandidateRow {
        let entryID: Int
        let matchedField: DictionarySearchHit.MatchedField
        let matchKind: DictionarySearchHit.MatchKind
        let jlpt: Int?
        /// Scalars of the matched writing. Ranking key 3: a tighter prefix
        /// (shorter headword) outranks a longer one that starts the same way.
        let matchedLength: Int
        /// Scalar offsets into the matched field, or nil when the row lights
        /// up nothing.
        let highlightRange: Range<Int>?
        /// The matched sense's gloss — gloss hits only. It leads the preview so
        /// the highlight always points into a string the row renders.
        let matchedGloss: String?
    }

    // MARK: - The ladder

    /// Runs every applicable stage and returns the ranked outcome for the window.
    ///
    /// The only early exit is **window saturation**: once the ranked list already
    /// holds `limit` rows whose worst tier outranks the best tier any remaining
    /// stage could produce, nothing left can change what is on screen. It fires
    /// immediately for a 1-mora query that saturates on exact hits — which is the
    /// rule *working*, skipping exactly the expensive single-mora prefix scan. It
    /// deliberately never fires on "found something": ambiguous inputs (`sake`,
    /// `gate`) would silently lose results that only a later stage finds.
    ///
    /// Saturation is measured against the *window*, which is what keeps it
    /// honest once the window grows: the rows a wider window would reveal are
    /// exactly the ones this rule declared invisible, so a deeper search runs
    /// the stage this one skipped and appends below the rows already on screen.
    /// It is also the only thing `limit` decides here — `assemble` builds every
    /// row the stages that ran found, so a window reached by paging rather
    /// than re-searched costs nothing at all.
    static func ladder(
        normalized: String,
        filters: DictionarySearchFilters,
        db: SQLiteDatabase,
        tokenize: @Sendable (String) -> [DictionaryToken]?,
        limit: Int
    ) throws -> DictionarySearchOutcome {
        let candidates = headwordCandidates(for: normalized)
        let exact = candidates.filter { candidate in candidate.probe == .exact }
        let prefixes = candidates.filter { candidate in candidate.probe == .prefix }
        let glossEligible = acceptsGlossQuery(normalized)
        var rows: [CandidateRow] = []
        var saturated = false
        if !exact.isEmpty {
            rows += try stage("exact") { try headwordRows(exact, db: db) }
            saturated = capSaturated(rows, filters: filters, limit: limit, remaining: [
                prefixes.isEmpty ? nil : DictionarySearchHit.MatchKind.prefix.rawValue,
                glossEligible ? DictionarySearchHit.MatchKind.glossWordBoundary.rawValue : nil
            ].compactMap(\.self))
        }
        if !saturated, !prefixes.isEmpty {
            rows += try stage("prefix") { try headwordRows(prefixes, db: db) }
            saturated = capSaturated(rows, filters: filters, limit: limit, remaining: glossEligible
                ? [DictionarySearchHit.MatchKind.glossWordBoundary.rawValue] : [])
        }
        // The lemma retry is the one stage gated on emptiness: an inflected
        // form only needs re-reading when nothing else found the word.
        if !saturated, rows.isEmpty, KanaClassification.containsJapanese(normalized) {
            let lemmas = lemmaCandidates(for: normalized, tokenize: tokenize)
            if !lemmas.isEmpty {
                rows += try stage("lemma") { try headwordRows(lemmas, db: db) }
            }
        }
        if !saturated, glossEligible {
            rows += try stage("gloss") { try glossRows(pattern: normalized, scope: filters.scope, db: db) }
        }
        return try stage("assemble") {
            try assemble(rows, filters: filters, db: db, saturated: saturated)
        }
    }

    /// Whether the requested window is already better than anything a remaining
    /// stage could add: a full window of hits, and the worst of them strictly
    /// outranking the best tier still pending.
    ///
    /// The window is counted in **entries**, through the same `bestPerEntry`
    /// merge and the same scope predicate `assemble` applies — not in the
    /// candidate rows the stages happened to produce. A prefix scan returns a
    /// row per writing, so one headword written several ways (or an entry the
    /// scan meets under both its kana and its kanji spelling) can contribute
    /// several rows to a screen that will render it once; counting rows made a
    /// half-empty screen read as full and skipped the gloss stage, which is how
    /// `best regards` came back as 42 prefix hits over 42 entries while its
    /// 74 rows tripped the cap — and the entry whose gloss reads "best regards"
    /// never ran at all.
    ///
    /// `commonOnly` is still absent, and must be: `common` does not exist
    /// before the `entries` join, so a common-only window can saturate on rows
    /// `assemble` will drop. That is a wasted stage, never a hidden one.
    static func capSaturated(
        _ rows: [CandidateRow], filters: DictionarySearchFilters, limit: Int, remaining: [Int]
    ) -> Bool {
        guard let best = remaining.min() else { return false }
        // The window is the *ranked* top `limit`, so its worst row is the
        // worst tier among the best `limit` tiers — not the worst tier in
        // arrival order, which is what a plain `prefix(limit)` would read
        // and would under-report the moment a later stage contributes a tier
        // the earlier ones did not.
        let tiers = bestPerEntry(rows)
            .filter { entryID, _ in filters.admits(entSeq: entryID) }
            .values
            .map { row in row.matchKind.rawValue }
            .sorted()
        guard tiers.count >= limit, limit > 0 else { return false }
        return tiers[limit - 1] < best
    }

    /// The gloss stage's gate: Latin input only (Japanese input has already
    /// been searched as writing), and long enough for a substring to mean
    /// something.
    static func acceptsGlossQuery(_ query: String) -> Bool {
        guard !KanaClassification.containsJapanese(query) else { return false }
        let latin = query.unicodeScalars.filter { scalar in
            scalar.isASCII && scalar.properties.isAlphabetic
        }.count
        return latin >= glossMinLatinLength
    }

    // MARK: - Stages

    /// Stage 4: a bounded `senses` scan with the scope predicate *in the SQL*.
    ///
    /// `senses` is WITHOUT ROWID keyed `(entry_id, ord)`, so a bare limit
    /// returns the lowest-`ent_seq` matches first — and name entries live at
    /// `ent_seq >= 10M`, above every JMDict row. Filtering afterwards would
    /// hand Words scope everything and Names scope nothing.
    static func glossRows(
        pattern: String, scope: DictionarySearchFilters.Scope, db: SQLiteDatabase
    ) throws -> [CandidateRow] {
        let statement = try db.statement(glossSQL(for: scope))
        statement.bind("%\(likeEscaped(pattern))%", at: 1)
        statement.bind(glossFetchCap, at: 2)
        var rows: [CandidateRow] = []
        var scanned = 0
        while try statement.step() {
            scanned += 1
            if scanned.isMultiple(of: scanCancelCheckInterval) {
                try checkCancellation()
            }
            let column = statement.optionalText(1) ?? ""
            // The build joins a sense's glosses into one column, so the tier and
            // the span have to be graded per *gloss*: `(hard) candy; toffee` is
            // a word-boundary match for `candy` and a bare substring for
            // `toffee`, and grading the column as a whole would grade both as
            // the weaker one.
            let match = glossMatch(pattern: pattern, column: column)
            rows.append(CandidateRow(
                entryID: statement.requiredInt(0),
                matchedField: .gloss,
                matchKind: match.kind,
                jlpt: nil,
                matchedLength: match.gloss.unicodeScalars.count,
                highlightRange: match.range,
                matchedGloss: match.gloss
            ))
        }
        return rows
    }

    /// The headword scans — stages 1, 2, and 3's retries — one candidate at a
    /// time: a primary-key seek for an exact candidate, a B-tree range scan for
    /// a prefix one.
    ///
    /// The prefix sort stays out of SQL deliberately. With a `LIMIT`, an
    /// `ORDER BY LENGTH(h.text)` makes SQLite temp-b-tree-sort the *whole*
    /// range before applying the limit — exactly the unbounded work
    /// `prefixScanCeiling` exists to prevent — so the survivors are sorted
    /// short-first in Swift afterwards. The fetch itself rides the primary
    /// key's BINARY order, which is the accepted alphabetical bias.
    ///
    /// The `kind` column comes off the row, which is what decides the
    /// highlight's field: a kana spelling never lights up the kanji writing,
    /// and a kana-only entry (no `keb` row at all) still highlights its
    /// reading.
    static func headwordRows(
        _ candidates: [HeadwordCandidate], db: SQLiteDatabase
    ) throws -> [CandidateRow] {
        assert(
            prefixFetchHeadroom <= prefixScanCeiling,
            "headroom above the scan ceiling truncates to the ceiling instead"
        )
        var rows: [CandidateRow] = []
        for candidate in candidates {
            try checkCancellation()
            let statement = try db.statement(
                candidate.probe == .exact ? exactSQL : prefixSQL
            )
            if candidate.probe == .exact {
                statement.bind(candidate.text, at: 1)
            } else {
                statement.bind(candidate.text, at: 1)
                statement.bind(candidate.text + scalarRangeCeiling, at: 2)
                statement.bind(prefixScanCeiling, at: 3)
            }
            var scanned: [CandidateRow] = []
            var count = 0
            while try statement.step() {
                count += 1
                if count.isMultiple(of: scanCancelCheckInterval) {
                    try checkCancellation()
                }
                let kindIndex: Int32 = candidate.probe == .exact ? 1 : 2
                scanned.append(headwordRow(
                    entryID: statement.requiredInt(0),
                    kind: statement.optionalText(kindIndex),
                    jlpt: statement.optionalInt(kindIndex + 1),
                    matchedText: candidate.probe == .exact
                        ? candidate.text
                        : (statement.optionalText(1) ?? candidate.text),
                    candidate: candidate
                ))
            }
            rows += candidate.probe == .exact
                ? scanned
                : Array(shortestFirst(scanned).prefix(prefixFetchHeadroom))
        }
        return rows
    }

    private static func headwordRow(
        entryID: Int,
        kind: String?,
        jlpt: Int?,
        matchedText: String,
        candidate: HeadwordCandidate
    ) -> CandidateRow {
        let isKanjiWriting = kind != "reb"
        return CandidateRow(
            entryID: entryID,
            matchedField: isKanjiWriting ? .keb : .reb,
            matchKind: candidate.matchKind,
            jlpt: jlpt,
            matchedLength: matchedText.unicodeScalars.count,
            highlightRange: candidate.highlightScalars > 0 ? 0 ..< candidate.highlightScalars : nil,
            matchedGloss: nil
        )
    }

    /// Shortest headword first, then lowest `ent_seq` — the deterministic half
    /// of ranking key 3 and 4, applied before the `common` join so a prefix
    /// scan's headroom keeps the rows that can actually win.
    static func shortestFirst(_ rows: [CandidateRow]) -> [CandidateRow] {
        rows.sorted { lhs, rhs in
            if lhs.matchedLength != rhs.matchedLength {
                return lhs.matchedLength < rhs.matchedLength
            }
            return lhs.entryID < rhs.entryID
        }
    }

    /// One matched gloss and the span inside it.
    struct GlossMatch {
        let gloss: String
        let range: Range<Int>?
        let kind: DictionarySearchHit.MatchKind
    }

    /// The best match inside a stored sense column: the tightest tier across
    /// its glosses, and the gloss that carried it — which is what the row will
    /// render, so the highlight always points into a string the user can see.
    ///
    /// `range(of:)` is the same case-insensitive fold the `LIKE` matched under,
    /// so a gloss it cannot locate is not a gloss the query reached. The
    /// fallback covers the pathological case where the fold disagrees with the
    /// collation: the row still matched, so it keeps its place without a
    /// highlight rather than dropping out of the results.
    static func glossMatch(pattern: String, column: String) -> GlossMatch {
        var best: GlossMatch?
        for gloss in glossList(column) {
            guard let range = MatchHighlight.range(of: pattern, in: gloss) else { continue }
            let kind = glossMatchKind(gloss: gloss, range: range)
            let match = GlossMatch(gloss: gloss, range: range, kind: kind)
            if best == nil || kind.rawValue < best?.kind.rawValue ?? .max {
                best = match
            }
        }
        if let best {
            return best
        }
        let scalars = column.unicodeScalars.count
        return GlossMatch(
            gloss: column,
            range: scalars == 0 ? nil : 0 ..< min(pattern.unicodeScalars.count, scalars),
            kind: .glossSubstring
        )
    }

    /// The gloss sub-tiers: a whole-word match first, then one starting the
    /// gloss, then a bare substring — `"to lose"` outranks `"closet"` for the
    /// query `lose`, which is the difference between a useful hit and noise.
    static func glossMatchKind(
        gloss: String, range: Range<Int>
    ) -> DictionarySearchHit.MatchKind {
        let scalars = Array(gloss.lowercased().unicodeScalars)
        guard range.lowerBound > 0 else {
            return range.upperBound == scalars.count
                ? .glossWordBoundary
                : .glossPrefix
        }
        let opensCleanly = !isWordScalar(scalars[range.lowerBound - 1])
        // A match at the very end of the gloss closes cleanly too.
        let closesCleanly = range.upperBound == scalars.count
            || !isWordScalar(scalars[range.upperBound])
        guard opensCleanly, closesCleanly else { return .glossSubstring }
        return .glossWordBoundary
    }

    private static func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
        Character(scalar).isLetter || Character(scalar).isNumber
    }
}
