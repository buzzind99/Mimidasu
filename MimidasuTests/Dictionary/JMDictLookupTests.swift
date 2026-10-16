import Foundation
@testable import Mimidasu
import Testing

@Suite("JMDictLookup")
final class JMDictLookupTests {
    private let databaseURL: URL
    /// Shared with `JMDictLookupHeadwordRowTests`, which extends this suite
    /// rather than rebuilding the fixture.
    let engine: JMDictLookup

    init() throws {
        let built = try JMDictFixtureDatabase.build()
        databaseURL = built.url
        engine = JMDictLookup(resolveDatabase: { [url = built.url] in url })
    }

    deinit {
        // Close before unlinking — SQLite warns loudly about vnodes removed
        // underneath an open handle.
        engine.close()
        JMDictFixtureDatabase.Built(url: databaseURL).remove()
    }

    // MARK: Hits

    @Test("hits the lemma candidate with pitch and JLPT from the matched headword row")
    func lemmaHit() throws {
        let result = try #require(try engine.lookup(LookupCandidate(text: "食べる")))
        #expect(result.matched == "食べる")
        #expect(result.entries.count == 1)

        let entry = try #require(result.entries.first)
        #expect(entry.entSeq == 1_358_280)
        #expect(entry.keb == "食べる")
        #expect(entry.reb == "たべる")
        #expect(entry.common)
        #expect(entry.jlpt == 5)
        #expect(entry.hatsuon == "た~べる")
        #expect(entry.accPatts == "2")
        #expect(entry.zoPatts == "LHLL")
        #expect(entry.senses.count == 2)
        #expect(entry.senses[0].pos == "v1,vt")
        #expect(entry.senses[0].glosses == ["to eat"])
        #expect(entry.senses[1].glosses == ["to live on (e.g. a salary)", "to live off", "to subsist on"])
    }

    @Test("hits the kana-only gairaigo entry with commonness from the kana object")
    func kanaOnlyHit() throws {
        let result = try #require(try engine.lookup(LookupCandidate(text: "アルバイト")))
        #expect(result.entries.count == 1)

        let entry = try #require(result.entries.first)
        #expect(entry.entSeq == 1_019_420)
        #expect(entry.keb == nil)
        #expect(entry.reb == "アルバイト")
        #expect(entry.common)
        #expect(entry.jlpt == 4)
        #expect(entry.hatsuon == "あるばいと")
        #expect(entry.accPatts == "3")
        #expect(entry.zoPatts == "LHHLLL")
        #expect(entry.senses[0].pos == "n,vs,vi")
        #expect(entry.senses[0].glosses == ["part-time job", "side job"])
    }

    @Test("hits through a halfwidth spelling, folded onto the stored fullwidth row")
    func halfwidthSpellingHit() throws {
        // The probe composes at the SQL boundary, so a halfwidth tap answers
        // like its fullwidth spelling: ｶﾀ語 composes onto the stored カタ語
        // keb row, and ﾊﾟｲﾅｯﾌﾟﾙ's voiced/semi-voiced marks (ﾊﾟ → ハ + ゛)
        // compose onto 9990150's kana-only パイナップル row.
        let kebMix = try #require(try engine.lookup(LookupCandidate(text: "ｶﾀ語")))
        #expect(kebMix.matched == "ｶﾀ語")
        #expect(kebMix.entries.first?.keb == "カタ語")

        let kanaOnly = try #require(try engine.lookup(LookupCandidate(text: "ﾊﾟｲﾅｯﾌﾟﾙ")))
        #expect(kanaOnly.matched == "ﾊﾟｲﾅｯﾌﾟﾙ")

        let entry = try #require(kanaOnly.entries.first)
        #expect(entry.entSeq == 9_990_150)
        #expect(entry.reb == "パイナップル")
        #expect(entry.common)
    }

    @Test("resolves a fullwidth-Latin tap onto the stored normalized spelling")
    func fullwidthLatinHit() throws {
        // The search row's headword shape: upstream stores ＴＫＧ fullwidth,
        // ingestion normalizes it to TKG, and the probe folds the tap at the
        // SQL boundary — the direction the shipped database's equality seeks
        // live or die by.
        let result = try #require(try engine.lookup(LookupCandidate(text: "ＴＫＧ")))
        #expect(result.matched == "ＴＫＧ")

        let entry = try #require(result.entries.first)
        #expect(entry.entSeq == 9_990_160)
        #expect(entry.keb == "TKG")
        #expect(entry.reb == "ティー・ケー・ジー")
        #expect(entry.senses[0].glosses == ["tamago kake gohan"])
    }

