import Foundation
@testable import Mimidasu
import Testing

/// The two correctness claims the FTS5 gloss index makes, measured against the
/// real prepared database rather than a fixture.
///
/// **Recall is not lost.** The old stage matched with
/// `WHERE gloss LIKE '%q%' ESCAPE '\'`, which walked all 656,706 `senses` rows.
/// The index answers with `MATCH`, and FTS5 folds case across the whole Unicode
/// range while `LIKE` folds ASCII only. So the two are *not* equivalent, and
/// the direction matters: every divergence measured is a row `MATCH` has and
/// `LIKE` does not. That is not a rounding error — `normalize` lowercases every
/// query, which combined with `LIKE`'s ASCII-only fold made the 35,714 sense
/// rows carrying uppercase non-ASCII (`École`, `ÉCOLE`) unreachable from *any*
/// query. A user typing `école` got zero results.
///
/// **A six-row fixture cannot see this.** The equivalence claim survived as long
/// as it did because hand-built corpora happen to agree. Hence the real
/// database, and hence the accented probes below — an ASCII-only probe set
/// passes against an index that folds nothing at all.
@Suite("JMDict gloss index recall", .enabled(if: InstalledJMDict.url != nil))
struct JMDictGlossIndexRecallTests {
    private func database() throws -> SQLiteDatabase {
        guard let url = InstalledJMDict.url else {
            throw CancellationError()
        }
        return try SQLiteDatabase(path: url.path)
    }

    /// Every `entry_id` whose gloss contains `query`, read through the index.
    private func indexed(_ query: String, db: SQLiteDatabase) throws -> Set<Int> {
        let statement = try db.statement(DictionarySearchEngine.glossSQL)
        let bounds = DictionarySearchEngine.glossRowIDBounds(for: .all)
        statement.bind(JMDictFTSIndex.phrase(query.lowercased()), at: 1)
        statement.bind(bounds.lower, at: 2)
        statement.bind(bounds.upper, at: 3)
        var out: Set<Int> = []
        while try statement.step() {
            out.insert(statement.requiredInt(0))
        }
        return out
    }

    /// Every `entry_id` the old full scan would have returned.
    ///
    /// Reproduced here rather than trusted to history: it is the exact
    /// predicate the stage ran before, `LIKE` and its escaping included.
    private func scanned(_ query: String, db: SQLiteDatabase) throws -> Set<Int> {
        let escaped = query
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        let statement = try db.statement(
            "SELECT entry_id FROM senses WHERE gloss LIKE ?1 ESCAPE '\\'"
        )
        statement.bind("%\(escaped)%", at: 1)
        var out: Set<Int> = []
        while try statement.step() {
            out.insert(statement.requiredInt(0))
        }
        return out
    }

    @Test("the indexed path returns every row the LIKE scan returned",
          arguments: [
              "lose", "bridge", "abandon", "the", "car", "best regards",
              "ing", "tion", "ers", "cafe", "CAFE", "strasse", "stanbul",
              "toku", "ecole", "école", "École", "σισυφος", "ΣΊΣΥΦΟΣ",
              "100%", "a_b", "abc-def"
          ])
    func indexedIsASupersetOfScanned(query: String) throws {
        let db = try database()
        defer { db.close() }

        let scanned = try scanned(query.lowercased(), db: db)
        let indexed = try indexed(query.lowercased(), db: db)

        // The hard half. Any row the old scan found and the index does not is a
        // regression a user would see as a vanished search result.
        #expect(
            scanned.subtracting(indexed).isEmpty,
            "\(query): the index dropped \(scanned.subtracting(indexed).count) row(s) the scan found"
        )
    }

    @Test("every indexed row still grades a highlight span",
          arguments: ["lose", "car", "école", "best regards", "ing"])
    func everyIndexedRowGradesASpan(query: String) throws {
        let db = try database()
        defer { db.close() }
        let pattern = query.lowercased()

        // `glossMatch` falls back to spanning the whole column when the fold in
        // `MatchHighlight.range` cannot locate the pattern in any of its
        // glosses. That fallback is only unreachable while that fold agrees
        // with the tokenizer's — and it is load-bearing now rather than
        // incidental, because FTS5 folds case `LIKE` never reached. A row can
        // match the index and then be impossible to point at inside its own
        // text, which would render as a hit whose highlight lights up nothing.
        //
        // Graded over the production join's own output rather than a
        // re-query, so what is checked is exactly what the stage sees.
        let statement = try db.statement(DictionarySearchEngine.glossSQL)
        let bounds = DictionarySearchEngine.glossRowIDBounds(for: .all)
        statement.bind(JMDictFTSIndex.phrase(pattern), at: 1)
        statement.bind(bounds.lower, at: 2)
        statement.bind(bounds.upper, at: 3)
        var rows = 0
        var unlocated = 0
        while try statement.step() {
            rows += 1
            let column = statement.optionalText(1) ?? ""
            let located = DictionarySearchEngine.glossList(column).contains { gloss in
                MatchHighlight.range(of: pattern, in: gloss) != nil
            }
            if !located {
                unlocated += 1
            }
        }
        #expect(rows > 0)
        #expect(unlocated == 0, "\(unlocated) of \(rows) row(s) matched but could not be located")
    }

    @Test("the index reaches rows the ASCII-only fold could not")
    func indexRecoversUnicodeCaseRows() throws {
        let db = try database()
        defer { db.close() }

        // `normalize` lowercases every query, so under `LIKE` these two rows
        // were unreachable from every query the app could produce. This is the
        // bug the index fixes, not a nicety it adds.
        let scanned = try scanned("école", db: db)
        let indexed = try indexed("école", db: db)

        #expect(!indexed.isEmpty)
        #expect(indexed.count > scanned.count)
        #expect(scanned.subtracting(indexed).isEmpty)
    }

    @Test("two-character queries are refused before the index, not after")
    func twoCharacterQueriesAreRefusedUpstream() throws {
        let db = try database()
        defer { db.close() }

        // The trigram tokenizer cannot express a shorter phrase and answers
        // with zero rows and no error — a silent total loss. The gate that
        // prevents it is `acceptsGlossQuery`, so this pins the gate against the
        // measured cost of removing it.
        #expect(DictionarySearchEngine.acceptsGlossQuery("ma") == false)
        #expect(try scanned("ma", db: db).count > 70000)
        #expect(try indexed("ma", db: db).isEmpty)
    }
}
