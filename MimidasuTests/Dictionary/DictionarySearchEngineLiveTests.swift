import Foundation
@testable import Mimidasu
import Testing

/// The parts of the ladder the fixture is too small to stage: a prefix scan
/// deep enough to cross the in-loop cancellation interval, a screen that
/// saturates the window, the load-more that widens it, and the bounded-fetch
/// budgets the tuning constants exist to hold. Live-gated — it runs against the
/// pinned prepared database, and disables itself when that is not installed.
@Suite("DictionarySearchEngine live", .enabled(if: InstalledJMDict.url != nil))
struct DictionarySearchEngineLiveTests {
    private func makeEngine() throws -> DictionarySearchEngine {
        DictionarySearchEngine(
            resolveDatabase: { InstalledJMDict.url },
            tokenize: { text in LiveDictionaryRuntime.engine?.tokenize(text) }
        )
    }

    @Test("a query whose exact tier falls short of the window runs every stage")
    func unsaturatedQueryRunsEveryStage() throws {
        let engine = try makeEngine()
        defer { engine.close() }
        // `あ` has 7 exact headwords, so nothing saturates and the prefix scan
        // runs too: the outcome is everything both stages found, capped at the
        // ceiling — which is what makes every click below a reveal rather than a
        // re-run of a 20k-row scan.

        let outcome = try engine.search("あ", filters: DictionarySearchFilters())

        #expect(outcome.saturated == false)
        #expect(outcome.hits.isEmpty == false)
        // The payload is the whole answer, bounded: the only two things that can
        // stop it are a stage that was skipped (it was not) and the ceiling.
        #expect(outcome.hits.count == min(outcome.matchedCount, DictionarySearchEngine.maxRows))
        #expect(outcome.hits.count >= DictionarySearchEngine.pageSize)
        #expect(outcome.matchedCount >= outcome.hits.count)
        // Common entries lead, so a one-mora screen is the useful one.
        #expect(outcome.hits.first?.common == true)
    }

    @Test("a skipped stage shows up as a floor, and only paging grows it")
    func saturationIsAFloorUntilPaged() throws {
        let engine = try makeEngine()
        defer { engine.close() }
        let filters = DictionarySearchFilters()
        let pageSize = DictionarySearchEngine.pageSize
        let narrow = try engine.search("し", filters: filters)
        #expect(narrow.saturated)
        #expect(narrow.hits.count == narrow.matchedCount)

        let deep = try engine.search("し", filters: filters, limit: pageSize * 2)

        // The window outgrew the exact tier, so the stage it had declared
        // invisible ran — and the total jumped by a factor, not a page.
        #expect(deep.saturated == false)
        #expect(deep.matchedCount > pageSize * 2)
        #expect(deep.hits.count == min(deep.matchedCount, DictionarySearchEngine.maxRows))
        // The rows the narrow window held are untouched, in the same order and
        // with the same previews: a stage is skipped only when its rows rank
        // below every row in the window, so a deeper window can only append.
        #expect(Array(deep.hits.prefix(narrow.hits.count)) == narrow.hits)
    }

    @Test("a query whose whole answer is found needs no probe")
    func completeAnswerIsBuiltWhole() throws {
        let engine = try makeEngine()
        defer { engine.close() }

        // `best` matches no headword; every one of its rows comes from the gloss
        // scan, and there is no second scan behind it. Nothing was skipped, so
        // the outcome is the whole answer — which is exactly why paging here
        // only ever reveals rows that are already in hand.
        let outcome = try engine.search("best", filters: DictionarySearchFilters())

        #expect(outcome.saturated == false)
        #expect(outcome.hits.count == outcome.matchedCount)
        #expect(outcome.hits.count > DictionarySearchEngine.pageSize)
        #expect(outcome.hits.allSatisfy { hit in hit.matchedField == .gloss })
    }

