import Foundation

/// Merging, the deferred `entries` join, ranking, and hit construction. The
/// order matters: ranking key #2 (`common`) lives in `entries`, so the join
/// cannot be folded into the scans and `commonOnly` cannot apply before it —
/// which is exactly why the stage queries stay primary-key-only.
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

    /// A candidate row joined to its entry, ready to rank.
    struct RankedRow {
        let row: CandidateRow
        let metadata: EntryMetadata
    }

    /// Merge, join, filter, rank, bound, and decorate.
    ///
    /// The sequence is load-bearing: scope filters pre-join (it is a predicate
    /// on `ent_seq` alone), and `commonOnly` filters post-join (`common` does
    /// not exist before it).
    ///
    /// Note what is *not* here: the caller's window. Every row the stages
    /// found is built, up to `maxRows` — the window is the UI's slice
    /// (`DictionarySearchState.visibleHits`), and building a row costs a
    /// couple of dictionary lookups against rows this search already holds.
    /// What costs a search is the scans, which happen upstream of this file.
    static func assemble(
        _ rows: [CandidateRow],
        filters: DictionarySearchFilters,
        db: SQLiteDatabase,
        saturated: Bool
    ) throws -> DictionarySearchOutcome {
        let survivors = bestPerEntry(rows)
            .filter { entryID, _ in filters.admits(entSeq: entryID) }
        let metadata = try entryMetadata(for: survivors.keys.sorted(), db: db)
        let joined = survivors.compactMap { entryID, row in
            metadata[entryID].map { meta in RankedRow(row: row, metadata: meta) }
        }
        let kept = filters.commonOnly
            ? rank(joined.filter { ranked in ranked.metadata.common })
            : rank(joined)
        let built = Array(kept.prefix(Self.maxRows))
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
            hits: hits, matchedCount: kept.count, saturated: saturated
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
    /// under the cursor is worse than one that is merely alphabetical.
    /// Commonness descending sinks names in All scope on its own, since
    /// JMnedict entries are never common.
    static func rank(_ rows: [RankedRow]) -> [RankedRow] {
        rows.sorted { lhs, rhs in
            if lhs.row.matchKind != rhs.row.matchKind {
                return lhs.row.matchKind.rawValue < rhs.row.matchKind.rawValue
            }
            if lhs.metadata.common != rhs.metadata.common {
                return lhs.metadata.common
            }
            if lhs.row.matchedLength != rhs.row.matchedLength {
                return lhs.row.matchedLength < rhs.row.matchedLength
            }
            return lhs.metadata.entSeq < rhs.metadata.entSeq
        }
    }

    // MARK: - Deferred joins

    /// `entries` metadata in `IN`-clause chunks. A search can reach a few
    /// thousand survivors; chunking keeps every statement inside SQLite's bound
    /// parameter limit, and each chunk is a run of primary-key seeks.
    static func entryMetadata(
        for entSeqs: [Int], db: SQLiteDatabase
    ) throws -> [Int: EntryMetadata] {
        var out: [Int: EntryMetadata] = [:]
        for chunk in chunks(entSeqs, size: entryChunkSize) {
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
    /// `ord` per entry is simply the first row seen; the build's `"; "` join
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

    /// The build joins a sense's glosses with `"; "`; split them back, trimmed,
    /// deduped in order, empties dropped.
    static func glossList(_ column: String) -> [String] {
        var out: [String] = []
        for gloss in column.components(separatedBy: "; ") {
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

    /// The gloss stage, one statement per scope so the predicate rides the
    /// scan. `senses` cannot use an index for `LIKE`, so this is the only
    /// bounded thing about it.
    static func glossSQL(for scope: DictionarySearchFilters.Scope) -> String {
        let head = "SELECT s.entry_id, s.gloss FROM senses s WHERE s.gloss LIKE ?1 ESCAPE '\\'"
        let boundary = DictionaryContent.nameSeqOffset
        return switch scope {
        case .all: head + " LIMIT ?2"
        case .words: head + " AND s.entry_id < \(boundary) LIMIT ?2"
        case .names: head + " AND s.entry_id >= \(boundary) LIMIT ?2"
        }
    }

    /// The `entries` metadata join, LEFT JOINing the entry's kanji writing for its
    /// JLPT level. `headwords` is WITHOUT ROWID keyed `(text, entry_id, kind)`
    /// and `text` is that key's leading column, so `h.text = e.keb` is a primary-key
    /// prefix seek per row — the same shape as every other probe in the ladder.
    /// The build backfills a word's level onto its writings that carry none, so
    /// the kanji row is where the entry's level lives.
    static func entriesSQL(count: Int) -> String {
        "SELECT e.ent_seq, e.keb, e.reb, e.common, h.jlpt FROM entries e "
            + "LEFT JOIN headwords h ON h.text = e.keb AND h.entry_id = e.ent_seq "
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

    /// `LIKE` wildcards in a user query are literal text, not patterns — same
    /// escaping (and the same `ESCAPE '\'`) `FavoritesDatabase` uses for its
    /// own search.
    static func likeEscaped(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }
}
