import Foundation
@testable import Mimidasu
import Testing

/// The search ladder over the fixture database: which stage produced a hit,
/// what it ranks, which field the highlight lands in, and how the filters,
/// errors and the outcome envelope read. Everything here runs offline — the
/// live suite beside it covers what the fixture is too small to stage.
@Suite("DictionarySearchEngine")
final class DictionarySearchEngineTests {
    private let fixture: DictionarySearchFixture

    init() throws {
        fixture = try DictionarySearchFixture()
    }

    private var engine: DictionarySearchEngine {
        fixture.engine
    }

    private var databaseURL: URL {
        fixture.url
    }

    private func search(
        _ query: String, scope: DictionarySearchFilters.Scope = .all,
        commonOnly: Bool = false
    ) throws -> DictionarySearchOutcome {
        try fixture.outcome(query, scope: scope, commonOnly: commonOnly)
    }

    // MARK: Stages

    @Test("finds a kanji writing as an exact hit and lights up the whole headword")
    func exactKanji() throws {
        let outcome = try search("食べる")

        let hit = try #require(outcome.hits.first)

        #expect(hit.entSeq == 1_358_280)
        #expect(hit.matchKind == .exact)
        #expect(hit.matchedField == .keb)
        #expect(hit.highlightRange == 0 ..< 3)
        #expect(hit.jlpt == 5)
        #expect(hit.common)
        #expect(hit.id == hit.entSeq)
        #expect(hit.headword == "食べる")
        #expect(hit.glossPreview == ["to eat"])
        #expect(!hit.isName)
    }

    @Test("finds a kana reading and highlights the reading, not the kanji")
    func exactKana() throws {
        let outcome = try search("たべる")

        let hit = try #require(outcome.hits.first)

        #expect(hit.entSeq == 1_358_280)
        #expect(hit.matchedField == .reb)
        #expect(hit.highlightRange == 0 ..< 3)
        #expect(hit.keb == "食べる")
    }

    @Test("reaches a katakana-written reading through the hiragana fold")
    func katakanaFold() throws {
        let outcome = try search("アソコ")

        let hit = try #require(outcome.hits.first)

        #expect(hit.entSeq == 1_000_320)
        #expect(hit.matchKind == .exact)
        #expect(hit.matchedField == .reb)
    }

    @Test("keeps the exact tier when the prefix scan reaches the same entry")
    func mergeKeepsBestTier() throws {
        // `あそこ` matches its own `reb` row exactly *and* the アソコ prefix
        // candidate's range scan reaches the same entry; the exact row wins, so
        // the badge reads EXACT and the highlight is the typed span.
        let outcome = try search("あそこ")

        let hits = outcome.hits.filter { hit in hit.entSeq == 1_000_320 }
        #expect(hits.count == 1)

        let hit = try #require(hits.first)
        #expect(hit.matchKind == .exact)
        #expect(hit.highlightRange == 0 ..< 3)
    }