    @Test("the reported query's truncated total is marked as a floor")
    func headroomBoundIsPublishedLive() throws {
        let engine = try makeEngine()
        defer { engine.close() }
        let filters = DictionarySearchFilters()

        // The reported case: `ま` matches ~19,600 headword rows, the headroom
        // keeps 8000, and the header read `10402` with no `+` — a total that was
        // short of the answer by 11,000 rows and looked like none of it was.
        let outcome = try engine.search("ま", filters: filters)

        #expect(outcome.truncated)
        #expect(outcome.isFloor)
        // Two Latin characters cannot reach the gloss stage, so no stage was
        // ever skipped and this floor is the bound and only the bound.
        #expect(outcome.saturated == false)
        // The window is not what cleared it, because nothing can.
        let deep = try engine.search("ま", filters: filters, limit: DictionarySearchEngine.maxRows)

        #expect(deep.truncated)
        #expect(deep.saturated == false)
        #expect(deep.matchedCount == outcome.matchedCount)
    }

    @Test("a window past the ceiling returns no more than the ceiling")
    func windowClampsToCeiling() throws {
        let engine = try makeEngine()
        defer { engine.close() }

        let outcome = try engine.search(
            "あ", filters: DictionarySearchFilters(), limit: DictionarySearchEngine.maxRows * 10
        )

        #expect(outcome.hits.count == DictionarySearchEngine.maxRows)
        #expect(outcome.matchedCount >= DictionarySearchEngine.maxRows)
    }

    @Test("a tight query fits one page, so there is nothing to load")
    func tightQueryFits() throws {
        let engine = try makeEngine()
        defer { engine.close() }

        let tight = try engine.search("食べる", filters: DictionarySearchFilters())

        #expect(tight.matchedCount == tight.hits.count)
        #expect(tight.hits.count <= DictionarySearchEngine.pageSize)
        #expect(tight.saturated == false)
    }

    @Test("a deep prefix scan stays bounded and survives cancellation checks")
    func deepPrefixScanIsBounded() throws {
        let engine = try makeEngine()
        defer { engine.close() }

        // One kana reaches past the 512-row cancellation interval in every
        // tier, so the drain loops' checks run without any special setup.
        let outcome = try engine.search("か", filters: DictionarySearchFilters())

        #expect(outcome.hits.isEmpty == false)
        #expect(outcome.matchedCount <= DictionarySearchEngine.prefixScanCeiling)
        // Every survivor's highlight covers exactly the character that was
        // typed, at the front of the field it points at — the range scan's
        // upper bound is the scalar after the last one, and the highlight is
        // what makes that visible. (The entry's own reading is not the field
        // that matched: a か-initial kanji can carry any reading — 華 = はな.)
        #expect(outcome.hits.allSatisfy { hit in hit.highlightRange == 0 ..< 1 })
    }

    @Test("a cancelled search throws instead of finishing")
    func cancellation() async throws {
        let engine = try makeEngine()
        defer { engine.close() }

        let task = Task {
            // Yield so the canceller runs first: the search below is synchronous
            // and would otherwise finish before the cancel lands.
            await Task.yield()
            _ = try engine.search("し", filters: DictionarySearchFilters())
        }
        task.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }

    @Test("the same query twice returns the same rows in the same order",
          arguments: ["あ", "か", "に", "食べる", "tabemono", "bridge"])
    func determinism(query: String) throws {
        let engine = try makeEngine()
        defer { engine.close() }

        let first = try engine.search(query, filters: DictionarySearchFilters())
        let second = try engine.search(query, filters: DictionarySearchFilters())

        #expect(first == second)
    }

    @Test("an English query reaches real glosses")
    func englishGlosses() throws {
        let engine = try makeEngine()
        defer { engine.close() }

        let bridge = try engine.search("bridge", filters: DictionarySearchFilters())

        #expect(bridge.hits.isEmpty == false)
        #expect(bridge.hits.allSatisfy { hit in hit.matchedField == .gloss })
        #expect(bridge.hits.contains { hit in hit.matchKind == .glossWordBoundary })
    }

