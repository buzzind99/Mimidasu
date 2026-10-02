@testable import Mimidasu
import Testing

/// The segment's own kana reading, the rule the dictionary tap's ranking reads
/// off a rendered segment: the furigana when the annotator aligned one, the
/// surface when it is kana-only, and nothing at all when there is no kana to
/// read.
@Suite("ReadingSegment kana reading")
struct ReadingSegmentKanaReadingTests {

    private func segment(
        _ surface: String, furigana: String? = nil
    ) -> ReadingSegment {
        ReadingSegment(surface: surface, romaji: surface, furigana: furigana)
    }

    @Test("a kanji run reads as its aligned furigana")
    func readsFurigana() {
        #expect(segment("海", furigana: "うみ").kanaReading == "うみ")
    }

    @Test("a kana run is its own reading")
    func readsKanaSurface() {
        #expect(segment("ありがとう").kanaReading == "ありがとう")
    }

    @Test("an empty furigana falls through to the surface rule")
    func ignoresEmptyFurigana() {
        #expect(segment("海", furigana: "").kanaReading == nil)
    }

    @Test("a kanji run with no reading carries none")
    func readsNothingWithoutKana() {
        #expect(segment("祝").kanaReading == nil)
    }

    @Test("an empty surface carries none", arguments: ["", "123", "…"])
    func readsNothingWithoutKanaSurface(surface: String) {
        #expect(segment(surface).kanaReading == nil)
    }
}
