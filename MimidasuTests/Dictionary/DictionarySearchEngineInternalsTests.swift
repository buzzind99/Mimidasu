import Foundation
@testable import Mimidasu
import Testing

/// One row-shape the saturation rule is asked about: how deep the window is, how
/// many distinct entries the finished stages hold in each tier, how many
/// candidate rows each of those entries is written under, and what is still
/// pending behind them.
struct SaturationCase: Sendable, CustomTestStringConvertible {
    let limit: Int
    let exactEntries: Int
    let prefixEntries: Int
    let rowsPerEntry: Int
    let remaining: [Int]
    let saturates: Bool

    init(
        _ limit: Int, _ exactEntries: Int, _ prefixEntries: Int,
        _ rowsPerEntry: Int, _ remaining: [Int], _ saturates: Bool
    ) {
        self.limit = limit
        self.exactEntries = exactEntries
        self.prefixEntries = prefixEntries
        self.rowsPerEntry = rowsPerEntry
        self.remaining = remaining
        self.saturates = saturates
    }

    var testDescription: String {
        "window \(limit), exact \(exactEntries), prefix \(prefixEntries), "
            + "\(rowsPerEntry) rows each, pending \(remaining) → \(saturates)"
    }
}

/// The pieces of the engine that answer for themselves: candidate
/// construction, the merge and rank keys, the SQL shapes, and the clamps.
/// Pure, so each rule can be pinned exactly — the ladder suites can only
/// observe their sum.
@Suite("DictionarySearchEngine internals")
final class DictionarySearchEngineInternalsTests {

    // MARK: Pure helpers

    @Test("normalizes at the SQL boundary: NFKC, lowercase, trimmed",
          arguments: zip(["  Ａ  ", "MAKERU", "負ける", "　か "], ["a", "makeru", "負ける", "か"]))
    func normalization(input: String, expected: String) {
        #expect(DictionarySearchEngine.normalize(input) == expected)
    }

    @Test("probes each script a writing can be written in",
          arguments: zip(
              ["まける", "マケル", "負ける"],
              [["まける", "マケル"], ["マケル", "まける"], ["負ける"]]
          ))
    func writingVariants(input: String, expected: [String]) {
        // A kanji-bearing writing is never mirrored: 負ケル is not a spelling
        // anything carries.
        #expect(DictionarySearchEngine.writingVariants(of: input) == expected)
    }

    @Test("folds a halfwidth kana onto the fullwidth form the database stores")
    func halfwidthFold() {
        #expect(DictionarySearchEngine.writingVariants(of: "ｱ").contains("ア"))
    }

    @Test("a full romaji spelling converts into exact candidates")
    func fullRomajiCandidates() {
        let full = DictionarySearchEngine.headwordCandidates(for: "makeru")

        // The kana spellings the romaji names, plus the literal text and its
        // uppercase probing the headwords stored verbatim.
        #expect(Set(full.map(\.text)) == ["まける", "マケル", "makeru", "MAKERU"])
        #expect(full.filter { candidate in candidate.probe == .exact }.count == 4)
        #expect(full.first?.highlightScalars == 3)
    }

    @Test("a digit query probes its own spelling, its uppercase deduped away")
    func digitCandidates() {
        let digits = DictionarySearchEngine.headwordCandidates(for: "4649")

        #expect(Set(digits.map(\.text)) == ["4649"])
        #expect(digits.contains { candidate in candidate.probe == .exact })
        #expect(digits.allSatisfy { candidate in candidate.highlightScalars == 4 })
    }

    @Test("a lowercase Latin spelling also probes the uppercase headword")
    func latinCaseCandidates() {
        let spellings = DictionarySearchEngine.headwordCandidates(for: "tkg")

        #expect(Set(spellings.map(\.text)) == ["tkg", "TKG"])
        #expect(spellings.filter { candidate in candidate.probe == .exact }.count == 2)
    }