    @Test("an English phrase reaches the entry whose gloss reads it")
    func englishPhraseReachesGloss() throws {
        let engine = try makeEngine()
        defer { engine.close() }

        // The reported case: `best regards` came back as 42 prefix hits over 42
        // entries (74 scan rows tripping the cap on rows rather than entries),
        // which skipped the gloss stage and hid the two homographs its
        // screenshot was about.
        let outcome = try engine.search("best regards", filters: DictionarySearchFilters())

        #expect(outcome.hits.isEmpty == false)
        #expect(outcome.hits.allSatisfy { hit in hit.matchKind != .prefix })
        for entSeq in [2_835_139, 1_224_890] {
            let hit = try #require(outcome.hits.first { candidate in candidate.entSeq == entSeq })
            #expect(hit.matchKind == .glossWordBoundary)
            #expect(hit.glossPreview.first == "best regards")
            #expect(hit.highlightRange == 0 ..< 12)
        }
        // No loanword noise: the seven senses that read "best regards" and
        // nothing else.
        #expect(outcome.matchedCount == outcome.hits.count)
        #expect(outcome.matchedCount == 7)
    }

    @Test("the romaji the transcript prints reaches the ー and mixed-script readings")
    func prolongedAndMixedScriptFlagships() throws {
        let engine = try makeEngine()
        defer { engine.close() }

        // The typed letters land on plain-vowel kana (ぱあてぃい) and the
        // hiragana spelling of a mixed reading; the readings that store the
        // prolonged-sound mark, and the readings written in both scripts,
        // arrive through the dash variants and the script-switch probes.
        // Each pair is a live row the pre-variant engine answered 0 for.
        let flagships: [(query: String, entSeq: Int64)] = [
            ("paatii", 1_100_760), // パーティー
            ("keeki", 1_047_860), // ケーキ
            ("koohii", 1_049_180), // コーヒー
            ("juusu", 1_065_950), // ジュース
            ("uchiagepaatii", 2_652_980), // うちあげパーティー
            ("ubefurontiadaigaku", 5_742_895) // うべフロンティアだいがく
        ]
        for flagship in flagships {
            let outcome = try engine.search(
                flagship.query, filters: DictionarySearchFilters(),
                limit: DictionarySearchEngine.maxRows * 10
            )
            #expect(
                outcome.hits.contains { hit in hit.entSeq == flagship.entSeq },
                "\(flagship.query) → \(flagship.entSeq)"
            )
        }
    }

    @Test("a mixed-case headword answers the query that folds onto it")
    func caseBearingFlagships() throws {
        let engine = try makeEngine()
        defer { engine.close() }

        // Every row here is one a pre-case engine answered 0 for: the query is
        // lowercased at the SQL boundary, the B-tree orders `ActiveX` outside
        // the range of `activex`, and only the all-caps half was reachable
        // through the uppercase spelling.
        struct Flagship {
            let query: String
            let entSeq: Int
            let kind: DictionarySearchHit.MatchKind
        }
        let flagships = [
            Flagship(query: "activex", entSeq: 5_747_363, kind: .exact), // ActiveX, the exact fold
            Flagship(query: "iphon", entSeq: 5_008_659, kind: .prefix), // iPhone, opened as a prefix
            // The Greek pair runs one search twice — `Α` normalizes to `α` —
            // and is kept deliberately: the second row pins that the typed
            // uppercase form and the folded form answer identically.
            Flagship(query: "α", entSeq: 1_019_520, kind: .exact), // Α, case `lower` never folds
            Flagship(query: "Α", entSeq: 1_019_520, kind: .exact) // the same name, typed in its case
        ]
        for flagship in flagships {
            let outcome = try engine.search(
                flagship.query, filters: DictionarySearchFilters(),
                limit: DictionarySearchEngine.maxRows
            )

            let hit = try #require(
                outcome.hits.first { candidate in candidate.entSeq == flagship.entSeq },
                "\(flagship.query) → \(flagship.entSeq) not found"
            )

            #expect(hit.matchKind == flagship.kind, "\(flagship.query) → \(flagship.entSeq)")
        }
    }

    @Test("every spelling the case fold changes is in the loaded case set")
    func caseSetCoversEveryCaseFoldedSpelling() throws {
        let url = try #require(InstalledJMDict.url)
        let database = try SQLiteDatabase(path: url.path)
        defer { database.close() }

        // The load is two statements whose second half exists because
        // SQLite's `lower()` is ASCII-only: on this corpus the ASCII predicate
        // alone skips 26 rows — the JMnedict Greek-capital names. This is the
        // backstop for the whole arrangement, and it is a corpus walk on
        // purpose (~330 ms): a pin bump that introduces case in a block
        // `nonASCIICaseLoadSQL` does not span has to fail here rather than
        // quietly darken those spellings.
        //
        // The guard's population is the **case** fold — `lowercased()` — not
        // `normalize`'s NFKC fold, on purpose: NFKC-only divergences (ligatures,
        // compatibility symbols) are a separate pre-existing gap this change
        // did not scope in, and widening the guard would turn red for rows
        // the case loads were never designed to carry.
        let statement = try database.statement("SELECT DISTINCT text FROM headwords")
        var folded: Set<String> = []
        while try statement.step() {
            guard let text = statement.optionalText(0),
                  text.lowercased() != text
            else { continue }
            folded.insert(text)
        }

        let loaded = try CaseHeadwordSpellings(db: database)

        // The load is a deliberate superset — spellings already reachable by
        // their own name cost a Set entry and answer nothing wrongly — so the
        // assertion is containment, not equality.
        #expect(folded.subtracting(loaded.reachableSpellings).isEmpty)
    }

    @Test("a gloss whose own text contains the old \"; \" joiner stays whole")
    func embeddedJoinerGlossStaysWhole() throws {
        let engine = try makeEngine()
        defer { engine.close() }

        // 1002890's sense reads "to scoop up (and remove; sand, earth, etc.)"
        // — one gloss whose own text contains the separator revisions before
        // 6 joined senses with. The column splits on the stored joiner, so a
        // gloss carrying the old spelling must reach the preview intact
        // rather than shredded into three bullets.
        let outcome = try engine.search("scoop up", filters: DictionarySearchFilters())

        let hit = try #require(outcome.hits.first { candidate in candidate.entSeq == 1_002_890 })
        #expect(hit.matchedField == .gloss)
        #expect(hit.glossPreview.first == "to scoop up (and remove; sand, earth, etc.)")
    }

    @Test("the scope filter holds against the live names")
    func scopeFilterHolds() throws {
        let engine = try makeEngine()
        defer { engine.close() }

        // Names live above every JMDict row, so Words must not answer a name
        // query the Names scope can.
        let words = try engine.search("田中", filters: DictionarySearchFilters(scope: .words))
        let names = try engine.search("田中", filters: DictionarySearchFilters(scope: .names))

        #expect(words.hits.allSatisfy { hit in !hit.isName })
        #expect(names.hits.allSatisfy { hit in hit.isName })
        #expect(names.hits.isEmpty == false)
    }

    @Test("common-only empties the Names scope, which is why the toggle greys out")
    func commonOnlyWithNames() throws {
        let engine = try makeEngine()
        defer { engine.close() }

        let outcome = try engine.search(
            "し", filters: DictionarySearchFilters(scope: .names, commonOnly: true)
        )

        #expect(outcome.isEmpty)
    }

    @Test("a romaji query reaches the entry it spells")
    func romajiReachesHeadwords() throws {
        let engine = try makeEngine()
        defer { engine.close() }

        let outcome = try engine.search("tabemono", filters: DictionarySearchFilters())
        let hit = try #require(outcome.hits.first { candidate in
            candidate.reb == "たべもの" || candidate.keb == "食べ物"
        })

        #expect(hit.matchKind == .exact)
        #expect(hit.highlightRange != nil)
    }

    @Test("a halfwidth katakana query reaches the fullwidth row")
    func halfwidthFold() throws {
        let engine = try makeEngine()
        defer { engine.close() }

        let outcome = try engine.search("ﾊﾟｲﾅｯﾌﾟﾙ", filters: DictionarySearchFilters())

        #expect(outcome.hits.isEmpty == false)
        #expect(outcome.hits.contains { hit in hit.reb == "パイナップル" })
    }

    @Test("the gloss hit whose row used to dead-end on expand is normalized")
    func glossHitHeadwordIsNormalized() throws {
        // The screenshot scenario: gohan gloss-hits the fullwidth initialism
        // entry. Ingestion normalized its keb to TKG, so the row the hit
        // renders is the spelling the expand lookup can actually resolve —
        // JMDictLookupLiveTests pins that resolution.
        let engine = try makeEngine()
        defer { engine.close() }

        let outcome = try engine.search("gohan", filters: DictionarySearchFilters())
        let hit = try #require(outcome.hits.first { candidate in
            candidate.entSeq == 2_834_407
        })

        #expect(hit.matchKind == .glossWordBoundary)
        #expect(hit.keb == "TKG")
        #expect(hit.headword == "TKG")
    }

    @Test("a numeric headword answers its own digits")
    func numericHeadword() throws {
        let engine = try makeEngine()
        defer { engine.close() }

        let outcome = try engine.search("4649", filters: DictionarySearchFilters())
        let hit = try #require(outcome.hits.first { candidate in candidate.keb == "4649" })

        #expect(hit.matchKind == .exact)
        #expect(hit.reb == "よろしく")
    }

    @Test("a romaji spelling reaches the yoroshiku homographs")
    func yoroshikuRomaji() throws {
        let engine = try makeEngine()
        defer { engine.close() }

        let outcome = try engine.search("yoroshiku", filters: DictionarySearchFilters())
        let hit = try #require(outcome.hits.first { candidate in candidate.keb == "宜しく" })

        #expect(hit.matchKind == .exact)
        #expect(hit.reb == "よろしく")
    }

    @Test("the densest three-character query still answers through the whole ladder")
    func densestGlossQueryAnswers() throws {
        let engine = try makeEngine()
        defer { engine.close() }

        // The end-to-end shape of the "no hit" regression. `ion` is the densest
        // three-character crossing of the word/name offset in the corpus — 47,909
        // sense rows over 46,394 entries — and the gloss stage is the only
        // source of all but a couple of dozen of them. A database adopted
        // without `gloss_fts` throws out of `glossRows` rather than returning
        // empty, and the search state turns that into "no results"; this asserts
        // the ladder itself still fills.
        //
        // It is also `i` + `on` as romaji (いおん / イオン), so the headword
        // stages contribute too — the gloss tier has to dominate the window
        // rather than fill it outright.
        let outcome = try engine.search("ion", filters: DictionarySearchFilters())

        #expect(outcome.hits.isEmpty == false)
        #expect(outcome.hits.count == min(outcome.matchedCount, DictionarySearchEngine.maxRows))
        #expect(outcome.matchedCount > 40000)
        #expect(outcome.hits.filter { hit in hit.matchedField == .gloss }.count > 900)
    }

    @Test("a lowercase initialism reaches its uppercase headword")
    func latinCaseHeadword() throws {
        let engine = try makeEngine()
        defer { engine.close() }

        let outcome = try engine.search("tkg", filters: DictionarySearchFilters())
        let hit = try #require(outcome.hits.first { candidate in
            candidate.entSeq == 2_834_407
        })

        #expect(hit.matchKind == .exact)
        #expect(hit.keb == "TKG")
    }
}
