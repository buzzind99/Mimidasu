import Foundation

/// Merging, the deferred `entries` join, ranking, and hit construction.
///
/// The order is load-bearing and it is why the join is split in two. Ranking
/// key #2 is `common`, which lives in `entries` — so a row cannot be ranked
/// until its entry has been read, and yet the expensive part of that read (the
/// `headwords` LEFT JOIN for the JLPT level) buys nothing the ranking uses.
/// So `commonFlags` fetches the one ranking column for every survivor as a
/// bare primary-key lookup, the window is cut from the ranking, and only the
/// rows on screen pay for the full join.
extension DictionarySearchEngine {
    /// The `entries` metadata a hit needs, fetched in bulk once the stages have
    /// said which entries they actually hit.
    struct EntryMetadata {
        let entSeq: Int
        let keb: String?
        let reb: String?
        let common: Bool
        /// The level carried by the entry's own kanji writing. `senses` has no
        /// JLPT column, so a gloss-stage candidate arrives without one and
        /// reads the level here instead — which is why this is metadata rather
        /// than something only the headword stages collect.
        let jlpt: Int?
    }

    /// A candidate row joined to its entry, ready to decorate.
    struct RankedRow {
        let row: CandidateRow
        let metadata: EntryMetadata
    }

    /// A candidate row paired with the single `entries` column the ranking
    /// reads. Everything `rank` needs, and nothing else — so it can be built
    /// for all survivors before the window is cut.
    struct ScoredRow {
        let entryID: Int
        let row: CandidateRow
        let common: Bool
    }

    /// Merge, filter, rank, bound, join, and decorate.
    ///
    /// The sequence is load-bearing: scope filters pre-join (a predicate on
    /// `ent_seq` alone), `commonOnly` filters on the pre-fetched flag, and the
    /// window is cut *before* the `headwords` join — every input to the ranking
    /// decision is available pre-join, so cutting there is lossless and skips
    /// the join for every row that will not be shown.
    ///
    /// Note what is *not* here: the caller's window. Every row the stages
    /// found is ranked and counted, up to `maxRows` built — the window is the
    /// UI's slice (`DictionarySearchState.visibleHits`), and building a row
    /// costs a couple of dictionary lookups against rows this search already
    /// holds. What costs a search is the scans, which happen upstream of this
    /// file.
    static func assemble(
        _ rows: [CandidateRow],
        filters: DictionarySearchFilters,
        db: SQLiteDatabase,
        saturated: Bool,
        truncated: Bool
    ) throws -> DictionarySearchOutcome {
        let survivors = bestPerEntry(rows)
            .filter { entryID, _ in filters.admits(entSeq: entryID) }
        let flags = try commonFlags(for: survivors.keys.sorted(), db: db)
        let scored = survivors.compactMap { entryID, row in
            flags[entryID].map { common in
                ScoredRow(entryID: entryID, row: row, common: common)
            }
        }
        let kept = filters.commonOnly
            ? rank(scored.filter { scored in scored.common })
            : rank(scored)
        // Every ranking key is decided above, so the window is cut here and the
        // `headwords` join runs for these rows alone.
        let window = Array(kept.prefix(Self.maxRows))
        let metadata = try entryMetadata(for: window.map(\.entryID), db: db)
        let built = window.compactMap { scored in
            metadata[scored.entryID].map { meta in RankedRow(row: scored.row, metadata: meta) }
        }
        let previews = try firstSenseGlosses(for: built.map(\.metadata.entSeq), db: db)
        let nameTypes = try namePosTokens(for: built, db: db)
        let hits = built.map { ranked in
            hit(
                for: ranked,
                preview: preview(for: ranked.row, firstSense: previews),
                nameTypes: nameTypes[ranked.metadata.entSeq] ?? []
            )
        }
        return DictionarySearchOutcome(
            hits: hits, matchedCount: kept.count,
            saturated: saturated, truncated: truncated
        )
    }

    /// One row per entry: the best tier wins, and with it that tier's field
    /// and highlight span. Ties keep the first row the stages produced, so the
    /// same query always produces the same order.
    static func bestPerEntry(_ rows: [CandidateRow]) -> [Int: CandidateRow] {
        var best: [Int: CandidateRow] = [:]
        for row in rows {
            guard let existing = best[row.entryID] else {
                best[row.entryID] = row
                continue
            }
            if row.matchKind.rawValue < existing.matchKind.rawValue {
                best[row.entryID] = row
            }
        }
        return best
    }

