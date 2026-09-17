import Foundation
@testable import Mimidasu
import Testing

// MARK: - Number-table resolution

@Suite("ReadingAnnotator number tables")
struct ReadingAnnotatorDigitTests {

    @Test("resolves digit-table runs beyond the live corpus (1000/10000/800/300)",
          arguments: [
              (["1000", "回"], "1000回", "senkai", "せんかい"),
              (["10000", "回"], "10000回", "mankai", "まんかい"),
              (["800", "回"], "800回", "happyakkai", "はっぴゃっかい"),
              (["300", "本"], "300本", "sanbyappon", "さんびゃっぽん")
          ])
    func digitTableSweep(
        surfaces: [String], text: String, romaji: String, furigana: String
    ) throws {
        let annotator = makeAnnotator(tokens(
            surfaces, readings: [nil, surfaces[1] == "回" ? "かい" : "ほん"]
        ))

        let segments = try #require(annotator.segments(for: text))

        #expect(describe(segments) == [[text, romaji, furigana]])
    }

    @Test("re-emits ASR whitespace when a held digit run can't resolve (2026 年)")
    func spacedUnresolvedDigitsReemitGap() throws {
        let annotator = makeAnnotator(spacedTokens(
            ["2026", "年"], readings: [nil, "ねん"]
        ))

        let segments = try #require(annotator.segments(for: "2026 年"))

        #expect(describe(segments) == [
            ["2026", "2026", nil], [" ", " ", nil], ["年", "nen", "ねん"]
        ])
    }

    @Test("recognizes pure numeral surfaces", arguments: [
        ("3", true),
        ("３", true),
        ("三", true),
        ("600", true),
        ("3.5", false),
        ("1回", false),
        ("壱", false),
        ("弐", false),
        ("", false)
    ])
    func numeralRunRecognition(surface: String, expected: Bool) {
        #expect(ReadingAnnotator.isNumeralRun(surface) == expected)
    }

    @Test("fuses the split kanji date 二十+四+日 with its irregular reading (にじゅうよっか)")
    func kanjiSplitNijuuyokka() throws {
        let annotator = makeAnnotator(tokens(
            ["二十", "四", "日"], readings: ["にじゅう", "よん", "にち"]
        ))

        let segments = try #require(annotator.segments(for: "二十四日"))

        #expect(describe(segments) == [["二十四日", "nijuuyokka", "にじゅうよっか"]])
    }
}
