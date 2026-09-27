import Foundation
@testable import Mimidasu
import Testing

// MARK: - Lexical reading repairs

/// Whole-reading repairs applied after the token stream: the dictionary's
/// etymological or first-listed readings rewritten to the spoken form a
/// transcript means.
@Suite("ReadingAnnotator lexical reading repairs")
struct ReadingAnnotatorRepairTests {

    @Test("overrides the single token's date reading of 一日 with the duration reading")
    func singleTokenIchinichiOverridesTsuitachi() throws {
        let annotator = makeAnnotator([token("一日", start: 0, reading: "ついたち")])

        let segments = try #require(annotator.segments(for: "一日"))

        #expect(describe(segments) == [["一日", "ichinichi", "いちにち"]])
    }

    @Test("repairs the dictionary's unvoiced reading of the entrance to the spoken rendaku form",
          arguments: [
              ("入口", "iriguchi", "いりぐち"),
              ("入り口", "iriguchi", "いりぐち")
          ])
    func entranceRendakuRepair(text: String, romaji: String, furigana: String) throws {
        let annotator = makeAnnotator([token(text, start: 0, reading: "いりくち")])

        let segments = try #require(annotator.segments(for: text))

        #expect(describe(segments) == [[text, romaji, furigana]])
    }

    @Test("repairs the dictionary's ニッポン reading of 日本 to the common にほん",
          arguments: [
              ("日本", "にっぽん", "nihon", "にほん"),
              ("日本人", "にっぽんじん", "nihonjin", "にほんじん"),
              ("日本一", "にっぽんいち", "nihon'ichi", "にほんいち")
          ])
    func nihonReadingRepair(
        text: String, reading: String, romaji: String, furigana: String
    ) throws {
        let annotator = makeAnnotator([token(text, start: 0, reading: reading)])

        let segments = try #require(annotator.segments(for: text))

        #expect(describe(segments) == [[text, romaji, furigana]])
    }

    @Test("repairs the にっぽん token reading where the dictionary splits the compound (日本中/日本製)",
          arguments: [
              (["日本", "中"], ["にっぽん", "ちゅう"], "日本中",
               [["日本", "nihon", "にほん"], ["中", "chuu", "ちゅう"]]),
              (["日本", "製"], ["にっぽん", "せい"], "日本製",
               [["日本", "nihon", "にほん"], ["製", "sei", "せい"]])
          ])
    func nihonReadingRepairSplitCompounds(
        surfaces: [String], readings: [String?], text: String, expected: [[String?]]
    ) throws {
        let annotator = makeAnnotator(tokens(surfaces, readings: readings))

        let segments = try #require(annotator.segments(for: text))

        #expect(describe(segments) == expected)
    }
}
