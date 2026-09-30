import Foundation
@testable import Mimidasu
import Testing

@Suite(
    "ReadingAnnotator collapse corpus sweep",
    .enabled(if: LiveDictionaryRuntime.isAvailable)
)
struct ReadingAnnotatorCollapseSweepLiveTests {

    /// Sentences the rest of the suite does not already pin, checked for the one
    /// property this pass exists to guarantee: nothing left long opens on a
    /// scalar no word can begin with. Each collapses in the real lattice and is
    /// only reachable through the peel, so a pass that stopped peeling leaves
    /// them stranded.
    @Test("a stranded opening is never left unresolved", arguments: peelOnlySentences)
    func strandedOpeningIsResolved(input: String) throws {
        let raw = try #require(DictionaryEngine.shared.tokenize(input))
        let fixed = ReadingAnnotator.repairedTokens(raw, of: input) { window in
            DictionaryEngine.shared.tokenize(window)
        }

        #expect(
            !fixed.contains { token in
                token.reading == nil
                    && token.end - token.start >= ReadingAnnotator.fragmentLengthThreshold
            },
            "left unresolved: \(input) → \(fixed.map(\.text))"
        )
        // The whole stream, not just the long runs: surfaces have to concatenate
        // back to the sentence or every anchored join breaks.
        #expect(tilesText(fixed, input), "seams: \(fixed.map(\.text))")
    }

    /// The same property over a corpus rather than a list, so a shape nobody
    /// thought to name is still covered. Sokuon deletions of these seeds are the
    /// shapes that produce a stranded opening in the first place — dropping the
    /// っ/ッ out of a conjugated verb and handing the rest to the lattice, which
    /// is what `debug/test.md` is.
    ///
    /// Scoped deliberately: the peeled sokuons themselves. The rest of the
    /// suite pins the window cap, the left-context budget and the exact repaired
    /// stream for the recorded sentence, and four separate mutations of those
    /// paths were caught there without this corpus adding anything — so this is
    /// breadth over *inputs*, not a second copy of the ladder's assertions.
    @Test("no shape in the corpus leaves a stranded opening")
    func corpusLeavesNoStrandedOpening() throws {
        var stranded: [String] = []

        for text in Self.corpus() {
            guard let raw = try #require(DictionaryEngine.shared.tokenize(text)) else { continue }
            let fixed = ReadingAnnotator.repairedTokens(raw, of: text) { window in
                DictionaryEngine.shared.tokenize(window)
            }
            let scalars = Array(text.unicodeScalars)
            for token in fixed
                where token.reading == nil
                && token.end - token.start >= ReadingAnnotator.fragmentLengthThreshold
            {
                let surface = String(String.UnicodeScalarView(scalars[token.start ..< token.end]))
                if let first = surface.unicodeScalars.first,
                   ReadingAnnotator.unstartableScalars.contains(first)
                {
                    stranded.append(surface)
                }
            }
        }

        #expect(stranded.isEmpty, "stranded: \(stranded)")
    }

    /// Sentences whose collapses open on a stranded small kana, so only the peel
    /// can resolve them. None of the three appears in another suite.
    private static let peelOnlySentences = [
        "覚えなきゃいけないからとかって。",
        "書かなくちゃいけないことがある。",
        "言わなきゃいけないよ。"
    ]

    private static let seeds = [
        "ちょっとまあいいんだけどさなんでや稲なりだけだからか。",
        "でうそうダンスレッスンが大変でもう覚えなきゃいけないことがめちゃくちゃってそうだよね。"
            + "なんかね悩んでたよね。めっちゃ覚えなきゃいけないからとかって。",
        "ちょっと待ってそれは違うと思うんだよね。",
        "猫が好きです。", "犬が好きです。", "今日はとてもいい天気ですね",
        "会議は明日の午後三時から始まります",
        "そのデータを分析と検証の両方に行います",
        "そうなんですよソピアちゃんも確かあれだったよね",
        "モいモいモいもいモい", "ソラシナソラシカ", "シュワルツェネッガー",
        "あいいいいいいいい", "のじゃのじゃのじゃ", "アルゴリズムです"
    ]

    /// The seeds plus every sokuon deletion of each — 24 sentences, of which 10
    /// collapse in the current lattice and 7 are repaired.
    private static func corpus() -> [String] {
        var out = seeds
        for seed in seeds {
            let scalars = Array(seed.unicodeScalars)
            for (index, scalar) in scalars.enumerated()
                where scalar.value == 0x3063 || scalar.value == 0x30C3
            {
                let kept = Array(scalars[..<index]) + Array(scalars[(index + 1)...])
                out.append(String(String.UnicodeScalarView(kept)))
            }
        }
        return Array(Set(out)).sorted()
    }
}
