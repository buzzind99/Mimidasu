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
        /// Whether this row came from the potential/passive unwrap fallback.
        /// Base lemma rows outrank unwrap rows when tier and commonness tie,
        /// and `assemble` drops unwrap rows outright when a base lemma
        /// survives filtering — the unwrap must never outrank the genuine
        /// base (入れる → 入る, くれる → くる).
        let isUnwrap: Bool

        init(
            entryID: Int, matchedField: DictionarySearchHit.MatchedField,
            matchKind: DictionarySearchHit.MatchKind, jlpt: Int?,
            matchedLength: Int, highlightRange: Range<Int>?,
            matchedGloss: String?, isUnwrap: Bool = false
        ) {
            self.entryID = entryID
            self.matchedField = matchedField
            self.matchKind = matchKind
            self.jlpt = jlpt
            self.matchedLength = matchedLength
            self.highlightRange = highlightRange
            self.matchedGloss = matchedGloss
            self.isUnwrap = isUnwrap
        }
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
    ///
    /// A search carrying `requiresExactCount` never reports this: its prefix
    /// scans run unbounded (`prefixUnboundedSQL`, no ceiling, no headroom
    /// trim), so every candidate row reaches the post-join filters and the
    /// total is exact.
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
        // A disabled group skips its stage outright: exact owns the lemma
        // retry too, which folds into `.exact`.
        let exactEnabled = filters.matchGroups.contains(.exact)
        let prefixEnabled = filters.matchGroups.contains(.prefix)
        let glossEnabled = filters.matchGroups.contains(.gloss)
        var rows: [CandidateRow] = []
        var saturated = false
        var truncated = false
        // Entry-level filters need an exact total the bounded scan cannot
        // give, so the stages below scan unbounded while they hold.
        let unbounded = filters.requiresExactCount
        // The three headword stages share one accumulator because they share one
        // question: not only which rows did this stage find, but did a bound of
        // its own hide any. Collecting the answer at the call site would let the
        // exact stage's `continue` silently drop it.
        func collect(_ label: String, _ candidates: [HeadwordCandidate]) throws {
            let scanned = try stage(label) { try headwordRows(candidates, db: db, unbounded: unbounded) }
            rows += scanned.rows
            truncated = truncated || scanned.truncated
        }
        if !exact.isEmpty, exactEnabled {
            try collect("exact", exact)
            // The pending tiers list only enabled groups: a disabled group's
            // tier can neither run nor displace the window, so it must not
            // hold the window open — nor let a full window claim to outrank it.
            saturated = capSaturated(rows, filters: filters, limit: limit, remaining: [
                prefixEnabled && !prefixes.isEmpty ? DictionarySearchHit.MatchKind.prefix.rawValue : nil,
                glossEnabled && glossEligible ? DictionarySearchHit.MatchKind.glossWordBoundary.rawValue : nil
            ].compactMap(\.self))
        }
        if !saturated, prefixEnabled, !prefixes.isEmpty {
            try collect("prefix", prefixes)
            saturated = capSaturated(rows, filters: filters, limit: limit, remaining: glossEnabled && glossEligible
                ? [DictionarySearchHit.MatchKind.glossWordBoundary.rawValue] : [])
        }
        // The lemma retry is the one stage gated on emptiness — see
        // `collectLemmaRetry` for the gate, the dual arms, and the
        // base-before-unwrap order. Lemma tier 1 is absent from the
        // `remaining` lists above by the same emptiness gate: a saturated
        // window implies in-scope rows, which already skip the retry.
        var lemmaState = LemmaRetryState(rows: rows, truncated: truncated, saturated: saturated)
        try collectLemmaRetry(
            normalized: normalized, filters: filters, db: db,
            state: &lemmaState, tokenize: tokenize
        )
        rows = lemmaState.rows
        truncated = lemmaState.truncated
        saturated = lemmaState.saturated
        if !saturated {
            saturated = capSaturated(rows, filters: filters, limit: limit, remaining: glossEnabled && glossEligible
                ? [DictionarySearchHit.MatchKind.glossWordBoundary.rawValue] : [])
        }
        if !saturated, glossEnabled, glossEligible {
            try checkCancellation()
            rows += try stage("gloss") { try glossRows(pattern: normalized, scope: filters.scope, db: db) }
        }
        return try stage("assemble") {
            try assemble(rows, filters: filters, db: db, saturated: saturated, truncated: truncated)
        }
    }

    /// The lemma retry: the one stage gated on emptiness. An inflected form
    /// only needs re-reading when nothing else found the word. It folds into
    /// `.exact`, so it is skipped when `.exact` is off or the window already
    /// saturated. The gate reads the pre-join scope predicate rather than the
    /// raw accumulator: rows that will all be filtered out of scope must not
    /// block the retry. Entry-level filters (`requiresExactCount`:
    /// common-only, JLPT, name types) are invisible pre-join, so a filtered
    /// search always runs the retry — mirroring `capSaturated`'s refusal.
    /// Romaji input lemmatizes through its converted kana: `tabetai`
    /// converts to たべたい, whose base たべる the headword probes never
    /// reach. The raw romaji is never tokenized and an unfinished spelling
    /// (`mak`) is not a word, so only a fully consumed conversion opens the
    /// romaji arm. Mixed-script runs both arms. The base probes run first
    /// and the potential unwrap only when they miss — a dictionary -える
    /// verb (入れる → 入る) must not outrank the genuine base. Under
    /// `requiresExactCount` both stages run pre-join (emptiness proves
    /// nothing there); `assemble` then drops unwrap rows when a base lemma
    /// survives filtering, and ranks any survivors base-first.
    /// The retry's mutable accumulator, passed as one parameter to respect
    /// the parameter-count budget.
    struct LemmaRetryState {
        var rows: [CandidateRow]
        var truncated: Bool
        /// Caller-owned: read once as the entry gate, written back unchanged.
        /// Saturation after the lemma stages is recomputed by the caller via
        /// `capSaturated`, so this retry never mutates it internally.
        var saturated: Bool
    }

    static func collectLemmaRetry(
        normalized: String, filters: DictionarySearchFilters,
        db: SQLiteDatabase, state: inout LemmaRetryState,
        tokenize: @Sendable (String) -> [DictionaryToken]?
    ) throws {
        guard !state.saturated, filters.matchGroups.contains(.exact) else { return }
        try checkCancellation()
        let retryUnbounded = filters.requiresExactCount
        let hasInScopeRows = state.rows.contains { row in filters.admits(entSeq: row.entryID) }
        guard filters.requiresExactCount || !hasInScopeRows else { return }
        let isJapanese = KanaClassification.containsJapanese(normalized)
        let conversions = romajiConversions(for: normalized).filter { conversion in
            conversion.fullyConsumed
        }
        guard isJapanese || !conversions.isEmpty else { return }
        func collect(_ label: String, _ candidates: [HeadwordCandidate], isUnwrap: Bool = false) throws {
            let scanned = try stage(label) {
                try headwordRows(candidates, db: db, unbounded: retryUnbounded)
            }
            // Names never lemmatize: a name has no dictionary form, so a
            // lemma probe that lands on a name row (a stem spray, a shared
            // spelling) is dropped rather than badged LEMMA. Exact-only
            // probes are primary-key seeks, so no scan bound is at stake.
            let kept = scanned.rows.filter { row in
                row.entryID < DictionaryContent.nameSeqOffset
            }
            if isUnwrap {
                state.rows += kept.map { row in
                    CandidateRow(
                        entryID: row.entryID, matchedField: row.matchedField,
                        matchKind: row.matchKind, jlpt: row.jlpt,
                        matchedLength: row.matchedLength, highlightRange: row.highlightRange,
                        matchedGloss: row.matchedGloss, isUnwrap: true
                    )
                }
            } else {
                state.rows += kept
            }
            state.truncated = state.truncated || scanned.truncated
        }
        let base = lemmaRetryCandidates(
            normalized: normalized, isJapanese: isJapanese,
            conversions: conversions, tokenize: tokenize, unwrapOnly: false
        )
        if !base.isEmpty {
            try collect("lemma", base)
        }
        let baseHit = state.rows.contains { row in filters.admits(entSeq: row.entryID) }
        guard filters.requiresExactCount || !baseHit else { return }
        try checkCancellation()
        let unwrap = lemmaRetryCandidates(
            normalized: normalized, isJapanese: isJapanese,
            conversions: conversions, tokenize: tokenize, unwrapOnly: true
        )
        if !unwrap.isEmpty {
            try collect("lemma-unwrap", unwrap, isUnwrap: true)
        }
    }

    /// The lemma retry's candidates for one stage: the Japanese arm reads the
    /// whole query, the romaji arm each hoisted conversion's kana, unioned and
    /// deduplicated by (probe, text). The base stage probes base + reading;
    /// the unwrap stage probes the potential/passive fallback alone, and the
    /// ladder only runs it when the base misses (or always under
    /// `requiresExactCount`, where pre-join emptiness proves nothing).
    static func lemmaRetryCandidates(
        normalized: String, isJapanese: Bool,
        conversions: [KanaRomaji.RomajiConversion],
        tokenize: @Sendable (String) -> [DictionaryToken]?,
        unwrapOnly: Bool
    ) -> [HeadwordCandidate] {
        var out: [HeadwordCandidate] = []
        var seen: Set<String> = []
        func add(_ candidates: [HeadwordCandidate]) {
            for candidate in candidates {
                let key = "\(candidate.probe.rawValue):\(candidate.text)"
                guard seen.insert(key).inserted else { continue }
                out.append(candidate)
            }
        }
        if isJapanese {
            if unwrapOnly {
                add(potentialUnwrapCandidates(for: normalized, tokenize: tokenize))
            } else {
                add(lemmaBaseCandidates(for: normalized, tokenize: tokenize))
            }
        }
        if !conversions.isEmpty {
            let probed = romajiProbedPairs(for: conversions)
            if unwrapOnly {
                add(romajiLemmaCandidates(for: conversions, probed: probed) { kana in
                    potentialUnwrapCandidates(for: kana, tokenize: tokenize)
                })
            } else {
                add(romajiLemmaCandidates(for: conversions, probed: probed) { kana in
                    lemmaBaseCandidates(for: kana, tokenize: tokenize)
                })
            }
        }
        return out
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
    /// The JLPT and name-type filters refuse for the same reason: their levels
    /// and badges need the `entries`/`senses` joins this probe cannot see.
    static func capSaturated(
        _ rows: [CandidateRow], filters: DictionarySearchFilters, limit: Int, remaining: [Int]
    ) -> Bool {
        guard !filters.requiresExactCount else { return false }
        guard let best = remaining.min() else { return false }
        // The window is the *ranked* top `limit`, so its worst row is the
        // worst tier among the best `limit` tiers — not the worst tier in
        // arrival order, which is what a plain `prefix(limit)` would read
        // and would under-report the moment a later stage contributes a tier
        // the earlier ones did not.
        let tiers = bestPerEntry(rows)
            .filter { entryID, row in
                filters.admits(entSeq: entryID) && filters.admits(matchKind: row.matchKind)
            }
            .values
            .map { row in row.matchKind.rawValue }
            .sorted()
        guard tiers.count >= limit, limit > 0 else { return false }
        return tiers[limit - 1] < best
    }

    /// The gloss stage's gate: Latin input only (Japanese input has already
    /// been searched as writing), long enough for a substring to mean
    /// something, and runnable at all — a platform with no FTS5 has no index
    /// to read, and the stage would abort the whole ladder on `no such table`.
    static func acceptsGlossQuery(
        _ query: String, fts5Available: Bool = JMDictFTSIndex.isAvailable
    ) -> Bool {
        guard fts5Available else { return false }
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
    ///
    /// `unbounded` lifts both bounds for searches carrying entry-level filters
    /// (`requiresExactCount`): prefix probes read `prefixUnboundedSQL` with no
    /// `LIMIT` and no ceiling bind, never set `truncated`, and keep every
    /// scanned row (still `shortestFirst`-ordered, untrimmed), so the post-join
    /// filters in `assemble` count exactly. Exact probes are untouched in both
    /// modes — a primary-key seek has no limit of its own and cannot truncate.
    static func headwordRows(
        _ candidates: [HeadwordCandidate], db: SQLiteDatabase, unbounded: Bool
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
                candidate.probe == .exact ? exactSQL : (unbounded ? prefixUnboundedSQL : prefixSQL)
            )
            if candidate.probe == .exact {
                statement.bind(candidate.text, at: 1)
            } else if unbounded {
                statement.bind(candidate.text, at: 1)
                statement.bind(candidate.text + scalarRangeCeiling, at: 2)
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
            if unbounded {
                // No bound ran, so nothing was hidden: keep every scanned row,
                // still shortest-first so the ranking meets them in the order
                // the headroom path would have kept.
                rows += shortestFirst(scanned)
                continue
            }
            // The scan's own ceiling reports as "reached", never as "not
            // reached": a range that happens to hold exactly `prefixScanCeiling`
            // rows is indistinguishable from one the `LIMIT` cut, and the false
            // positive runs the safe way — a `+` on a total that happened to be
            // exact — while the false negative would publish a truncated total
            // as the whole answer.
            truncated = truncated || count >= prefixScanCeiling
            // Shortest-first in both arms, not just the trimmed one: the
            // unbounded path sorts every scan, and `bestPerEntry` keeps the
            // first row on tier ties — so B-tree order here and sorted order
            // there would pick a different representative writing (and with
            // it a different highlight and JLPT level) for the same entry
            // depending on whether a filter forced the unbounded scan.
            let ordered = shortestFirst(scanned)
            guard ordered.count > prefixFetchHeadroom else {
                rows += ordered
                continue
            }
            truncated = true
            rows += Array(ordered.prefix(prefixFetchHeadroom))
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
}
