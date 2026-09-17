import Foundation
@testable import Mimidasu
import Testing

// MARK: - Surfaces

@Suite("ReadingAnnotator surfaces")
struct ReadingAnnotatorSurfaceTests {

    @Test("surfaces concatenate back to the input across mixed tokens")
    func concatenateBack() throws {
        let text = "600回、桜ですA B𠮷"
        let annotator = makeAnnotator(tokens(
            ["600", "回", "、", "桜", "です", "A", " ", "B", "𠮷"],
            readings: [nil, "かい", nil, "さくら", "です", nil, nil, nil, nil]
        ))

        let segments = try #require(annotator.segments(for: text))

        #expect(segments.map(\.surface).joined() == text)
    }

    @Test("emits a plain run for spans the runtime doesn't cover")
    func gapBecomesPlainRun() throws {
        let text = "あXい"
        let annotator = makeAnnotator([
            token("あ", start: 0, reading: "あ"),
            token("い", start: 2, reading: "い")
        ])

        let segments = try #require(annotator.segments(for: text))

        #expect(describe(segments) == [["あ", "a", nil], ["X", "X", nil], ["い", "i", nil]])
    }

    @Test("trims surrounding whitespace before segmenting")
    func trimsPadding() throws {
        let annotator = makeAnnotator([token("桜", start: 0, reading: "さくら")])

        let segments = try #require(annotator.segments(for: " 桜 "))

        #expect(segments.map(\.surface).joined() == "桜")
    }

    @Test("clamps a token whose end runs past the input")
    func clampsOverlongTokenEnd() throws {
        let annotator = ReadingAnnotator(tokenize: { _ in
            [DictionaryToken(text: "桜", start: 0, end: 5, reading: "さくら")]
        })

        let segments = try #require(annotator.segments(for: "桜"))

        #expect(describe(segments) == [["桜", "sakura", "さくら"]])
    }

    @Test("clamps an out-of-range gap span past the input")
    func clampsOverlongGapSpan() throws {
        let annotator = ReadingAnnotator(tokenize: { _ in
            [
                DictionaryToken(text: "2", start: 0, end: 1, reading: nil),
                DictionaryToken(text: "", start: 5, end: 6, reading: nil)
            ]
        })

        let segments = try #require(annotator.segments(for: "2 "))

        #expect(segments.map(\.surface).joined() == "2")
    }
}
