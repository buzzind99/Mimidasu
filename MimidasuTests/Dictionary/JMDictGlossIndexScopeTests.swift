import Foundation
@testable import Mimidasu
import Testing

/// Regression: the capped `.all` scan structurally excluded names. On `to`
/// the scope matched 85,364 sense rows, of which **38,571 are names** — none
/// of which the capped scan returned. The cause was mechanical: the cap's
/// `LIMIT` had no `ORDER BY`, and `senses` is keyed `(entry_id, ord)` with
/// every name entry at `ent_seq >= 10M`, so a truncated scan simply stopped
/// inside the word block and never reached them.
///
/// The originally proposed repair was to run a second `.names` scan and merge.
/// That is unnecessary here: deleting the cap removes the truncation and the
/// missing names together, so the question is only whether the merged screen
/// comes out the same.
///
/// **The original probe cannot be re-run.** `to` is two characters, and the
/// trigram tokenizer cannot express a two-character phrase — FTS5 answers it
/// with zero rows and no error, on every scope. Measured here it returns 0 for
/// `.all`, `.words` and `.names` alike, which is indistinguishable from "no
/// names at all" and would have made this gate pass while asserting nothing.
/// The probe is `ion` instead: 36,218 word entries and 11,691 name entries,
/// the densest three-character crossing of the offset in the corpus.
@Suite("JMDict gloss index uncapped scope", .enabled(if: InstalledJMDict.url != nil))
struct JMDictGlossIndexScopeTests {
    private func database() throws -> SQLiteDatabase {
        guard let url = InstalledJMDict.url else { throw CancellationError() }
        return try SQLiteDatabase(path: url.path)
    }

    /// One entry id per scope, read through the production statement.
    private func entries(
        _ query: String, scope: DictionarySearchFilters.Scope, db: SQLiteDatabase
    ) throws -> Set<Int> {
        let statement = try db.statement(DictionarySearchEngine.glossSQL)
        let bounds = DictionarySearchEngine.glossRowIDBounds(for: scope)
        statement.bind(JMDictFTSIndex.phrase(query.lowercased()), at: 1)
        statement.bind(bounds.lower, at: 2)
        statement.bind(bounds.upper, at: 3)
        var out: Set<Int> = []
        while try statement.step() {
            out.insert(statement.requiredInt(0))
        }
        return out
    }

    @Test("the uncapped .all scan returns the names the capped one hid")
    func allScopeNowIncludesNames() throws {
        let db = try database()
        defer { db.close() }

        let all = try entries("ion", scope: .all, db: db)
        let words = try entries("ion", scope: .words, db: db)
        let names = try entries("ion", scope: .names, db: db)

        // Dense on both sides of the offset — the regime the capped `.all`
        // scan truncated out of existence.
        #expect(words.count > 30000)
        #expect(names.count > 10000)

        // `.all` is the union of the two scopes: the property the capped `.all`
        // scan structurally could not have.
        #expect(all == words.union(names))
        #expect(all.isSuperset(of: words))
        #expect(all.isSuperset(of: names))

        // Names are the entire point of the uncapped scan: they used to be unreachable
        // through `.all`, and now they are not.
        let offset = JMDictNameEntries.ingestOffset
        #expect(names.allSatisfy { entryID in entryID >= offset })
        #expect(words.allSatisfy { entryID in entryID < offset })
        #expect(all.filter { entryID in entryID >= offset }.count == names.count)
    }

    @Test("a name-heavier query is still reached through .all")
    func nameHeavyQueryStillCrossesTheOffset() throws {
        let db = try database()
        defer { db.close() }

        // The miniature shape: more names than words, so a
        // scan that stopped at the ceiling would return almost nothing useful.
        let words = try entries("oto", scope: .words, db: db)
        let names = try entries("oto", scope: .names, db: db)
        let all = try entries("oto", scope: .all, db: db)

        #expect(names.count > words.count)
        #expect(all == words.union(names))
        #expect(all.count == words.count + names.count)
    }

    @Test("the scopes partition on the ingest offset, with no overlap or gap")
    func scopesPartitionTheCorpus() throws {
        let db = try database()
        defer { db.close() }

        // A smaller query than `to` keeps this cheap while still crossing the
        // boundary densely on both sides.
        let words = try entries("name", scope: .words, db: db)
        let names = try entries("name", scope: .names, db: db)
        let all = try entries("name", scope: .all, db: db)

        #expect(words.isDisjoint(with: names))
        #expect(all == words.union(names))
    }

    @Test("the rowid range is what makes a scoped scan cheap")
    func rowidRangeBoundsTheScan() throws {
        let db = try database()
        defer { db.close() }

        // `.names` used to cost the whole 403,272-row name block on every query
        // — 25–34 ms even when it found nothing, because `senses` has no index
        // on `gloss`. Asserted here as coverage rather than as timing: the
        // statement must return the names, and it must do so through the same
        // one-statement path as every other scope.
        let names = try entries("bridge", scope: .names, db: db)
        let all = try entries("bridge", scope: .all, db: db)
        #expect(!names.isEmpty)
        #expect(all.isSuperset(of: names))
    }
}
