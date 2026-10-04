import Foundation
@testable import Mimidasu
import Testing

// MARK: - Stray-kana base trust

/// The lexicon lexes some stray kana as conjugated verbs (ち → ちる, っ → く),
/// and the bogus base once leaked past a missed surface into the tap lookup's
/// lemma candidate — an unrelated 散る/句 card for ASR garble — and into the
/// favorites lemma match. A single kana scalar is never an inflected form, so
/// its base only survives when it restates the surface.
@Suite("ReadingAnnotator stray-kana base trust")
struct ReadingAnnotatorStrayKanaBaseTests {

    @Test("a stray single-kana token loses the lexicon's bogus verb base",
          arguments: [("ち", "ちる"), ("っ", "く")])
    func strayKanaLosesBogusBase(surface: String, base: String) throws {
        let annotator = makeAnnotator(
            [token(surface, start: 0, reading: surface, base: base, pos: "動詞")]
        )

        let segments = try #require(annotator.segments(for: surface))

        #expect(segments.map(\.surface) == [surface])
        #expect(segments.map(\.lemma) == [nil])
    }

    @Test("a single-kana base that restates the surface is kept")
    func restatingSingleKanaBaseKept() throws {
        let annotator = makeAnnotator(
            [token("は", start: 0, reading: "は", base: "は", pos: "助詞")]
        )

        let segments = try #require(annotator.segments(for: "は"))

        #expect(segments.map(\.lemma) == ["は"])
    }

    @Test("a kana stem wider than one scalar keeps its base through the sokuon merge")
    func kanaStemKeepsBaseThroughMerge() throws {
        let annotator = makeAnnotator([
            token("いっ", start: 0, reading: "いっ", base: "いく", pos: "動詞"),
            token("た", start: 2, reading: "た", base: "た", pos: "助動詞")
        ])

        let segments = try #require(annotator.segments(for: "いった"))

        #expect(segments.map(\.surface) == ["いった"])
        #expect(segments.map(\.lemma) == ["いく"])
    }

    @Test("a sokuon merge anchored on a stray kana token carries no base")
    func mergedStraySokuonCarriesNoBase() throws {
        let annotator = makeAnnotator([
            token("ち", start: 0, reading: "ち", base: "ちる", pos: "動詞"),
            token("っ", start: 1, reading: "っ", base: "く", pos: "動詞"),
            token("スマブラスマブラ", start: 2)
        ])

        let segments = try #require(annotator.segments(for: "ちっスマブラスマブラ"))

        #expect(segments.map(\.surface) == ["ち", "っスマブラスマブラ"])
        #expect(segments.map(\.lemma) == [nil, nil])
    }
}