    @Test("resolves the ASCII spelling the normalized entry hands back")
    func normalizedLatinHit() throws {
        // The expand path: the search row renders the normalized keb, so the
        // candidate text arrives already canonical and must still find its
        // own row.
        let result = try #require(try engine.lookup(LookupCandidate(text: "TKG")))

        let entry = try #require(result.entries.first)

        #expect(entry.entSeq == 9_990_160)
        #expect(entry.keb == "TKG")
    }

    @Test("orders senses by ord and splits the stored joins back apart")
    func multiSenseOrder() throws {
        let result = try #require(try engine.lookup(LookupCandidate(text: "あめ")))

        let entry = try #require(result.entries.first { entry in entry.entSeq == 1_153_520 })

        #expect(entry.senses.map(\.glosses.first) == ["(hard) candy", "rice-sugar", "amber"])
        #expect(entry.senses[2].misc == "abbr")
        #expect(entry.senses[1].pos == "n")
    }

    // MARK: Restriction filtering

    @Test("drops kanji-restricted senses: foreign restriction, empty list; keeps unrestricted")
    func kanjiRestrictionFiltering() throws {
        let result = try #require(try engine.lookup(LookupCandidate(text: "仮語")))

        let entry = try #require(result.entries.first)

        #expect(entry.entSeq == 9_990_010)
        #expect(entry.senses.count == 1)
        #expect(entry.senses[0].glosses == ["applies to every writing"])
    }

    @Test("drops the kana-restricted sense for a reading outside the restriction")
    func kanaRestrictedSenseDropped() throws {
        let result = try #require(try engine.lookup(LookupCandidate(text: "あしこ")))

        let entry = try #require(result.entries.first)

        #expect(entry.entSeq == 1_000_320)
        #expect(entry.senses.count == 2)
        #expect(entry.senses.map(\.glosses.first) == ["there", "that far"])
    }

    @Test("keeps the kana-restricted sense for a reading inside the restriction")
    func kanaRestrictedSenseKept() throws {
        let result = try #require(try engine.lookup(LookupCandidate(text: "あそこ")))

        let entry = try #require(result.entries.first)

        #expect(entry.senses.count == 3)
    }

    @Test("drops an entry whose every sense is filtered away for the candidate")
    func fullyFilteredEntryDropped() throws {
        #expect(try engine.lookup(LookupCandidate(text: "幽語")) == nil)
    }

    // MARK: Misses

    @Test("returns nil for a candidate with no headword")
    func noHitReturnsNil() throws {
        #expect(try engine.lookup(LookupCandidate(text: "きのこっぷ")) == nil)
    }

    @Test("returns nil for an empty candidate list")
    func emptyCandidateListReturnsNil() throws {
        #expect(try engine.lookup([]) == nil)
    }

    // MARK: Candidate ordering