    /// The full rank, in order: tier, then commonness, then how tight the
    /// matched text is, then `ent_seq`.
    ///
    /// The last key is not cosmetic — without a total order the same query
    /// could reshuffle its rows between two keystrokes, and a list that moves
    /// under the cursor is worse than one that is merely alphabetical. It is
    /// also what makes the uncapped path safe to truncate: `bestPerEntry` has
    /// already collapsed to one row per entry, so the key is unique and the
    /// window is a deterministic prefix.
    /// Commonness descending sinks names in All scope on its own, since
    /// JMnedict entries are never common.
    static func rank(_ rows: [ScoredRow]) -> [ScoredRow] {
        rows.sorted { lhs, rhs in
            if lhs.row.matchKind != rhs.row.matchKind {
                return lhs.row.matchKind.rawValue < rhs.row.matchKind.rawValue
            }
            if lhs.common != rhs.common {
                return lhs.common
            }
            if lhs.row.matchedLength != rhs.row.matchedLength {
                return lhs.row.matchedLength < rhs.row.matchedLength
            }
            return lhs.entryID < rhs.entryID
        }
    }

    // MARK: - Deferred joins

    /// `entries.common` alone, in `IN`-clause chunks — the pre-join pre-fetch
    /// that lets the window be cut before the expensive join.
    ///
    /// No `headwords` LEFT JOIN and no text columns: this is a bare
    /// primary-key lookup per survivor, measured at ~0.55 µs/row against the
    /// real prepared database, where the full `entryMetadata` join over the same
    /// survivors costs several times more and returns metadata for rows the
    /// window will never show.
    static func commonFlags(
        for entSeqs: [Int], db: SQLiteDatabase
    ) throws -> [Int: Bool] {
        var out: [Int: Bool] = [:]
        for chunk in chunks(entSeqs, size: entryChunkSize) {
            let statement = try db.statement(commonFlagsSQL(count: chunk.count))
            bind(chunk, to: statement)
            while try statement.step() {
                out[statement.requiredInt(0)] = statement.bool(1)
            }
        }
        return out
    }

    /// `entries` metadata in `IN`-clause chunks. A search can reach a few
    /// thousand survivors; chunking keeps every statement inside SQLite's bound
    /// parameter limit, and each chunk is a run of primary-key seeks.
    static func entryMetadata(
        for entSeqs: some Sequence<Int>, db: SQLiteDatabase
    ) throws -> [Int: EntryMetadata] {
        var out: [Int: EntryMetadata] = [:]
        for chunk in chunks(Array(entSeqs), size: entryChunkSize) {
            let statement = try db.statement(entriesSQL(count: chunk.count))
            bind(chunk, to: statement)
            while try statement.step() {
                let entSeq = statement.requiredInt(0)
                out[entSeq] = EntryMetadata(
                    entSeq: entSeq,
                    keb: statement.optionalText(1),
                    reb: statement.optionalText(2),
                    common: statement.bool(3),
                    jlpt: statement.optionalInt(4)
                )
            }
        }
        return out
    }

    /// The first sense's glosses per entry — the preview line's text for every
    /// hit that was not found by its own gloss. Ordered by `ord` so the lowest
    /// `ord` per entry is simply the first row seen; the build's gloss joiner
    /// is split back into individual glosses here.
    static func firstSenseGlosses(
        for entSeqs: [Int], db: SQLiteDatabase
    ) throws -> [Int: [String]] {
        var out: [Int: [String]] = [:]
        for chunk in chunks(entSeqs, size: entryChunkSize) {
            let statement = try db.statement(firstSenseSQL(count: chunk.count))
            bind(chunk, to: statement)
            while try statement.step() {
                let entryID = statement.requiredInt(0)
                guard out[entryID] == nil else { continue }
                out[entryID] = glossList(statement.optionalText(1) ?? "")
            }
        }
        return out
    }

