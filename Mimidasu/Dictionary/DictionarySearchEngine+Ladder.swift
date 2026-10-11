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

    /// One headword stage's rows, and whether one of that stage's own bounds
    /// cut them.
    ///
    /// Reported apart from saturation because the two are not the same fact. A
    /// stage the *window* skipped is undone by a wider window; a bound the
    /// *scan* hit is not undone by anything — `prefixScanCeiling` and
    /// `prefixFetchHeadroom` are constants, so a deeper search re-runs the same
    /// scan and reaches the same bound. Only the first is worth a re-search;
    /// both are worth a floor on the total.
    struct HeadwordRows {
        let rows: [CandidateRow]
        let truncated: Bool
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
        open: Open,
        tokenize: @Sendable (String) -> [DictionaryToken]?,
        limit: Int
    ) throws -> DictionarySearchOutcome {
        let db = open.db
        let candidates = headwordCandidates(for: normalized, caseHeadwords: open.caseHeadwords)
        let exact = candidates.filter { candidate in candidate.probe == .exact }
        let prefixes = candidates.filter { candidate in candidate.probe == .prefix }
        let glossEligible = acceptsGlossQuery(normalized)
        var rows: [CandidateRow] = []
        var saturated = false
        var truncated = false
        // The three headword stages share one accumulator because they share one
        // question: not only which rows did this stage find, but did a bound of
        // its own hide any. Collecting the answer at the call site would let the
        // exact stage's `continue` silently drop it.
        func collect(_ label: String, _ candidates: [HeadwordCandidate]) throws {
            let scanned = try stage(label) { try headwordRows(candidates, db: db) }
            rows += scanned.rows
            truncated = truncated || scanned.truncated
        }
        if !exact.isEmpty {
            try collect("exact", exact)
            saturated = capSaturated(rows, filters: filters, limit: limit, remaining: [
                prefixes.isEmpty ? nil : DictionarySearchHit.MatchKind.prefix.rawValue,
                glossEligible ? DictionarySearchHit.MatchKind.glossWordBoundary.rawValue : nil
            ].compactMap(\.self))
        }
        if !saturated, !prefixes.isEmpty {
            try collect("prefix", prefixes)
            saturated = capSaturated(rows, filters: filters, limit: limit, remaining: glossEligible
                ? [DictionarySearchHit.MatchKind.glossWordBoundary.rawValue] : [])
        }
        // The lemma retry is the one stage gated on emptiness: an inflected
        // form only needs re-reading when nothing else found the word.
        if !saturated, rows.isEmpty, KanaClassification.containsJapanese(normalized) {
            let lemmas = lemmaCandidates(for: normalized, tokenize: tokenize)
            if !lemmas.isEmpty {
                try collect("lemma", lemmas)
            }
        }
        if !saturated, glossEligible {
            rows += try stage("gloss") { try glossRows(pattern: normalized, scope: filters.scope, db: db) }
        }
        return try stage("assemble") {
            try assemble(rows, filters: filters, db: db, saturated: saturated, truncated: truncated)
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
    /// `commonOnly` refuses the measurement outright. `common` does not exist
    /// before the `entries` join, so the window counted here is not the window
    /// `assemble` will render: a common-only search can saturate on hundreds
    /// of rows and then drop every one the window was full of. Skipping a
    /// stage on that basis hides rows — and since the headword stages ignore
    /// `limit`, a wider window re-measures the same rows and saturates
    /// identically, so paging could not un-skip it. A common-only search runs
    /// the remaining stage instead, and publishes no floor it cannot honour.
    static func capSaturated(
        _ rows: [CandidateRow], filters: DictionarySearchFilters, limit: Int, remaining: [Int]
    ) -> Bool {
        guard !filters.commonOnly else { return false }
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

    /// Stage 4: the FTS5 trigram index over `senses.gloss`, with the scope
    /// predicate *in the SQL*.
    ///
    /// The gloss text comes back through a **join**, not a per-row lookup. A
    /// contentless FTS table exposes only `rowid`, so the `(entry_id, ord)` pair
    /// has to be decoded and the gloss re-read from `senses` — and the shape of
    /// that re-read is the whole cost of the stage. Done one primary-key seek at
    /// a time it measured 434 ms for `ing` against the real prepared database,
    /// each seek an independent B-tree descent. Expressed as a single join, FTS5
    /// emits matching rowids ascending, `senses` is therefore read in primary
    /// key order, and the same rows cost 33 ms. Same rows, same order, 13×
    /// cheaper.
    ///
    /// Scope rides the rowid range rather than the `entry_id` predicate: with
    /// `rowid = entry_id * 128 + ord` the JMnedict boundary is exactly
    /// `DictionaryContent.nameSeqOffset * 128`, so one statement covers all
    /// three scopes and the predicate still rides the scan. Filtering
    /// afterwards instead would pay the read-back for every out-of-scope row —
    /// a `.names` query streaming the entire word block — and `assemble` would
    /// discard all of it. `assemble`'s `admits(entSeq:)` stays as the second,
    /// independent check; neither alone is enough.
    static func glossRows(
        pattern: String, scope: DictionarySearchFilters.Scope, db: SQLiteDatabase
    ) throws -> [CandidateRow] {
        assert(
            pattern.unicodeScalars.count >= glossMinLatinLength,
            "the trigram index silently answers nothing below three characters"
        )
        let bounds = glossRowIDBounds(for: scope)
        let statement = try db.statement(glossSQL)
        statement.bind(JMDictFTSIndex.phrase(pattern), at: 1)
        statement.bind(bounds.lower, at: 2)
        statement.bind(bounds.upper, at: 3)
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

    /// The inclusive `rowid` range a scope's sense rows occupy.
    ///
    /// The pack is `entry_id * JMDictFTSIndex.ordStride + ord`, so the
    /// `ent_seq` boundary becomes a constant comparison on the rowid itself and
    /// needs no second statement. `.all` is unbounded on both ends, which FTS5
    /// reads as "no constraint" — not as a scan of everything.
    static func glossRowIDBounds(
        for scope: DictionarySearchFilters.Scope
    ) -> (lower: Int, upper: Int) {
        let boundary = DictionaryContent.nameSeqOffset * JMDictFTSIndex.ordStride
        return switch scope {
        case .all: (0, Int.max)
        case .words: (0, boundary)
        case .names: (boundary, Int.max)
        }
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
    ///
    /// `truncated` is what keeps those two bounds honest. A 1-mora prefix scan
    /// matches tens of thousands of headwords and the headroom keeps 8000 of
    /// them, so a search that reports the survivors it kept as though they were
    /// the answer is publishing a floor with nothing marking it as one — `ma`
    /// read `10402` where the true count is 21532. Both bounds are reported,
    /// and both are constants, so the flag is not something a wider window can
    /// clear.
    static func headwordRows(
        _ candidates: [HeadwordCandidate], db: SQLiteDatabase
    ) throws -> HeadwordRows {
        assert(
            prefixFetchHeadroom <= prefixScanCeiling,
            "headroom above the scan ceiling truncates to the ceiling instead"
        )
        var rows: [CandidateRow] = []
        var truncated = false
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
            guard candidate.probe == .prefix else {
                // An exact seek has no limit of its own, so it cannot truncate.
                rows += scanned
                continue
            }
            // The scan's own ceiling reports as "reached", never as "not
            // reached": a range that happens to hold exactly `prefixScanCeiling`
            // rows is indistinguishable from one the `LIMIT` cut, and the false
            // positive runs the safe way — a `+` on a total that happened to be
            // exact — while the false negative would publish a truncated total
            // as the whole answer.
            truncated = truncated || count >= prefixScanCeiling
            guard scanned.count > prefixFetchHeadroom else {
                rows += scanned
                continue
            }
            truncated = true
            rows += Array(shortestFirst(scanned).prefix(prefixFetchHeadroom))
        }
        return HeadwordRows(rows: rows, truncated: truncated)
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
    /// every occurrence in every gloss, and the occurrence that carried it —
    /// what the row will render, so the highlight points at what it ranks.
    ///
    /// The fold here is the same case fold the gloss index's tokenizer
    /// applies, so a gloss it cannot locate is not a gloss the query
    /// reached. That agreement is no longer incidental — the index folds case
    /// across the whole Unicode range, so a row can match the index on a case
    /// difference the fold must then reproduce — and it is asserted against
    /// the real prepared database rather than assumed. The fallback covers the
    /// pathological case where the two folds still disagree: the row keeps its
    /// place without a highlight rather than dropping out of the results.
    static func glossMatch(pattern: String, column: String) -> GlossMatch {
        let byteCount = column.utf8.count
        // The fast path offsets into the *folded* text and then slices the
        // *original*, which only lines up when one scalar is one byte: then the
        // fold cannot change the count either, so a scalar offset is a byte
        // offset and a byte offset is a character offset. `K` (U+212A) is the
        // trap — it is not ASCII but folds to one, so testing the folded text
        // for ASCII would wrongly admit it; the column's own byte width is what
        // settles it. Everything else — an accented character, `İ` — takes the
        // fragment-wise path, which derives its text from the column itself and
        // so cannot get this wrong. 36,413 of 656,706 senses (5.5%); among the
        // rows a dense query reaches, `ing`, it is 389 of 52,172 (0.7%).
        guard byteCount == column.unicodeScalars.count else {
            return glossMatchByFragment(pattern: pattern, column: column)
        }
        let scalars = Array(column.lowercased().unicodeScalars)
        let needle = Array(pattern.lowercased().unicodeScalars)
        guard !scalars.isEmpty, !needle.isEmpty, scalars.count >= needle.count else {
            return glossMatchFallback(pattern: pattern, column: column)
        }

        var bestKind: DictionarySearchHit.MatchKind?
        var bestRange: Range<Int>?
        var bestBounds: Range<Int>?
        var fragmentStart = 0
        while fragmentStart < scalars.count, bestKind != .glossWordBoundary {
            let fragmentEnd = separatorStart(in: scalars, from: fragmentStart) ?? scalars.count
            // The build writes the gloss joiner between glosses and nothing
            // else, so a fragment's bounds end at that scalar — and trimming
            // its edges is a pair of walks, where `glossList` allocated a
            // substring for every one of the ~85,000 glosses a one-mora query
            // reaches.
            var lower = fragmentStart
            var upper = fragmentEnd
            while lower < upper, CharacterSet.whitespaces.contains(scalars[lower]) {
                lower += 1
            }
            while upper > lower, CharacterSet.whitespaces.contains(scalars[upper - 1]) {
                upper -= 1
            }
            fragmentStart = min(fragmentEnd + 1, scalars.count)

            // Every occurrence inside the fragment is graded, not just the
            // leftmost: in `iced (e.g. iced tea` the first `iced` opens the
            // gloss while the second stands alone — the occurrence that earns
            // the tier lends its span, so the highlight points at what ranks.
            var position = lower
            while let start = nextOccurrence(
                of: needle, in: scalars, within: lower ..< upper, from: position
            ) {
                let lowerBound = start - lower
                let upperBound = lowerBound + needle.count
                let kind = glossMatchKind(
                    scalars: scalars,
                    range: lowerBound ..< upperBound,
                    length: upper - lower,
                    offset: lower
                )
                // Only the winner's text is materialised. Every row the index
                // matches used to build a `String` here, to serve the thousand rows
                // `assemble` actually shows.
                if kind.rawValue < bestKind?.rawValue ?? .max {
                    bestKind = kind
                    bestRange = lowerBound ..< upperBound
                    bestBounds = lower ..< upper
                }
                // The best tier there is, and ties keep the first: nothing
                // later in the column can change the answer.
                if kind == .glossWordBoundary {
                    break
                }
                position = start + 1
            }
        }
        guard let bestKind, let bestRange, let bestBounds else {
            return glossMatchFallback(pattern: pattern, column: column)
        }
        return GlossMatch(
            // One scalar is one byte and one character here, so the scalar
            // bounds the scan produced are character bounds — a native
            // substring, not a re-encode. The two ends are the whole column
            // for most rows, and are taken without a walk.
            gloss: String(column[
                (bestBounds.lowerBound == 0 ? column.startIndex
                    : column.index(column.startIndex, offsetBy: bestBounds.lowerBound))
                    ..< (bestBounds.upperBound == scalars.count ? column.endIndex
                        : column.index(column.startIndex, offsetBy: bestBounds.upperBound))
            ]),
            range: bestRange,
            kind: bestKind
        )
    }

    /// The original fragment-wise grading, occurrence-wise like the fast path,
    /// kept for the columns whose fold changes their scalar offsets.
    private static func glossMatchByFragment(pattern: String, column: String) -> GlossMatch {
        let needle = Array(pattern.lowercased().unicodeScalars)
        guard !needle.isEmpty else {
            return glossMatchFallback(pattern: pattern, column: column)
        }
        var best: GlossMatch?
        fragment: for gloss in glossList(column) {
            let scalars = Array(gloss.lowercased().unicodeScalars)
            var position = 0
            while let start = nextOccurrence(
                of: needle, in: scalars, within: 0 ..< scalars.count, from: position
            ) {
                let range = start ..< (start + needle.count)
                let kind = glossMatchKind(
                    scalars: scalars, range: range, length: scalars.count, offset: 0
                )
                let match = GlossMatch(gloss: gloss, range: range, kind: kind)
                if best == nil || kind.rawValue < best?.kind.rawValue ?? .max {
                    best = match
                }
                if kind == .glossWordBoundary {
                    break fragment
                }
                position = start + 1
            }
        }
        return best ?? glossMatchFallback(pattern: pattern, column: column)
    }

    /// A column whose fold reproduced none of its glosses. The hit keeps its
    /// place, spanned by the pattern's own length.
    private static func glossMatchFallback(pattern: String, column: String) -> GlossMatch {
        let scalars = column.unicodeScalars.count
        return GlossMatch(
            gloss: column,
            range: scalars == 0 ? nil : 0 ..< min(pattern.unicodeScalars.count, scalars),
            kind: .glossSubstring
        )
    }

    /// The first gloss joiner at or after `start`, or nil when the column ends
    /// first.
    private static func separatorStart(
        in scalars: [Unicode.Scalar], from start: Int
    ) -> Int? {
        scalars[start...].firstIndex(of: JMDictPin.glossJoiner)
    }

    /// The first position at or after `start` where `needle` sits within
    /// `bounds`, or nil.
    private static func nextOccurrence(
        of needle: [Unicode.Scalar],
        in scalars: [Unicode.Scalar],
        within bounds: Range<Int>,
        from start: Int
    ) -> Int? {
        var index = start
        while index + needle.count <= bounds.upperBound {
            if scalars[index ..< (index + needle.count)].elementsEqual(needle) {
                return index
            }
            index += 1
        }
        return nil
    }

    /// The gloss sub-tiers: a whole-word match first, then one starting the
    /// gloss, then a bare substring — `"to lose"` outranks `"closet"` for the
    /// query `lose`, which is the difference between a useful hit and noise.
    static func glossMatchKind(
        gloss: String, range: Range<Int>
    ) -> DictionarySearchHit.MatchKind {
        let scalars = Array(gloss.lowercased().unicodeScalars)
        return glossMatchKind(scalars: scalars, range: range, length: scalars.count, offset: 0)
    }

    /// The same grading against an already-folded scalar array, for a caller
    /// grading several fragments of one column out of a single array.
    ///
    /// `range` is relative to the matched gloss, but `scalars` is the whole
    /// column, so `offset` is where that gloss starts — the two are what keep
    /// the neighbour lookups pointing at the characters around the match
    /// instead of at the start of the column.
    private static func glossMatchKind(
        scalars: [Unicode.Scalar], range: Range<Int>, length: Int, offset: Int
    ) -> DictionarySearchHit.MatchKind {
        guard range.lowerBound > 0 else {
            return range.upperBound == length
                ? .glossWordBoundary
                : .glossPrefix
        }
        let opensCleanly = !isWordScalar(scalars[offset + range.lowerBound - 1])
        // A match at the very end of the gloss closes cleanly too.
        let closesCleanly = range.upperBound == length
            || !isWordScalar(scalars[offset + range.upperBound])
        guard opensCleanly, closesCleanly else { return .glossSubstring }
        return .glossWordBoundary
    }

    private static func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
        Character(scalar).isLetter || Character(scalar).isNumber
    }
}