    @Test("an English phrase spells no kana, only the Latin it was typed in")
    func englishPhraseCandidates() {
        // `best regards` used to convert its leading token to `べ` and read the
        // `st` it left over as an `s` onset, which lit up べさ…べそ and their
        // katakana mirrors — 74 `ベスト*` rows that outranked the seven entries
        // whose gloss actually reads "best regards". Only the literal probes
        // are left, so the gloss stage is what answers.
        let candidates = DictionarySearchEngine.headwordCandidates(for: "best regards")

        #expect(Set(candidates.map(\.text)) == ["best regards", "BEST REGARDS"])
        #expect(KanaRomaji.convert("best")?.trailingOnset == nil)
    }

    @Test("a romaji prefix expands into prefix candidates")
    func prefixCandidates() {
        let partial = DictionarySearchEngine.headwordCandidates(for: "mak")
        // The spelling and its uppercase probe both stages; every *expansion*
        // is a prefix — an unfinished stem promises what follows, not a word.
        let literal: Set = ["mak", "MAK"]
        #expect(partial.filter { candidate in !literal.contains(candidate.text) }
            .allSatisfy { candidate in candidate.probe == .prefix })

        let texts = Set(partial.map(\.text))
        #expect(texts.contains("まけ"))
        #expect(texts.contains("マケ"))
        #expect(texts.contains("mak"))
        #expect(!texts.contains("ま"))
    }

    @Test("a kana query probes both scripts without duplicating the mirror")
    func kanaCandidates() {
        let japanese = DictionarySearchEngine.headwordCandidates(for: "たべる")

        #expect(Set(japanese.map(\.text)) == ["たべる", "タベル"])
        // Two writings × two probes, each de-duplicated: the mirror is never
        // probed twice, and no writing is probed for the same stage twice.
        #expect(japanese.count == 4)
        #expect(japanese.allSatisfy { candidate in candidate.highlightScalars == 3 })
    }

    @Test("a romaji sentence converts only its leading token")
    func leadingTokenOnly() {
        // A latin query names one headword at best: the leading token converts,
        // the rest is noise.
        let sentence = DictionarySearchEngine.romajiConversions(for: "makeru desu")

        #expect(sentence.count == 1)
        #expect(sentence.first?.kana == "まける")
    }

    @Test("romaji too short to convert stays empty")
    func tooShortConvertsToNothing() {
        #expect(DictionarySearchEngine.romajiConversions(for: "mk").isEmpty)
    }

    @Test("saturates the window on distinct entries, not on the rows behind them",
          arguments: [
              SaturationCase(50, 50, 0, 1, [2], true),
              SaturationCase(50, 50, 0, 1, [1], true),
              SaturationCase(50, 50, 0, 1, [Int](), false),
              SaturationCase(50, 49, 0, 1, [2], false),
              SaturationCase(50, 49, 2, 1, [2], false),
              SaturationCase(50, 50, 1, 1, [2], true),
              SaturationCase(50, 49, 2, 1, [1], false),
              SaturationCase(50, 49, 2, 1, [5], true),
              // The reported case: `best regards` scanned 74 prefix rows over 42
              // entries with the gloss tier still pending. One row each would
              // have saturated; two rows each must not, because `bestPerEntry`
              // dedupes the pairs long before the window and 42 < 50.
              SaturationCase(50, 0, 42, 2, [3], false),
              SaturationCase(50, 0, 50, 2, [3], true),
              // The window is the unit, not a constant: the very rows that
              // saturate one page deep leave the next stage pending two pages
              // deep, which is exactly what a load-more is for.
              SaturationCase(100, 0, 50, 2, [3], false),
              // A zero window can never saturate — there is no worst row to
              // read a tier off.
              SaturationCase(0, 1, 1, 1, [2], false),
          ])
    func capSaturation(_ testCase: SaturationCase) {
        // A full window of exact entries outranks every remaining tier; a
        // partial window can never saturate, and a pending tier that beats the
        // window's worst entry can still displace the tail.
        #expect(DictionarySearchEngine.capSaturated(
            screen(
                exactEntries: testCase.exactEntries,
                prefixEntries: testCase.prefixEntries,
                rowsPerEntry: testCase.rowsPerEntry
            ),
            filters: DictionarySearchFilters(),
            limit: testCase.limit,
            remaining: testCase.remaining
        ) == testCase.saturates)
    }

    @Test("counts only the entries its scope will actually render")
    func capSaturationRespectsScope() {
        // 2 000 word entries behind one name: Words renders a full window and
        // saturates, All renders a full window and saturates, and Names renders
        // one row out of 2 001 — so a stage is still worth running there.
        let words = (0 ..< 2000).map { entry in
            screenRow(kind: .prefix, entryID: entry + 1)
        }
        let name = screenRow(kind: .prefix, entryID: DictionaryContent.nameSeqOffset + 1)
        let all = words + [name]
        func saturated(_ rows: [DictionarySearchEngine.CandidateRow], _ scope: DictionarySearchFilters.Scope) -> Bool {
            DictionarySearchEngine.capSaturated(
                rows, filters: DictionarySearchFilters(scope: scope),
                limit: DictionarySearchEngine.pageSize, remaining: [3]
            )
        }

        #expect(saturated(all, .all) == true)
        #expect(saturated(words, .words) == true)
        #expect(saturated(words, .names) == false)
        #expect(saturated(all, .names) == false)
    }

    /// `exactEntries` + `prefixEntries` distinct entries, each carried by
    /// `rowsPerEntry` candidate rows — the several-writings-one-headword shape
    /// a prefix scan produces and `bestPerEntry` collapses. The two tiers get
    /// disjoint id ranges: one id is one entry, so overlapping them would merge
    /// the tiers instead of stacking them.
    private func screen(
        exactEntries: Int, prefixEntries: Int, rowsPerEntry: Int
    ) -> [DictionarySearchEngine.CandidateRow] {
        var out: [DictionarySearchEngine.CandidateRow] = []
        for (offset, count) in [exactEntries, prefixEntries].enumerated() {
            let kind: DictionarySearchHit.MatchKind = offset == 0 ? .exact : .prefix
            let base = offset == 0 ? 1 : exactEntries + 1
            for entry in 0 ..< count {
                out += Array(repeating: screenRow(kind: kind, entryID: base + entry), count: rowsPerEntry)
            }
        }
        return out
    }

    private func screenRow(
        kind: DictionarySearchHit.MatchKind, entryID: Int
    ) -> DictionarySearchEngine.CandidateRow {
        DictionarySearchEngine.CandidateRow(
            entryID: entryID, matchedField: .keb, matchKind: kind, jlpt: nil,
            matchedLength: 3, highlightRange: 0 ..< 1, matchedGloss: nil
        )
    }

    @Test("keeps the best row per entry")
    func bestPerEntry() {
        let weak = DictionarySearchEngine.CandidateRow(
            entryID: 7, matchedField: .gloss, matchKind: .glossSubstring, jlpt: nil,
            matchedLength: 40, highlightRange: 0 ..< 3, matchedGloss: "something"
        )
        let strong = DictionarySearchEngine.CandidateRow(
            entryID: 7, matchedField: .keb, matchKind: .exact, jlpt: 4,
            matchedLength: 2, highlightRange: 0 ..< 2, matchedGloss: nil
        )

        let best = DictionarySearchEngine.bestPerEntry([weak, strong])

        #expect(best.count == 1)
        #expect(best[7]?.matchKind == .exact)
        #expect(best[7]?.matchedField == .keb)
    }

    @Test("ranks a screen by its rows' tiers")
    func rankOrder() {
        let weak = DictionarySearchEngine.CandidateRow(
            entryID: 7, matchedField: .gloss, matchKind: .glossSubstring, jlpt: nil,
            matchedLength: 40, highlightRange: 0 ..< 3, matchedGloss: "something"
        )
        let strong = DictionarySearchEngine.CandidateRow(
            entryID: 8, matchedField: .keb, matchKind: .exact, jlpt: 4,
            matchedLength: 2, highlightRange: 0 ..< 2, matchedGloss: nil
        )
        let rows = [
            DictionarySearchEngine.ScoredRow(entryID: 7, row: weak, common: false),
            DictionarySearchEngine.ScoredRow(entryID: 8, row: strong, common: true)
        ]

        let ranked = DictionarySearchEngine.rank(rows)

        #expect(ranked.map(\.entryID) == [8, 7])
    }

    @Test("puts the scope predicate in the gloss SQL and nowhere else")
    func glossSQLShape() {
        let sql = DictionarySearchEngine.glossSQL

        #expect(sql.contains("MATCH ?1"))
        #expect(sql.contains("f.rowid >= ?2 AND f.rowid < ?3"))
        // The matched text comes from `senses` — a contentless FTS table stores
        // no gloss — decoded back to `(entry_id, ord)` by the pack.
        #expect(sql.contains("s.entry_id = f.rowid >> \(JMDictFTSIndex.ordShift)"))
        #expect(sql.contains("s.ord = f.rowid & \(JMDictFTSIndex.maxEncodableOrd)"))
        // The `ESCAPE` clause is what made the index unusable in the first
        // place, and the fetch cap is gone: every survivor is ranked now.
        #expect(!sql.contains("LIKE"))
        #expect(!sql.contains("LIMIT"))
    }

    @Test("scopes the gloss stage by rowid range, one statement for all three")
    func glossRowIDRange() {
        // The boundary is the same predicate `admits(entSeq:)` applies, packed.
        // Words admits `ent_seq < 10_000_000`, which is exactly
        // `rowid < 10_000_000 * 128`.
        let boundary = DictionaryContent.nameSeqOffset * JMDictFTSIndex.ordStride
        #expect(boundary == 1_280_000_000)

        let words = DictionarySearchEngine.glossRowIDBounds(for: .words)
        #expect(words.lower == 0)
        #expect(words.upper == boundary)

        let names = DictionarySearchEngine.glossRowIDBounds(for: .names)
        #expect(names.lower == boundary)

        // `.all` is unbounded, and FTS5 reads an absent bound as "no
        // constraint" — not as a scan of everything.
        let all = DictionarySearchEngine.glossRowIDBounds(for: .all)
        #expect(all.lower == 0)
        #expect(all.upper == Int.max)
    }

    @Test("quotes a user's gloss query as one literal phrase",
          arguments: [
              ("bridge", "\"bridge\""),
              // Every LIKE metacharacter is already literal inside a quoted
              // phrase, so only the quote itself needs escaping.
              ("100%", "\"100%\""),
              ("a_b", "\"a_b\""),
              ("a*b", "\"a*b\""),
              ("say \"hi\"", "\"say \"\"hi\"\"\""),
          ])
    func glossPhrase(input: String, expected: String) {
        #expect(JMDictFTSIndex.phrase(input) == expected)
    }

    @Test("chunks a list inside the size, keeping the tail",
          arguments: [
              ([1, 2, 3, 4, 5, 6, 7], 3, [[1, 2, 3], [4, 5, 6], [7]]),
              ([Int](), 3, [[Int]]()),
              ([1], 3, [[1]]),
          ])
    func chunking(input: [Int], size: Int, expected: [[Int]]) {
        #expect(DictionarySearchEngine.chunks(input, size: size) == expected)
    }

    @Test("the entry and sense SQL stay inside SQLite's parameter limits")
    func sqlBuilders() {
        #expect(DictionarySearchEngine.entryChunkSize < 999)
        #expect(DictionarySearchEngine.entriesSQL(count: 2).contains("IN (?,?)"))
        #expect(DictionarySearchEngine.firstSenseSQL(count: 2).contains("ORDER BY entry_id, ord"))
        #expect(DictionarySearchEngine.placeholders(3) == "?,?,?")
    }

    @Test("clamps a highlight to the string it is drawn into")
    func highlightClamping() {
        // The matched spelling can be longer than the field the row renders —
        // an alternate kanji, or a kana spelling that is not the entry's first.
        #expect(DictionarySearchEngine.clampedHighlight(0 ..< 3, rendered: "さご") == 0 ..< 2)
        #expect(DictionarySearchEngine.clampedHighlight(0 ..< 3, rendered: "ア") == 0 ..< 1)
        #expect(DictionarySearchEngine.clampedHighlight(2 ..< 4, rendered: "さ") == nil)
        #expect(DictionarySearchEngine.clampedHighlight(nil, rendered: "さご") == nil)
        #expect(DictionarySearchEngine.clampedHighlight(0 ..< 1, rendered: nil) == nil)
    }

    @Test("resolves the highlight's target field per match kind",
          arguments: [
              (DictionarySearchHit.MatchedField.keb, [String](), "愛"),
              (DictionarySearchHit.MatchedField.reb, [String](), "あい"),
              (DictionarySearchHit.MatchedField.gloss, ["love"], "love"),
          ])
    func highlightTarget(
        field: DictionarySearchHit.MatchedField, preview: [String], target: String
    ) {
        let metadata = DictionarySearchEngine.EntryMetadata(
            entSeq: 5, keb: "愛", reb: "あい", common: true, jlpt: 4
        )
        let row = DictionarySearchEngine.CandidateRow(
            entryID: 5, matchedField: field, matchKind: .exact, jlpt: nil,
            matchedLength: 2, highlightRange: 0 ..< 2, matchedGloss: "love"
        )
        #expect(DictionarySearchEngine.highlightTarget(
            for: row, metadata: metadata, preview: preview
        ) == target)
    }

    @Test("seeds a gloss hit's preview with the sense that matched")
    func previewSeededWithMatchedSense() {
        let gloss = DictionarySearchEngine.CandidateRow(
            entryID: 3, matchedField: .gloss, matchKind: .glossWordBoundary, jlpt: nil,
            matchedLength: 10, highlightRange: 0 ..< 4, matchedGloss: "to eat"
        )

        #expect(DictionarySearchEngine.preview(for: gloss, firstSense: [3: ["something", "to eat"]])
            == ["to eat", "something"])
    }

    @Test("a word hit's preview is the first sense, deduplicated")
    func previewDeduplicates() {
        let firstSense = DictionarySearchEngine.CandidateRow(
            entryID: 4, matchedField: .keb, matchKind: .exact, jlpt: nil,
            matchedLength: 2, highlightRange: 0 ..< 2, matchedGloss: nil
        )

        #expect(DictionarySearchEngine.preview(for: firstSense, firstSense: [4: ["to eat", "to eat"]])
            == ["to eat"])
    }

    @Test("a word hit with no first sense carries no preview")
    func previewWithoutSense() {
        let firstSense = DictionarySearchEngine.CandidateRow(
            entryID: 4, matchedField: .keb, matchKind: .exact, jlpt: nil,
            matchedLength: 2, highlightRange: 0 ..< 2, matchedGloss: nil
        )

        #expect(DictionarySearchEngine.preview(for: firstSense, firstSense: [:]).isEmpty)
    }

    @Test("a gloss the fold cannot locate keeps its hit, spanned by the pattern's length")
    func foldMissFallback() {
        // A LIKE match the fold cannot reproduce is rare — `İ` lower-cases to
        // two scalars, so a span computed from the pattern's own length is the
        // only thing left to fall back on. The hit still earns its place.
        let match = DictionarySearchEngine.glossMatch(pattern: "\u{0130}", column: "x")

        #expect(match.kind == .glossSubstring)
        #expect(match.gloss == "x")
        #expect(match.range == 0 ..< 1)
    }

    @Test("an empty column leaves nothing to span")
    func emptyColumnNoSpan() {
        #expect(DictionarySearchEngine.glossMatch(pattern: "ss", column: "").range == nil)
    }

    @Test("an ordinary column grades per gloss and locates the span")
    func ordinaryColumnLocated() {
        let located = DictionarySearchEngine.glossMatch(pattern: "ice", column: "rice-sugar; toffee")

        #expect(located.gloss == "rice-sugar")
        #expect(located.kind == .glossSubstring)
        #expect(located.range == 1 ..< 4)
    }

    @Test("splits a sense's stored gloss column back into glosses",
          arguments: zip(
              ["to eat; to live on", "a; a; ", ""],
              [["to eat", "to live on"], ["a"], [String]()]
          ))
    func glossList(input: String, expected: [String]) {
        #expect(DictionarySearchEngine.glossList(input) == expected)
    }

    @Test("grades a gloss match against its neighbours",
          arguments: [
              ("to lose", 0 ..< 7, DictionarySearchHit.MatchKind.glossWordBoundary),
              ("to lose", 3 ..< 7, DictionarySearchHit.MatchKind.glossWordBoundary),
              ("to be defeated", 6 ..< 14, DictionarySearchHit.MatchKind.glossWordBoundary),
              ("to lose", 0 ..< 2, DictionarySearchHit.MatchKind.glossPrefix),
              ("to be defeated", 6 ..< 9, DictionarySearchHit.MatchKind.glossSubstring),
              ("to rice", 4 ..< 7, DictionarySearchHit.MatchKind.glossSubstring),
              ("mind", 1 ..< 3, DictionarySearchHit.MatchKind.glossSubstring),
              ("to rice", 3 ..< 7, DictionarySearchHit.MatchKind.glossWordBoundary),
          ])
    func glossMatchKindRanking(gloss: String, range: Range<Int>, kind: DictionarySearchHit.MatchKind) {
        // A whole-word run has boundaries on both sides; an opening partial
        // keeps only the left one; a run buried inside a word on either side
        // is a bare substring. `rice` in "to rice" is a whole word — the whole
        // difference from `ice` in the same string.
        #expect(DictionarySearchEngine.glossMatchKind(gloss: gloss, range: range) == kind)
    }

    @Test("ranks the tiers in the order the badge implies")
    func matchKindOrder() {
        #expect(DictionarySearchHit.MatchKind.exact.rawValue
            < DictionarySearchHit.MatchKind.lemma.rawValue)
        #expect(DictionarySearchHit.MatchKind.lemma.rawValue
            < DictionarySearchHit.MatchKind.prefix.rawValue)
        #expect(DictionarySearchHit.MatchKind.prefix.rawValue
            < DictionarySearchHit.MatchKind.glossWordBoundary.rawValue)
    }

    @Test("labels the tiers the badges render",
          arguments: zip(
              [DictionarySearchHit.MatchKind.exact, .lemma, .prefix, .glossWordBoundary],
              ["EXACT", "LEMMA", "PREFIX", "GLOSS"]
          ))
    func badgeLabels(kind: DictionarySearchHit.MatchKind, label: String) {
        #expect(kind.badgeLabel == label)
    }

    @Test("the engine defaults to the store's prepared dictionary")
    func defaultInit() throws {
        let sut = DictionarySearchEngine()
        defer { sut.close() }

        // Whether the database resolves is the machine's business; that the
        // default closures are callable without a fixture is the point, and an
        // empty query never reaches them.
        #expect(try sut.search("", filters: DictionarySearchFilters()) == .empty)
    }

    @Test("binds a candidate list by id")
    func statementBinding() throws {
        let fixture = try DictionarySearchFixture()
        let database = try SQLiteDatabase(path: fixture.url.path)
        defer { database.close() }

        let statement = try database.statement(DictionarySearchEngine.entriesSQL(count: 3))
        DictionarySearchEngine.bind([1_358_280, 1_237_410, 1_500_150], to: statement)

        #expect(try statement.step())
    }
}
