import Foundation
@testable import Mimidasu
import Testing

/// The four pager-ranking tiers — surface match, reading match, commonness,
/// ent_seq — pinned on synthetic homographs sharing one headword.
@Suite("JMDictLookup pager ranking")
final class JMDictLookupPagerRankingTests {
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

    @Test("returns both homograph entries with the common one leading")
    func homographRanking() throws {
        let result = try #require(try engine.lookup(LookupCandidate(text: "あめ")))

        #expect(result.entries.map(\.entSeq) == [1_153_520, 9_990_030])
        #expect(result.entries.map(\.common) == [true, false])
    }

    /// The 例子 trio isolates the tail tiebreaks: the common entry carries
    /// the highest ent_seq, so common-first is observable only through the
    /// commonness tier (deleting it reorders the assertion), and the two
    /// uncommon entries pin ent_seq-ascending order within a tier.
    @Test("commonness outranks ent_seq; ent_seq orders within a tier")
    func commonTiebreakOutranksEntSeq() throws {
        let result = try #require(try engine.lookup(LookupCandidate(text: "例子")))

        #expect(result.entries.map(\.entSeq) == [9_990_130, 9_990_120, 9_990_140])
        #expect(result.entries.map(\.common) == [true, false, false])
    }

    @Test("ranks the kana-written entry first when the tap is kana")
    func kanaSurfaceRanksFirst() throws {
        let result = try #require(try engine.lookup(LookupCandidate(text: "さご")))

        #expect(result.entries.map(\.entSeq) == [9_990_080, 9_990_070])
        #expect(result.entries.map(\.keb) == [nil, "叉語"])
    }

    @Test("a katakana tap folds onto the hiragana-written kana-only entry")
    func katakanaSurfaceFolds() throws {
        let result = try #require(try engine.lookup(LookupCandidate(text: "サゴ")))

        #expect(result.entries.map(\.entSeq) == [9_990_080, 9_990_070])
    }

    @Test("ranks the tapped kanji writing's entry first without a reading")
    func kanjiSurfaceRanksFirst() throws {
        let result = try #require(try engine.lookup(LookupCandidate(text: "前")))

        #expect(result.entries.map(\.entSeq) == [9_990_060, 9_990_050])
        #expect(result.entries.map(\.common) == [false, true])
    }

    @Test("ranks the furigana-matching entry first across the shared headword")
    func readingMatchRanksFirst() throws {
        // 先 (saki, uncommon 前 as an alternate writing) and 前 (mae) both
        // match the 前 headword; the tap's furigana names the reading in
        // context, so the uncommon まえ entry outranks the common さき one.
        let result = try #require(try engine.lookup(
            LookupCandidate(text: "前", reading: "まえ")
        ))

        #expect(result.entries.map(\.entSeq) == [9_990_060, 9_990_050])
        #expect(result.entries.map(\.reb) == ["まえ", "さき"])
    }

    @Test("katakana furigana matches the hiragana entry reading")
    func katakanaFuriganaMatchesHiraganaReading() throws {
        let result = try #require(try engine.lookup(
            LookupCandidate(text: "前", reading: "マエ")
        ))

        #expect(result.entries.map(\.entSeq) == [9_990_060, 9_990_050])
    }
}