    @Test("prefix hits keep the level of the row they matched")
    func prefixKeepsJLPT() throws {
        let outcome = try search("食")

        let hit = try #require(outcome.hits.first { candidate in
            candidate.entSeq == 1_358_280
        })

        #expect(hit.matchKind == .prefix)
        #expect(hit.matchedField == .keb)
        #expect(hit.jlpt == 5)
        // Only the typed scalar is lit up, not the whole matched headword.
        #expect(hit.highlightRange == 0 ..< 1)
        #expect(hit.glossPreview == ["to eat"])
    }

    @Test("orders a prefix scan's survivors shortest headword first")
    func prefixShortestFirst() throws {
        let outcome = try search("あ")

        let prefixes = outcome.hits.filter { hit in hit.matchKind == .prefix }

        // あめ / 彼処 / あめむら / アルバイト (reached through the katakana
        // mirror) / 雨 / 雨村 — six entries, one row each. Commonness outranks
        // tightness in the rank, so shortest-first holds inside a commonness
        // partition, not across the whole list: the uncommon 雨 trails the
        // six-mora アルバイト.
        #expect(prefixes.count == 6)
        #expect(prefixes.map(\.entSeq) == [1_153_520, 1_000_320, 9_990_100, 1_019_420,
                                           9_990_030, 15_668_307])
        // The pinned readings double as the range-scan bound: every row the
        // scan returned starts with the mora the user typed.
        #expect(prefixes.map(\.reb) == ["あめ", "あそこ", "あめむら", "アルバイト", "あめ",
                                        "あめむら"])
        #expect(outcome.hits.filter { hit in hit.matchKind == .exact }.isEmpty)
    }

    @Test("leads a shared spelling with the common entry")
    func commonnessRanking() throws {
        // あめ is a homograph pair (飴 common, 雨 not) and the prefix of
        // あめむら, which is itself a common/name homograph pair.
        let hits = try search("あめ").hits

        #expect(hits.map(\.entSeq) == [1_153_520, 9_990_030, 9_990_100, 15_668_307])
        #expect(hits.map(\.common) == [true, false, true, false])
        #expect(hits.map(\.matchKind) == [.exact, .exact, .prefix, .prefix])
        #expect(hits.map(\.isName) == [false, false, false, true])
        // Within a tier, commonness first; then the tighter match; then ent_seq.
        #expect(hits[0].reb == "あめ")
        #expect(hits[2].reb == "あめむら")
    }

    @Test("clarms the sokuon the user typed")
    func romajiSokuon() throws {
        let outcome = try search("furoshiki")

        let hit = try #require(outcome.hits.first)

        #expect(hit.entSeq == 1_500_150)
        #expect(hit.reb == "ふろしき")
        #expect(hit.matchKind == .exact)
        #expect(hit.matchedField == .reb)
        #expect(hit.keb == "風呂敷")
    }

    @Test("a full romaji spelling reaches the headword it spells")
    func romajiQueryExact() throws {
        let mae = try #require(try search("mae").hits.first)

        #expect(mae.entSeq == 9_990_060)
        #expect(mae.matchKind == .exact)
        #expect(mae.matchedField == .reb)
        // `mae` is two kana, so the reading is covered whole.
        #expect(mae.highlightRange == 0 ..< 2)
    }

    @Test("a romaji prefix keeps the typed span, not the matched mora")
    func romajiQueryPrefix() throws {
        let ma = try #require(try search("ma").hits.first)

        #expect(ma.entSeq == 9_990_060)
        #expect(ma.matchKind == .prefix)
        #expect(ma.highlightRange == 0 ..< 1)
    }

    @Test("a romaji stem nothing completes stays empty")
    func romajiQueryWithoutCompletion() throws {
        // Nothing in the fixture starts with まけ, so an expansion that matched
        // anything here would be a bug rather than coverage.
        #expect(try search("mak").isEmpty)
    }

    @Test("reads an inflected form through the tokenizer's lemma")
    func lemmaRetry() throws {
        let sut = DictionarySearchEngine(
            resolveDatabase: { [url = databaseURL] in url },
            tokenize: { _ in
                [DictionaryToken(
                    text: "あめた", start: 0, end: 3,
                    reading: "あめた", base: "あめ", pos: "n", bound: false
                )]
            }
        )
        defer { sut.close() }

        let outcome = try sut.search("あめた", filters: DictionarySearchFilters())
        let hit = try #require(outcome.hits.first { candidate in
            candidate.entSeq == 1_153_520
        })

        #expect(hit.matchKind == .lemma)
        // The badge explains a lemma row; nothing the user typed is lit up.
        #expect(hit.highlightRange == nil)
        // 飴 is kanji-written, but the lemma probe matched the *kana* row
        // (`headwords.text = 'あめ'`), so the reading is what lights up.
        #expect(hit.matchedField == .reb)
        #expect(hit.keb == "飴")
        #expect(hit.reb == "あめ")
        #expect(hit.matchKind.badgeLabel == "LEMMA")
    }

    @Test("skips a bound token's lemma, which is about a word never searched")
    func lemmaSkipsBoundTokens() throws {
        let sut = DictionarySearchEngine(
            resolveDatabase: { [url = databaseURL] in url },
            tokenize: { _ in
                [DictionaryToken(
                    text: "あめ", start: 0, end: 2,
                    reading: "あめ", base: "あめ", pos: "助動詞", bound: true
                )]
            }
        )
        defer { sut.close() }

        let outcome = try sut.search("あめ", filters: DictionarySearchFilters())

        #expect(outcome.hits.map(\.entSeq) == [1_153_520, 9_990_030, 9_990_100, 15_668_307])
        #expect(outcome.hits.allSatisfy { hit in hit.matchKind != .lemma })
    }

    // MARK: Gloss stage

    @Test("a whole-gloss match is a word-boundary hit")
    func glossWordBoundaryHit() throws {
        let bridge = try #require(try search("bridge").hits.first)

        #expect(bridge.entSeq == 1_237_410)
        #expect(bridge.matchKind == .glossWordBoundary)
        #expect(bridge.matchedField == .gloss)
        #expect(bridge.glossPreview.first == "bridge")
        #expect(bridge.highlightRange == 0 ..< 6)
    }

    @Test("an opening partial match grades below a whole word")
    func glossPrefixHit() throws {
        // "present" opens the gloss without filling it — the opening boundary is
        // real, it just is not at the end. Word-boundary needs both sides.
        let present = try #require(try search("present").hits.first)

        #expect(present.entSeq == 1_002_500)
        #expect(present.matchKind == .glossPrefix)
        #expect(present.glossPreview.first == "present brought by a visitor")
        #expect(present.highlightRange == 0 ..< 7)
    }

    @Test("grades a sense column per gloss, not per column")
    func glossGradedPerGloss() throws {
        // `candy` is a whole word in "(hard) candy" even though the stored
        // column goes on with "; toffee", so grading the column as a string
        // would bury it.
        let candy = try #require(try search("candy").hits.first)

        #expect(candy.entSeq == 1_153_520)
        #expect(candy.matchKind == .glossWordBoundary)
        #expect(candy.glossPreview.first == "(hard) candy")
        #expect(candy.highlightRange == 7 ..< 12)
        #expect(MatchHighlight.range(of: "candy", in: "(hard) candy") == 7 ..< 12)
    }

    @Test("orders bare substring hits by ent_seq under the tighter tiers")
    func glossSubstringHits() throws {
        // "ice" sits inside "disservice" and inside "rice-sugar": bare
        // substrings, ordered by ent_seq because the tiers all agree.
        let ice = try search("ice").hits

        #expect(ice.count == 2)
        #expect(ice.map(\.entSeq) == [1_002_500, 1_153_520])
        #expect(ice.allSatisfy { hit in hit.matchKind == .glossSubstring })
        #expect(ice.first?.matchKind.badgeLabel == "GLOSS")
        #expect(ice.first?.glossPreview.first == "disservice")
        #expect(ice.last?.glossPreview.first == "rice-sugar")
        // The highlight points into the string the row renders.
        #expect(MatchHighlight.range(of: "ice", in: "rice-sugar") == ice.last?.highlightRange)
    }

    @Test("matches glosses case-insensitively, as the SQL LIKE does")
    func glossCaseInsensitive() throws {
        let lower = try search("candy")
        let upper = try search("CANDY")
        #expect(upper.hits.map(\.entSeq) == lower.hits.map(\.entSeq))

        let hit = try #require(upper.hits.first)
        #expect(hit.glossPreview.first == "(hard) candy")
        #expect(try MatchHighlight.range(of: "candy", in: #require(hit.glossPreview.first))
            == hit.highlightRange)
    }

    @Test("treats LIKE wildcards as literal text", arguments: ["brid%", "br_dge", "bridge\\"])
    func glossEscaping(query: String) throws {
        // Unescaped, `brid%` would match `bridge`; escaped it looks for a
        // literal `brid%` and finds nothing. An underscore is a single-character
        // wildcard unescaped, and a backslash is the escape character itself.
        #expect(try search(query).isEmpty)
    }

    @Test("answers a name query under the Names scope, by spelling and by reading",
          arguments: ["Kimura", "きむら"])
    func nameReachableUnderNames(query: String) throws {
        let names = try search(query, scope: .names)

        #expect(names.hits.map(\.entSeq) == [15_668_306])
        #expect(names.hits.first?.isName == true)
    }

    @Test("never answers a name query under Words", arguments: ["Kimura", "きむら"])
    func nameUnreachableUnderWords(query: String) throws {
        #expect(try search(query, scope: .words).isEmpty)
    }

    @Test("keeps the name reachable under the default scope")
    func nameReachableUnderAll() throws {
        #expect(try search("Kimura").hits.map(\.entSeq) == [15_668_306])
    }

    @Test("gates the gloss stage on a Latin query of three letters or more")
    func glossGate() {
        #expect(DictionarySearchEngine.acceptsGlossQuery("ab") == false)
        #expect(DictionarySearchEngine.acceptsGlossQuery("abc") == true)
        #expect(DictionarySearchEngine.acceptsGlossQuery("abc123") == true)
        #expect(DictionarySearchEngine.acceptsGlossQuery("負ける") == false)
        #expect(DictionarySearchEngine.acceptsGlossQuery("ま") == false)
    }

    // MARK: Filters

    @Test("splits words from names on the ingest offset")
    func scopePredicate() {
        // The predicate itself, at the ingest offset that separates the two
        // dictionaries: JMnedict ids arrive as `id + 10M`.
        let boundary = DictionaryContent.nameSeqOffset
        #expect(boundary == 10_000_000)

        let all = DictionarySearchFilters()
        #expect(all.admits(entSeq: boundary - 1))
        #expect(all.admits(entSeq: boundary))
        #expect(all.admits(entSeq: 15_668_306))
        #expect(DictionarySearchFilters(scope: .words).admits(entSeq: boundary) == false)
        #expect(DictionarySearchFilters(scope: .names).admits(entSeq: boundary - 1) == false)
        #expect(DictionarySearchFilters(scope: .names).admits(entSeq: 15_668_306))
    }

    @Test("labels the scope switcher's cases in display order")
    func scopeLabels() {
        #expect(DictionarySearchFilters.Scope.allCases.map(\.label) == ["All", "Words", "Names"])
        // The mode switcher binds the scope by identity, not by index.
        #expect(DictionarySearchFilters.Scope.allCases.map(\.id) == ["All", "Words", "Names"])
    }

    @Test("drops uncommon entries under common-only")
    func commonOnlyFilter() throws {
        let words = try search("あめ", commonOnly: true)

        // 雨村/あめむら is common too, and survives the prefix tier alongside 飴.
        #expect(words.hits.map(\.entSeq) == [1_153_520, 9_990_100])
    }

    @Test("common-only empties the Names scope, which is why the toggle greys out")
    func commonOnlyNamesEmpty() throws {
        // Names are never common, so the combination is structurally empty.
        #expect(try search("きむら", scope: .names, commonOnly: true).isEmpty)
    }

    @Test("a blank query never reaches the ladder", arguments: ["", "   "])
    func blankQuerySkipsTheLadder(query: String) throws {
        let sut = DictionarySearchEngine(resolveDatabase: { [url = databaseURL] in url })
        defer { sut.close() }

        #expect(try sut.search(query, filters: DictionarySearchFilters()) == .empty)
    }

    // MARK: Envelope

    @Test("reports the pre-window total, which equals the row count when nothing is cut")
    func outcomeEnvelope() throws {
        let outcome = try search("あめ")

        #expect(outcome.matchedCount == outcome.hits.count)
        #expect(outcome.matchedCount == 4)
        #expect(outcome.hits.count == 4)
        #expect(outcome.saturated == false)
        #expect(outcome.isEmpty == false)
    }

    @Test("the empty outcome is the zero value a blank query publishes")
    func emptyOutcome() {
        #expect(DictionarySearchOutcome.empty.isEmpty)
        #expect(DictionarySearchOutcome.empty.matchedCount == 0)
    }

    @Test("orders identically for the same query, so no row moves between keystrokes")
    func determinism() throws {
        let first = try search("あ")
        let second = try search("あ")

        #expect(first == second)
    }

    // MARK: Errors

    @Test("reports a missing database as a fault, not as no matches")
    func missingDatabase() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("mimidasu-search-missing-\(UUID().uuidString).sqlite")
        let sut = DictionarySearchEngine(resolveDatabase: { missing })
        defer { sut.close() }

        #expect(throws: DictionarySearchError.databaseMissing) {
            try sut.search("食べる", filters: DictionarySearchFilters())
        }
    }

    @Test("reports a closed engine, and stays closed")
    func closedEngine() throws {
        let sut = DictionarySearchEngine(resolveDatabase: { [url = databaseURL] in url })

        sut.close()

        #expect(throws: DictionarySearchError.databaseClosed) {
            try sut.search("食べる", filters: DictionarySearchFilters())
        }
        // Idempotent, like `JMDictLookup.close()`.
        sut.close()
    }

    @Test("maps an unavailable database onto the same missing case a path does")
    func errorTranslation() {
        #expect(DictionarySearchError(.unavailable) == .databaseMissing)
        let failure = SQLiteDatabase.Error.sqlite(code: 11, message: "database disk image is malformed")
        #expect(DictionarySearchError(failure)
            == .sqlite(code: 11, message: "database disk image is malformed"))
    }

    @Test("translates a SQLite failure onto the typed error")
    func corruptDatabase() throws {
        let corrupt = FileManager.default.temporaryDirectory
            .appendingPathComponent("mimidasu-search-corrupt-\(UUID().uuidString).sqlite")
        try Data("not a database".utf8).write(to: corrupt)
        defer { try? FileManager.default.removeItem(at: corrupt) }
        let sut = DictionarySearchEngine(resolveDatabase: { corrupt })
        defer { sut.close() }

        #expect(throws: DictionarySearchError.self) {
            try sut.search("食べる", filters: DictionarySearchFilters())
        }
    }

    // MARK: Cancellation

    @Test("a cancelled task abandons the scan instead of finishing it")
    func cancelledTaskThrows() async {
        // The sleep is the cancellation checkpoint: whether cancel lands before
        // the task starts or while it sleeps, the engine's check below runs in
        // a cancelled task every time.
        let task = Task {
            try? await Task.sleep(for: .seconds(60))
            try DictionarySearchEngine.checkCancellation()
        }

        task.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }

    @Test("a live task passes the check")
    func liveTaskPassesCancellationCheck() {
        #expect(throws: Never.self) {
            try DictionarySearchEngine.checkCancellation()
        }
    }
}
