import Foundation
@testable import Mimidasu
import Testing

/// The `assemble` reorder, proved lossless rather than spot-checked.
///
/// Ranking key #2 is `common`, which lives in `entries`, so the window cannot
/// be cut before the join reads it — the reorder fetches that one column for
/// every survivor as a bare primary-key lookup, ranks, cuts the window, and
/// only then pays for the `headwords` join on the rows that will be shown.
/// That is a performance argument, and performance arguments hide correctness
/// bugs: a row dropped between the two halves is invisible on screen and
/// invisible in `matchedCount`.
///
/// So the old shape is reimplemented here verbatim and run against the new one
/// over a fixture whose survivors exceed `maxRows` — the only regime where the
/// two can actually differ, since below `maxRows` both join everything.
@Suite("DictionarySearch assemble reorder")
struct DictionarySearchAssembleDiffTests {
    /// Survivors in excess of `maxRows`, a third of them common, with gloss
    /// text that varies in length — so all four ranking keys (tier, commonness,
    /// matched length, `ent_seq`) actually discriminate and a bug that swapped
    /// two keys would show up as a different order rather than as no order at
    /// all.
    private static let survivors = DictionarySearchEngine.maxRows + 200

    /// The candidate rows the gloss stage produces, plus a handle over the
    /// fixture they came from and a handle the caller must close.
    private struct Stage {
        let rows: [DictionarySearchEngine.CandidateRow]
        let db: SQLiteDatabase
        let fixture: DictionarySearchFixture
    }

    private func makeRows() throws -> Stage {
        let fixture = try DictionarySearchFixture(
            extraWords: JMDictFixtureDatabase.bulkWords(
                count: Self.survivors, readingPrefix: "かん", startingAt: 9_991_000
            )
        )
        let db = try SQLiteDatabase(path: fixture.url.path)
        // `bulk` is four Latin characters, so only the gloss stage can answer it:
        // no reading in the fixture is a headword for it.
        let rows = try DictionarySearchEngine.glossRows(
            pattern: "bulk", scope: .all, db: db
        )
        return Stage(rows: rows, db: db, fixture: fixture)
    }

    @Test("the reordered assemble returns the old assemble's hits and total")
    func reorderIsLossless() throws {
        let stage = try makeRows()
        defer { stage.db.close() }
        let rows = stage.rows
        // The regime that makes the two differ at all: the old shape joined
        // every survivor and then threw most of them away.
        #expect(rows.count == Self.survivors)
        #expect(Self.survivors > DictionarySearchEngine.maxRows)

        let filters = DictionarySearchFilters()
        let current = try DictionarySearchEngine.assemble(
            rows, filters: filters, db: stage.db, saturated: false, truncated: false
        )
        let legacy = try Self.legacyAssemble(rows, filters: filters, db: stage.db)

        #expect(current.hits == legacy.hits)
        #expect(current.matchedCount == legacy.matchedCount)
        #expect(current.hits.count == DictionarySearchEngine.maxRows)
        // Every survivor is counted, not just the window — this is what the
        // deleted fetch cap used to under-report.
        #expect(current.matchedCount == Self.survivors)
    }

    @Test("the reordered assemble agrees under common-only, where the filter moved")
    func reorderIsLosslessUnderCommonOnly() throws {
        let stage = try makeRows()
        defer { stage.db.close() }
        let rows = stage.rows
        let filters = DictionarySearchFilters(commonOnly: true)
        let current = try DictionarySearchEngine.assemble(
            rows, filters: filters, db: stage.db, saturated: false, truncated: false
        )
        let legacy = try Self.legacyAssemble(rows, filters: filters, db: stage.db)

        // `commonOnly` now filters against the pre-fetched flag instead of the
        // joined metadata. Same value, different statement — so it is worth
        // proving rather than assuming.
        #expect(current.hits == legacy.hits)
        #expect(current.matchedCount == legacy.matchedCount)
        #expect(current.hits.allSatisfy { hit in hit.common })
        #expect(current.matchedCount < Self.survivors)
    }

    @Test("the reordered assemble agrees under a scope filter")
    func reorderIsLosslessUnderScope() throws {
        let stage = try makeRows()
        defer { stage.db.close() }
        let rows = stage.rows
        let filters = DictionarySearchFilters(scope: .words)
        let current = try DictionarySearchEngine.assemble(
            rows, filters: filters, db: stage.db, saturated: false, truncated: false
        )
        let legacy = try Self.legacyAssemble(rows, filters: filters, db: stage.db)

        #expect(current.hits == legacy.hits)
        #expect(current.matchedCount == legacy.matchedCount)
        #expect(current.hits.allSatisfy { hit in !hit.isName })
    }

    @Test("the production search path returns the reordered assemble's answer")
    func productionPathAgrees() throws {
        let stage = try makeRows()
        defer { stage.db.close() }
        let outcome = try stage.fixture.outcome("bulk")
        let assembled = try DictionarySearchEngine.assemble(
            stage.rows, filters: DictionarySearchFilters(), db: stage.db,
            saturated: false, truncated: false
        )

        #expect(outcome.hits == assembled.hits)
        #expect(outcome.matchedCount == Self.survivors)
    }

    /// The pre-reorder `assemble`, transcribed: join every survivor, filter
    /// `commonOnly` post-join, rank, then truncate to the window.
    ///
    /// Kept honest deliberately — it calls the same production helpers
    /// (`bestPerEntry`, `entryMetadata`, `firstSenseGlosses`, `hit`) and only
    /// re-derives the *order* of those calls plus the rank comparator, which is
    /// what the reorder actually touched.
    private static func legacyAssemble(
        _ rows: [DictionarySearchEngine.CandidateRow],
        filters: DictionarySearchFilters,
        db: SQLiteDatabase
    ) throws -> DictionarySearchOutcome {
        let survivors = DictionarySearchEngine.bestPerEntry(rows)
            .filter { entryID, _ in filters.admits(entSeq: entryID) }
        let metadata = try DictionarySearchEngine.entryMetadata(
            for: survivors.keys.sorted(), db: db
        )
        let joined = survivors.compactMap { entryID, row in
            metadata[entryID].map { meta in
                DictionarySearchEngine.RankedRow(row: row, metadata: meta)
            }
        }
        let kept = filters.commonOnly
            ? legacyRank(joined.filter { ranked in ranked.metadata.common })
            : legacyRank(joined)
        let built = Array(kept.prefix(DictionarySearchEngine.maxRows))
        let previews = try DictionarySearchEngine.firstSenseGlosses(
            for: built.map(\.metadata.entSeq), db: db
        )
        let nameTypes = try DictionarySearchEngine.namePosTokens(for: built, db: db)
        let hits = built.map { ranked in
            DictionarySearchEngine.hit(
                for: ranked,
                preview: DictionarySearchEngine.preview(
                    for: ranked.row, firstSense: previews
                ),
                nameTypes: nameTypes[ranked.metadata.entSeq] ?? []
            )
        }
        return DictionarySearchOutcome(
            hits: hits, matchedCount: kept.count, saturated: false, truncated: false
        )
    }

    /// The pre-reorder comparator: same four keys, reading `ent_seq` and
    /// `common` off the joined metadata rather than the pre-join struct.
    private static func legacyRank(
        _ rows: [DictionarySearchEngine.RankedRow]
    ) -> [DictionarySearchEngine.RankedRow] {
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
}
