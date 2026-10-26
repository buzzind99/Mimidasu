import Foundation
@testable import Mimidasu
import Testing

/// `JMDictLookup.hasHeadword` over the fixture database: the whole-surface
/// entry gate behind the annotator's fragmentation pass — any headword row
/// (kanji or kana spelling) counts, so a kana-written word the tokenizer
/// lexicon lacks is protected, not fragmented. The probe composes its input
/// (true NFKC) at the SQL boundary, so halfwidth and fullwidth spellings
/// answer identically; one end-to-end test drives it through the
/// annotator's gate as well.
@Suite("JMDictLookup headword gate")
final class JMDictHeadwordGateTests {
    private let databaseURL: URL
    private let engine: JMDictLookup

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

    @Test(
        "hits for a headword spelling folded onto its stored row",
        arguments: [
            "食べる", // kanji headword
            "さご", // kana-only entry, kana spelling
            "サゴ", // katakana shape stored alongside the hiragana
            "ＴＫＧ" // fullwidth-Latin normalized to the stored TKG row
        ]
    )
    func headwordSpellingHits(spelling: String) throws {
        #expect(try engine.hasHeadword(spelling))
    }

    @Test("the annotator's gate keeps a halfwidth name whole through the composed fold")
    func annotatorGateComposesHalfwidthProbe() throws {
        // ﾊﾟｲﾅｯﾌﾟﾙ carries voiced/semi-voiced marks the compatibility
        // mapping alone leaves decomposed (ﾊﾟ → ハ + ゛); the annotator's
        // gate probe must compose back onto the stored パイナップル row
        // before the byte-wise SQL compare, or the covered name fragments.
        // The fake-Set gates used elsewhere can't catch a fold regression —
        // Swift string membership folds canonically — so this runs the real
        // probe over the fixture database.
        let gate = ReadingAnnotator.memoizedHeadwordGate { [engine] surface in
            try engine.hasHeadword(surface)
        }
        let annotator = makeAnnotator([token("ﾊﾟｲﾅｯﾌﾟﾙ", start: 0)], headwordGate: gate)

        let segments = try #require(annotator.segments(for: "ﾊﾟｲﾅｯﾌﾟﾙ"))

        #expect(segments.map(\.surface) == ["ﾊﾟｲﾅｯﾌﾟﾙ"])
    }

    @Test("misses for garble no entry covers")
    func garbleMisses() throws {
        #expect(try engine.hasHeadword("そらしなそらしな") == false)
    }

    /// `hasHeadword` has its own `catch` and its own `openedDatabase` call, so it
    /// earns its own copy of the infrastructure errors rather than borrowing
    /// `lookup`'s — asserted as strongly as the ones in `JMDictLookupTests`,
    /// which pin the exact case rather than merely the error type.
    @Test("throws databaseMissing when no database resolves")
    func missingDatabaseThrows() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("mimidasu-jmdict-missing-\(UUID().uuidString).sqlite")
        let sut = JMDictLookup(resolveDatabase: { missing })

        let thrown = #expect(throws: JMDictLookupError.self) {
            try sut.hasHeadword("食べる")
        }

        #expect(thrown == .databaseMissing)
    }

    @Test("throws a typed sqlite error for a corrupt database")
    func corruptDatabaseThrowsTypedSqliteError() throws {
        let corrupt = FileManager.default.temporaryDirectory
            .appendingPathComponent("mimidasu-jmdict-gate-corrupt-\(UUID().uuidString).sqlite")
        try Data("definitely not a sqlite database".utf8).write(to: corrupt)
        defer { try? FileManager.default.removeItem(at: corrupt) }
        let sut = JMDictLookup(resolveDatabase: { corrupt })

        let thrown = try #require(
            #expect(throws: JMDictLookupError.self) {
                try sut.hasHeadword("食べる")
            }
        )

        guard case .sqliteError = thrown else {
            Issue.record("expected .sqliteError, got \(thrown)")
            return
        }
    }
}
