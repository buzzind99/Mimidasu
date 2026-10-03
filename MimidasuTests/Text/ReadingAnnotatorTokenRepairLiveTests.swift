import Foundation
@testable import Mimidasu
import Testing

// MARK: - Live collapse-repair corpus

/// The collapse repair against the real tokenizer: a run the lattice bound as
/// one unknown node comes back as the real word boundaries it hides, the
/// rebuilt stream still lines up with the text it was cut from, and the window
/// cap stays clear of the collapse threshold. Gated on the tokenizer runtime
/// only — the repair itself consults no dictionary. The no-coverage corpus
/// lives in the fragmentation suite, which also needs the JMDict gate.
@Suite(
    "ReadingAnnotator collapse repair corpus",
    .enabled(if: LiveDictionaryRuntime.isAvailable)
)
struct ReadingAnnotatorTokenRepairLiveTests {

    private let annotator = ReadingAnnotator(tokenize: { text in
        LiveDictionaryRuntime.engine?.tokenize(text)
    })

    private func segments(_ text: String) throws -> [ReadingSegment] {
        try #require(annotator.segments(for: text))
    }

    private func tokenize(_ text: String) throws -> [DictionaryToken] {
        try #require(LiveDictionaryRuntime.engine?.tokenize(text))
    }

    /// The repair run over a sentence by the real engine, from the stream the
    /// engine itself produced.
    private func repaired(_ text: String) throws -> [DictionaryToken] {
        let engine = try #require(LiveDictionaryRuntime.engine)
        let raw = try tokenize(text)
        return ReadingAnnotator.repairedTokens(raw, of: text) { window in
            engine.tokenize(window)
        }
    }

