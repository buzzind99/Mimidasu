import Foundation
@testable import Mimidasu
import Testing

// MARK: - Live numeral overrides

/// The numeral overrides against the real IPADIC model: the tokenizer
/// splits each of these into numeral + counter, so the reading is one the
/// fusion manufactures, and the whole-surface table has to correct it.
/// `LiveDictionaryRuntime` backs the suite (prepared dictionary, else the
/// fetched model decompressed once into a temp file).
@Suite("ReadingAnnotator numeral overrides corpus", .enabled(if: LiveDictionaryRuntime.isAvailable))
struct ReadingAnnotatorOverridesLiveTests {

    private static let annotator = ReadingAnnotator(tokenize: { text in
        LiveDictionaryRuntime.engine?.tokenize(text)
    })

    private func segments(_ text: String) throws -> [ReadingSegment] {
        try #require(Self.annotator.segments(for: text))
    }

    @Test("reads the bound-form 二 in the compound split across four tokens (一人二役 → hitori futayaku)")
    func boundFormNumeralInCompound() throws {
        let segments = try segments("一人二役")

        #expect(describe(segments) == [
            ["一人", "hitori", "ひとり"], ["二役", "futayaku", "ふたやく"]
        ])
    }

    @Test("reads the bound-form numerals the tokenizer splits into numeral + counter",
          arguments: [
              ("二役", "futayaku", "ふたやく"),
              ("一粒", "hitotsubu", "ひとつぶ"),
              ("一組", "hitokumi", "ひとくみ"),
              ("一袋", "hitofukuro", "ひとふくろ"),
              ("七輪", "shichirin", "しちりん"),
              ("六社", "rokusha", "ろくしゃ"),
              ("一挺", "icchou", "いっちょう"),
              ("六種", "rokushu", "ろくしゅ")
          ])
    func boundFormNumerals(input: String, romaji: String, furigana: String) throws {
        let segments = try segments(input)

        #expect(describe(segments) == [[input, romaji, furigana]])
    }

    @Test("reads the surface overrides through an ASR gap and a fullwidth digit (二 役, １ 桁)",
          arguments: [
              ("二 役", "futayaku", "ふたやく"),
              ("１ 桁", "hitoketa", "ひとけた")
          ])
    func overridesThroughGapAndWidth(text: String, romaji: String, furigana: String) throws {
        let segments = try segments(text)

        #expect(describe(segments) == [[text, romaji, furigana]])
    }

    @Test("surfaces concatenate back to the input",
          arguments: [
              "一人二役", "二 役", "１ 桁", "１人組", "一挺", "六種", "六週", "六旬", "三百", "六百間"
          ])
    func concatenateBack(text: String) throws {
        let segments = try segments(text)

        #expect(segments.map(\.surface).joined() == text)
    }
}