    @Test("first hit wins for display; later hits adding entries are kept as also")
    func orderedCandidates() throws {
        let outcome = try #require(try engine.lookup([
            LookupCandidate(text: "飴"),
            LookupCandidate(text: "あめ")
        ]))

        #expect(outcome.display.matched == "飴")
        #expect(outcome.display.entries.map(\.entSeq) == [1_153_520])
        #expect(outcome.also.map(\.matched) == ["あめ"])
        #expect(outcome.also[0].entries.map(\.entSeq) == [1_153_520, 9_990_030])
    }

    @Test("skips a later candidate that only re-hits already-returned entries")
    func duplicateEntryCandidateSkipped() throws {
        let outcome = try #require(try engine.lookup([
            LookupCandidate(text: "食べる"),
            LookupCandidate(text: "たべる")
        ]))

        #expect(outcome.display.matched == "食べる")
        #expect(outcome.also.isEmpty)
    }

    @Test("sorts also results longest match first")
    func alsoOrderLongestFirst() throws {
        let outcome = try #require(try engine.lookup([
            LookupCandidate(text: "橋"),
            LookupCandidate(text: "たべる"),
            LookupCandidate(text: "アルバイト"),
            LookupCandidate(text: "飴")
        ]))

        #expect(outcome.display.matched == "橋")
        // アルバイト (5) outranks たべる (3) outranks 飴 (1), regardless of
        // the order the candidates arrived in.
        #expect(outcome.also.map(\.matched) == ["アルバイト", "たべる", "飴"])
    }

    @Test("equal-length also results keep candidate order")
    func alsoEqualLengthKeepsCandidateOrder() throws {
        let outcome = try #require(try engine.lookup([
            LookupCandidate(text: "橋"),
            LookupCandidate(text: "飴"),
            LookupCandidate(text: "雨")
        ]))

        #expect(outcome.display.matched == "橋")
        #expect(outcome.also.map(\.matched) == ["飴", "雨"])
    }

    @Test("an out-of-order non-split after splits folds the splits into also")
    func outOfOrderNonSplitFoldsSplitsIntoAlso() throws {
        // Defensive: expansion order places non-splits first, but a caller
        // that violates it must not drop the split hits already collected.
        // Lives here, not in the display suite: it drives the engine's typed
        // candidate interface directly, which resolve never produces.
        let resolution = try engine.lookup([
            ExpansionCandidate(
                candidate: LookupCandidate(text: "雨"), origin: .split
            ),
            ExpansionCandidate(
                candidate: LookupCandidate(text: "お"), origin: .tappedSurface
            )
        ])

        guard case let .found(outcome) = resolution else {
            Issue.record("expected found, got \(resolution)")
            return
        }
        #expect(outcome.display.matched == "お")
        #expect(outcome.also.map(\.matched) == ["雨"])
    }

    // MARK: Candidate kind

    @Test("derives the candidate kind from the script", arguments: [
        ("食べる", LookupCandidate.Kind.kanji),
        ("たべる", LookupCandidate.Kind.kana),
        ("アルバイト", LookupCandidate.Kind.kana),
        ("𠮷野家", LookupCandidate.Kind.kanji),
        ("A", LookupCandidate.Kind.kana)
    ])
    func kindDerivation(text: String, kind: LookupCandidate.Kind) {
        #expect(LookupCandidate(text: text).kind == kind)
    }

    // MARK: Infrastructure errors

    @Test("throws databaseMissing when no database resolves")
    func missingDatabaseThrows() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("mimidasu-jmdict-missing-\(UUID().uuidString).sqlite")
        let sut = JMDictLookup(resolveDatabase: { missing })

        let thrown = #expect(throws: JMDictLookupError.self) {
            try sut.lookup(LookupCandidate(text: "食べる"))
        }

        #expect(thrown == .databaseMissing)
    }

    @Test("throws databaseClosed after close()")
    func closedHandleThrows() throws {
        _ = try engine.lookup(LookupCandidate(text: "食べる"))
        engine.close()

        let thrown = #expect(throws: JMDictLookupError.self) {
            try engine.lookup(LookupCandidate(text: "食べる"))
        }

        #expect(thrown == .databaseClosed)
    }

    @Test("throws a sqlite error for a corrupt database file")
    func corruptDatabaseThrows() throws {
        let corrupt = FileManager.default.temporaryDirectory
            .appendingPathComponent("mimidasu-jmdict-corrupt-\(UUID().uuidString).sqlite")
        try Data("definitely not a sqlite database".utf8).write(to: corrupt)
        defer { try? FileManager.default.removeItem(at: corrupt) }
        let sut = JMDictLookup(resolveDatabase: { corrupt })

        let thrown = try #require(
            #expect(throws: JMDictLookupError.self) {
                try sut.lookup(LookupCandidate(text: "食べる"))
            }
        )

        guard case .sqliteError = thrown else {
            Issue.record("expected .sqliteError, got \(thrown)")
            return
        }
    }

    @Test("error descriptions are actionable copy per case")
    func errorDescriptions() {
        #expect(
            JMDictLookupError.databaseMissing.errorDescription
                == "JMDict database not found; the dictionary may still be preparing."
        )
        #expect(
            JMDictLookupError.databaseClosed.errorDescription
                == "JMDict database has been closed."
        )
        #expect(
            JMDictLookupError.databaseCorrupt.errorDescription
                == "JMDict database is corrupt."
        )
        #expect(
            JMDictLookupError.sqliteError(code: 11, message: "corrupt").errorDescription
                == "JMDict database error 11: corrupt."
        )
    }

    @Test("default database resolution prefers the prepared location, then the debug checkout")
    func defaultDatabaseResolution() {
        let destination = URL(fileURLWithPath: "/tmp/dest")
        let prepared = destination.appendingPathComponent(JMDictPin.preparedFileName)

        // The prepared location wins whenever it exists.
        #expect(
            JMDictLookup.defaultDatabaseURL(destination: destination, fileExists: { _ in true })
                == prepared
        )

        // Without it, the debug checkout (repo-anchored build/<tag>.dev.sqlite)
        // resolves. The dev artifact, not the raw build output: the raw one has
        // no gloss index, and a lookup that resolved it would run every Latin
        // gloss search against a database the stage cannot query.
        #if DEBUG
            let checkout = DictionaryStore.debugRepoURL(JMDictPin.debugCheckoutPath)
            #expect(
                JMDictLookup.defaultDatabaseURL(
                    destination: destination,
                    fileExists: { url in url == checkout }
                ) == checkout
            )
            #expect(checkout.lastPathComponent == JMDictPin.devArtifactFileName)
        #endif

        // Neither resolves → nil (lookups then throw .databaseMissing).
        #expect(
            JMDictLookup.defaultDatabaseURL(destination: destination, fileExists: { _ in false }) == nil
        )
    }

    /// A path SQLite cannot open at all (a directory) fails `sqlite3_open_v2`
    /// itself — the never-cached failure branch. Each act is one lookup; two
    /// sequential acts assert the second call retries (and fails again):
    /// failed opens must not latch the engine closed.
    @Test("an unopenable database path throws and stays retryable")
    func unopenableDatabasePathThrows() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mimidasu-jmdict-unopenable-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sut = JMDictLookup(resolveDatabase: { directory })

        let firstThrown = try thrownForOneLookup(sut)
        let retryThrown = try thrownForOneLookup(sut)

        #expect(retryThrown == firstThrown, "the failure must repeat on retry")
    }

    /// One lookup against `sut`. SQLite surfaces an unopenable path as
    /// either the typed missing case or a CANTOPEN sqlite error, depending
    /// on whether it handed back a handle — both are accepted here.
    private func thrownForOneLookup(_ sut: JMDictLookup) throws -> JMDictLookupError {
        let thrown = try #require(
            #expect(throws: JMDictLookupError.self) {
                try sut.lookup(LookupCandidate(text: "食べる"))
            }
        )
        #expect(
            thrown == .databaseMissing || isSQLiteError(thrown),
            "expected .databaseMissing or .sqliteError, got \(thrown)"
        )
        return thrown
    }

    private func isSQLiteError(_ error: JMDictLookupError) -> Bool {
        if case .sqliteError = error {
            return true
        }
        return false
    }

    /// A headword row whose entry row is gone is a corrupt database, not a
    /// miss — the lookup throws instead of returning nil. Built over the
    /// shared orphan-headword fixture, which carries just the three-table
    /// shape this path needs.
    @Test("a headword row without its entry throws database-corrupt")
    func orphanHeadwordRowThrows() throws {
        let built = try JMDictFixtureDatabase.orphanHeadword()
        let sut = JMDictLookup(resolveDatabase: { [url = built.url] in url })
        defer {
            sut.close()
            built.remove()
        }

        let thrown = try #require(
            #expect(throws: JMDictLookupError.self) {
                try sut.lookup(LookupCandidate(text: "孤語"))
            }
        )

        guard case .databaseCorrupt = thrown else {
            Issue.record("expected .databaseCorrupt, got \(thrown)")
            return
        }
    }

    // MARK: Cancellation

    /// The cancel lands before the task is awaited, so the flag is already
    /// set when the candidate loop reaches its first checkpoint — the throw
    /// never bets on how fast the fixture database answers. The engine has
    /// no catch for it, so the error surfaces to the caller untouched.
    @Test("a cancelled lookup throws instead of finishing")
    func cancellation() async throws {
        let engine = engine
        let task = Task {
            _ = try engine.lookup(LookupCandidate(text: "食べる"))
        }
        task.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }
}

// MARK: - Typed error mapping

extension JMDictLookupTests {
    @Test("maps SQLite errors onto the typed lookup errors")
    func sqliteErrorMapping() {
        #expect(JMDictLookupError(SQLiteDatabase.Error.unavailable) == .databaseMissing)
        #expect(
            JMDictLookupError(SQLiteDatabase.Error.sqlite(code: 11, message: "corrupt"))
                == .sqliteError(code: 11, message: "corrupt")
        )
    }
}