    /// That the engine really did bind the run as one unknown node, and not
    /// something the repair had no work to do. Without this a recovery test is
    /// satisfied identically by a dictionary bump that fixes the collapse on its
    /// own — which is exactly the moment it would stop testing anything, and
    /// silently.
    private func expectCollapse(_ text: String) throws -> [DictionaryToken] {
        let raw = try tokenize(text)
        #expect(
            raw.contains { token in
                token.reading == nil
                    && token.end - token.start >= ReadingAnnotator.fragmentLengthThreshold
            },
            "the corpus entry no longer collapses — the repair is untested here: \(raw.map(\.text))"
        )
        return raw
    }

    @Test("the collapsed debug sentence comes back as its real words")
    func debugSentenceRecoversItsWords() throws {
        let text = "ちょっとまあいいんだけどさなんでや稲なりだけだからか。"
        _ = try expectCollapse(text)
        let segments = try segments(text)

        #expect(segments.map(\.surface) == [
            "ちょっと", "まあ", "いい", "ん", "だ", "けど", "さ", "な", "ん", "で", "や",
            "稲", "なり", "だけ", "だ", "から", "か", "。"
        ])
        #expect(describe(segments) == [
            ["ちょっと", "chotto", nil], ["まあ", "maa", nil], ["いい", "ii", nil],
            ["ん", "n", nil], ["だ", "da", nil], ["けど", "kedo", nil], ["さ", "sa", nil],
            ["な", "na", nil], ["ん", "n", nil], ["で", "de", nil], ["や", "ya", nil],
            ["稲", "ine", "いね"], ["なり", "nari", nil], ["だけ", "dake", nil],
            ["だ", "da", nil], ["から", "kara", nil], ["か", "ka", nil], ["。", "。", nil]
        ])
        #expect(segments.count == 18, "streams: \(describe(segments))")
        #expect(segments.prefix(11).allSatisfy { segment in segment.lemma != nil })
        // Nothing is left over for the fallback tier to guess at.
        #expect(segments.allSatisfy { segment in
            segment.surface.unicodeScalars.count < ReadingAnnotator.fragmentLengthThreshold
        })
        #expect(segments.map(\.surface).joined() == text)
    }

    /// A repeated-vocable run that the lexicon *does* resolve comes back
    /// tappable without the fallback tier's help.
    ///
    /// This is a no-op test, and that is the point — it was written as a
    /// recovery test and was not one. The real engine binds
    /// `あいいいいいいいい` as `あ / いい / いい / いい / いい` unaided, so the
    /// repair has nothing to do here; asserting only the recovered segments let
    /// it pass whether or not the pass ran, and it would have kept passing after
    /// a dictionary bump. The stream is now asserted clean first, so what is
    /// pinned is the property that is actually true: the pass leaves an
    /// already-clean stream alone and every piece stays tappable.
    @Test("repeats of real words need no repair, and stay tappable", arguments: [
        "あいいいいいいいい"
    ])
    func repeatedRealWordsNeedNoRepair(input: String) throws {
        let raw = try tokenize(input)
        #expect(
            !raw.contains { token in
                token.reading == nil
                    && token.end - token.start >= ReadingAnnotator.fragmentLengthThreshold
            },
            "this now collapses — the pass has work to do here again: \(raw.map(\.text))"
        )
        let segments = try segments(input)

        #expect(segments.map(\.surface) == ["あ", "いい", "いい", "いい", "いい"])
        #expect(segments.map(\.surface).joined() == input)
        #expect(segments.allSatisfy { segment in segment.lemma != nil })
        #expect(segments.allSatisfy { segment in
            segment.surface.unicodeScalars.count < ReadingAnnotator.fragmentLengthThreshold
        })
    }

    /// The seam the join taps depend on, end to end through the real engine.
    /// Everything else here judges the tokenizer's windows; this drives the
    /// repair itself and checks the stream it hands back still lines up with
    /// the sentence — a repair that adopted a misaligned payload, or trimmed
    /// the wrong elements when a second collapse reached back across an
    /// already-repaired span, leaves a stream that repeats or drops a scalar
    /// and no longer concatenates back. Deliberately includes a spaced
    /// sentence and a pair of adjacent collapses.
    @Test("the repaired stream still tiles the sentence it was cut from", arguments: [
        "ちょっとまあいいんだけどさなんでや稲なりだけだからか。",
        "今日はとてもいい天気ですね",
        "会議は明日の午後三時から始まります",
        "そうなんですよソピアちゃんも確かあれだったよね",
        "そのデータを分析与検証の両方に行います",
        // Spaced the way ASR emits it — the tokenizer skips whitespace, so a
        // repaired stream may legitimately leave a gap there and nowhere else.
        "今日 は とても いい 天気 ですね",
        "モいモいモいもいモい",
        "ソラシナソラシカ",
        "シュワルツェネッガー",
        "あいいいいいいいい",
        // Two unstartable openings in one sentence, so the second peel's fold
        // lands on a span the first one already rewrote.
        "でうそうダンスレッスンが大変でもう覚えなきゃいけないことがめちゃくちゃってそうだよね。"
            + "なんかね悩んでたよね。めっちゃ覚えなきゃいけないからとかって。"
    ])
    func repairedStreamStillTiles(input: String) throws {
        let engine = try #require(LiveDictionaryRuntime.engine)
        let raw = try #require(engine.tokenize(input))

        let repaired = ReadingAnnotator.repairedTokens(raw, of: input) { window in
            engine.tokenize(window)
        }

        #expect(tilesText(repaired, input), "seams: \(repaired.map(\.text))")
    }

    /// Sentences whose cap-12 windowing reproduces full-sentence tokenization
    /// byte-for-byte — the tripwire for a dictionary bump that reintroduces
    /// collapses inside the window. Both arguments are longer than one window on
    /// purpose: an input of exactly `repairWindow` scalars runs the loop once
    /// with every offset unchanged, so it compares two identical `tokenize` calls
    /// and proves only that the engine is deterministic.
    @Test("windowed decoding reproduces whole-sentence tokenization", arguments: [
        "会議は明日の午後三時から始まります", "そのデータを分析与検証の両方に行います"
    ])
    func windowingMatchesWholeSentence(input: String) throws {
        #expect(input.unicodeScalars.count > ReadingAnnotator.repairWindow)
        let scalars = Array(input.unicodeScalars)
        var windowed: [DictionaryToken] = []
        var cursor = 0
        while cursor < scalars.count {
            let high = min(cursor + ReadingAnnotator.repairWindow, scalars.count)
            let window = String(String.UnicodeScalarView(scalars[cursor ..< high]))
            let decoded = try tokenize(window)
            windowed.append(contentsOf: decoded.map { token in
                DictionaryToken(
                    text: token.text, start: token.start + cursor, end: token.end + cursor,
                    reading: token.reading, base: token.base, pos: token.pos,
                    bound: token.bound
                )
            })
            cursor = high
        }

        let whole = try tokenize(input)
        #expect(windowed == whole)
    }

    /// A window boundary can shift a Viterbi choice without any collapse: this
    /// sentence reads 分析と検証の windowed against 分析与検証の whole, both
    /// clean. What must never happen inside the cap is an unknown run, which is
    /// the collapse the repair exists to undo.
    @Test("window boundaries may shift a reading, never collapse a window", arguments: [
        "そのデータを分析と検証の両方に行います"
    ])
    func windowBoundaryDoesNotCollapse(input: String) throws {
        let scalars = Array(input.unicodeScalars)
        var windows = 0
        var cursor = 0
        while cursor < scalars.count {
            let high = min(cursor + ReadingAnnotator.repairWindow, scalars.count)
            let window = String(String.UnicodeScalarView(scalars[cursor ..< high]))
            let decoded = try tokenize(window)
            windows += 1

            #expect(!decoded.contains { token in
                token.reading == nil
                    && token.end - token.start >= ReadingAnnotator.fragmentLengthThreshold
            }, "window collapsed: \(window)")
            cursor = high
        }
        // Every assertion in the loop is vacuous if it never ran.
        #expect(windows > 1, "one window, nothing was checked: \(input)")
    }

    // MARK: - Unstartable openings

    /// The `debug/test.md` line against the real tokenizer. Both its collapses
    /// open on the stray `ゃ` of a sokuon the ASR dropped, which is the one
    /// opening no window width and no kana left context can resolve — so before
    /// the peel these two runs were the sentence's only untappable content, cut
    /// at a fixed width into `ゃいけないこと / がめちゃくちゃ / ってそうだよね`.
    ///
    /// Asserted on the token stream rather than the rendered segments on
    /// purpose: the sokuon merge has its own say over which tokens become
    /// segments (`って` + `そう` is one), and this test is about the seams the
    /// repair adopts. The segment-level claims are the three below it.
    @Test("the sokuon-loss sentence comes back as its real words")
    func sokuonLossSentenceRecoversItsWords() throws {
        let text = "でうそうダンスレッスンが大変でもう覚えなきゃいけないことがめちゃくちゃってそうだよね。"
            + "なんかね悩んでたよね。めっちゃ覚えなきゃいけないからとかって。"

        let repaired = try repaired(text)

        #expect(repaired.map(\.text) == [
            "で", "う", "そう", "ダンス", "レッスン", "が", "大変", "で", "もう", "覚え",
            "なきゃ", "いけ", "ない", "こと", "が", "めちゃくちゃ", "って", "そう", "だ",
            "よ", "ね", "。", "なんか", "ね", "悩ん", "で", "た", "よ", "ね", "。",
            "めっちゃ", "覚え", "なきゃ", "いけ", "ない", "から", "と", "かっ", "て", "。"
        ])
        #expect(tilesText(repaired, text))
        // Nothing is left for the fallback tier to guess a cut inside, and the
        // folded openings are resolved rows, so both stay tappable.
        #expect(!repaired.contains { token in
            token.reading == nil && token.end - token.start >= ReadingAnnotator.fragmentLengthThreshold
        })
        let folded = repaired.filter { token in token.text == "なきゃ" }
        #expect(folded.count == 2, "the folds are missing: \(repaired.map(\.text))")
        #expect(folded.allSatisfy { token in token.base != nil })
    }

    @Test("the sokuon-loss sentence renders no fragment longer than the threshold")
    func sokuonLossSentenceRendersShortSegments() throws {
        let text = "でうそうダンスレッスンが大変でもう覚えなきゃいけないことがめちゃくちゃってそうだよね。"
            + "なんかね悩んでたよね。めっちゃ覚えなきゃいけないからとかって。"

        let segments = try segments(text)

        #expect(segments.map(\.surface).joined() == text)
        #expect(
            segments.allSatisfy { segment in
                segment.surface.unicodeScalars.count < ReadingAnnotator.fragmentLengthThreshold
            },
            "\(describe(segments))"
        )
        let surfaces = Set(segments.map(\.surface))
        #expect(surfaces.isDisjoint(with: ["ゃいけないこと", "がめちゃくちゃ", "ってそうだよね"]))
    }

    @Test("the folded opening reads as one word rather than a stranded kana")
    func foldedOpeningReadsAsOneWord() throws {
        let segments = try segments("覚えなきゃいけないからとかって。")

        let folded = try #require(segments.first { segment in segment.surface == "なきゃ" })
        // `きゃ` geminates, so the fold is one romaji syllable and not two.
        #expect(folded.romaji == "nakya")
        #expect(folded.lemma != nil)
        #expect(!segments.contains { segment in segment.surface == "ゃ" })
    }

    /// A peel is two tokenizer calls on top of the two the left-context walk
    /// already spent declining: one for the remainder, one for the folded span.
    /// Pinned because this runs on every live-partial revision of the sentence
    /// that contains the collapse.
    @Test("a peel costs the remainder decode and the fold, and nothing else")
    func peelCostIsBounded() throws {
        let text = "なきゃいけないからとかって"
        let raw = try expectCollapse(text)
        let engine = try #require(LiveDictionaryRuntime.engine)
        var windows: [String] = []

        let repaired = ReadingAnnotator.repairedTokens(raw, of: text) { window in
            windows.append(window)
            return engine.tokenize(window)
        }

        #expect(windows == [
            "ゃいけないからとかって", // the bare region, windowed
            "なきゃいけないからとかっ", // one kana of left context, windowed
            "いけないからとかって", // the remainder, undivided
            "なきゃ" // the span the opening folds into
        ])
        // …and the calls bought something: the same peel for the same budget
        // produced the folded word. Without this the call log alone would be
        // satisfied by a peel that spent four calls and adopted nothing.
        #expect(repaired.first?.text == "なきゃ")
        #expect(repaired.first?.base != nil)
        #expect(tilesText(repaired, text))
    }

    /// A run that opens on a full-size kana never reaches the peel, which is
    /// what keeps a dictionary-covered long name whole: the fallback tier's
    /// gate is the only thing standing between it and a cut, and the repair
    /// runs ahead of that gate.
    @Test("a long unknown name is left whole for the gate", arguments: [
        "シュワルツェネッガー"
    ])
    func longUnknownNameIsLeftWhole(input: String) throws {
        let segments = try segments(input)

        #expect(segments.map(\.surface) == [input])
    }
}