    /// Every sense's raw `pos` column per name entry, in sense order — what
    /// `DictionaryContent.nameTypeBadges(posTokens:)` maps to badges. Names
    /// only: a word search (the overwhelming majority) asks for nothing, and a
    /// name entry with no tagged sense contributes no key, so the UI renders
    /// no type badges rather than an empty claim.
    static func namePosTokens(
        for ranked: [RankedRow], db: SQLiteDatabase
    ) throws -> [Int: [String?]] {
        let nameIDs = ranked.compactMap { row -> Int? in
            row.metadata.entSeq >= DictionaryContent.nameSeqOffset ? row.metadata.entSeq : nil
        }
        guard !nameIDs.isEmpty else { return [:] }
        var out: [Int: [String?]] = [:]
        for chunk in chunks(nameIDs, size: entryChunkSize) {
            let statement = try db.statement(namePosSQL(count: chunk.count))
            bind(chunk, to: statement)
            while try statement.step() {
                out[statement.requiredInt(0), default: []].append(statement.optionalText(1))
            }
        }
        return out
    }

    /// A gloss hit leads with the sense that matched, so `highlightRange`
    /// always points into a string the row actually renders. The entry's own
    /// first sense follows when it adds something.
    static func preview(for row: CandidateRow, firstSense: [Int: [String]]) -> [String] {
        var glosses: [String] = []
        if let matched = row.matchedGloss, !matched.isEmpty {
            glosses.append(matched)
        }
        for gloss in firstSense[row.entryID] ?? [] where !glosses.contains(gloss) {
            glosses.append(gloss)
        }
        return Array(glosses.prefix(3))
    }

    /// The build joins a sense's glosses with `JMDictPin.glossJoiner`; split
    /// them back, trimmed, deduped in order, empties dropped.
    static func glossList(_ column: String) -> [String] {
        var out: [String] = []
        for gloss in column.components(separatedBy: String(JMDictPin.glossJoiner)) {
            let trimmed = gloss.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !out.contains(trimmed) else { continue }
            out.append(trimmed)
        }
        return out
    }

    // MARK: - Hits

    static func hit(
        for ranked: RankedRow, preview: [String], nameTypes: [String?]
    ) -> DictionarySearchHit {
        let row = ranked.row
        let metadata = ranked.metadata
        return DictionarySearchHit(
            entSeq: metadata.entSeq,
            keb: metadata.keb,
            reb: metadata.reb,
            common: metadata.common,
            // The row's own level wins where the stage had one: a headword hit
            // matched a specific writing and reports that writing's level. The
            // metadata join is the fallback that gives the gloss stage — whose
            // scan never touches `headwords` — the entry's level, so the
            // collapsed row and the expanded entry agree on the badge.
            jlpt: row.jlpt ?? metadata.jlpt,
            isName: metadata.entSeq >= DictionaryContent.nameSeqOffset,
            namePosTokens: nameTypes,
            matchKind: row.matchKind,
            matchedField: row.matchedField,
            highlightRange: clampedHighlight(row.highlightRange, rendered: highlightTarget(
                for: row, metadata: metadata, preview: preview
            )),
            glossPreview: preview
        )
    }

    /// The field the highlight belongs in, as the row renders it — the entry's
    /// writing for a headword hit, the matched sense for a gloss hit.
    static func highlightTarget(
        for row: CandidateRow, metadata: EntryMetadata, preview: [String]
    ) -> String? {
        switch row.matchedField {
        case .keb: metadata.keb
        case .reb: metadata.reb
        case .gloss: preview.first
        }
    }

    /// Clamps a span to the rendered field it will be drawn into. An entry's
    /// matched writing can be shorter than the writing the row scanned (an
    /// alternate kanji spelling, a kana spelling that is not the entry's first
    /// `reb`), and a span that runs past the end of its string would slice out
    /// of bounds in the view.
    static func clampedHighlight(_ range: Range<Int>?, rendered: String?) -> Range<Int>? {
        guard let range, let rendered else { return nil }
        let count = rendered.unicodeScalars.count
        let lower = min(range.lowerBound, count)
        let upper = min(max(range.upperBound, lower), count)
        return upper > lower ? lower ..< upper : nil
    }

    // MARK: - Plumbing

    static func chunks<T>(_ items: [T], size: Int) -> [[T]] {
        stride(from: 0, to: items.count, by: size).map { start in
            Array(items[start ..< min(start + size, items.count)])
        }
    }

    static func bind(_ ids: [Int], to statement: SQLiteDatabase.Statement) {
        for (offset, id) in ids.enumerated() {
            statement.bind(id, at: Int32(offset + 1))
        }
    }
}

// MARK: - SQL

extension DictionarySearchEngine {
    /// One primary-key seek. `jlpt` is selected even though the badge belongs
    /// to the row, not the stage: without it every prefix hit would lose the
    /// level it actually carries.
    static let exactSQL =
        "SELECT h.entry_id, h.kind, h.jlpt FROM headwords h WHERE h.text = ?"

    /// A range scan over the `headwords` B-tree. `LIMIT` bounds the scan;
    /// `ORDER BY LENGTH(h.text)` is deliberately absent (see `headwordRows`).
    static let prefixSQL = """
    SELECT h.entry_id, h.text, h.kind, h.jlpt FROM headwords h
    WHERE h.text >= ?1 AND h.text < ?2
    LIMIT ?3
    """

    /// The gloss stage: the trigram index joined back to `senses` for the matched
    /// text, scoped by `rowid`.
    ///
    /// `MATCH`, not `LIKE`. SQLite's FTS5 documentation is explicit that its
    /// index cannot optimize a `LIKE` carrying an `ESCAPE` clause, and the old
    /// query had one — which is why the stage was a 656,706-row full scan.
    ///
    /// The join is not decoration: `content=''` means the index stores no gloss
    /// text, so the matched column has to come from `senses`, and `rowid` decodes
    /// back to the `(entry_id, ord)` that addresses it. Because FTS5 returns
    /// matching rowids in ascending order, this join reads `senses` in primary
    /// key order.
    ///
    /// One statement for all three scopes — the scope rides `?2`/`?3` (see
    /// `glossRowIDBounds`) — so the predicate rides the scan and the prepared
    /// statement is cached once.
    static let glossSQL = """
    SELECT s.entry_id, s.gloss FROM \(JMDictFTSIndex.tableName) f
    JOIN senses s ON s.entry_id = f.rowid >> \(JMDictFTSIndex.ordShift)
                   AND s.ord = f.rowid & \(JMDictFTSIndex.maxEncodableOrd)
    WHERE \(JMDictFTSIndex.tableName) MATCH ?1 AND f.rowid >= ?2 AND f.rowid < ?3
    """

    /// The pre-join pre-fetch: the one `entries` column the ranking reads. No
    /// join, no text — a run of primary-key seeks over the `entries` B-tree, so
    /// it stays cheap enough to run for every survivor.
    static func commonFlagsSQL(count: Int) -> String {
        "SELECT ent_seq, common FROM entries WHERE ent_seq IN ("
            + placeholders(count) + ")"
    }

    /// The `entries` metadata join, LEFT JOINing one of the entry's writings for
    /// its JLPT level. `headwords` is WITHOUT ROWID keyed `(text, entry_id, kind)`
    /// and `text` is that key's leading column, so the join is a primary-key
    /// prefix seek per row — the same shape as every other probe in the ladder.
    /// The build backfills a word's level onto its writings that carry none, so
    /// the kanji row is where the entry's level lives — and an entry with no
    /// kanji writing at all (keb NULL) reads it off its reading instead, which
    /// is what `COALESCE` buys: without the fallback the level of every
    /// kana-only entry vanished on gloss-tier hits. The join stays entry-scoped
    /// and `(text, entry_id)` is unique, so the fallback cannot fan a row out.
    static func entriesSQL(count: Int) -> String {
        "SELECT e.ent_seq, e.keb, e.reb, e.common, h.jlpt FROM entries e "
            + "LEFT JOIN headwords h ON h.text = COALESCE(e.keb, e.reb) AND h.entry_id = e.ent_seq "
            + "WHERE e.ent_seq IN (" + placeholders(count) + ")"
    }

    static func namePosSQL(count: Int) -> String {
        "SELECT entry_id, pos FROM senses WHERE entry_id IN ("
            + placeholders(count) + ") ORDER BY entry_id, ord"
    }

    static func firstSenseSQL(count: Int) -> String {
        "SELECT entry_id, gloss FROM senses WHERE entry_id IN ("
            + placeholders(count) + ") ORDER BY entry_id, ord"
    }

    static func placeholders(_ count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ",")
    }
}
