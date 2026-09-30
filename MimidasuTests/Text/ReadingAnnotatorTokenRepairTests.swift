import Foundation
@testable import Mimidasu
import Testing

// MARK: - Collapse repair fixtures

// MARK: - Recovery

/// The repair's purpose: a run the tokenizer collapsed comes back as the real
/// word boundaries it hides, each piece annotated and tappable, with nothing
/// left for the fallback tier to guess at.
@Suite("ReadingAnnotator collapse repair")
struct ReadingAnnotatorTokenRepairTests {

    private static let threshold = ReadingAnnotator.fragmentLengthThreshold

    @Test("the collapsed debug sentence recovers ちょっと and its real word boundaries")
    func recoversWordBoundaries() throws {
        let fake = FakeCollapseTokenizer(collapseWindows())

        let segments = try #require(fake.annotator().segments(for: debugSentence))

        #expect(segments.map(\.surface) == [
            "ちょっと", "まあ", "いい", "ん", "だ", "けど", "さ", "な", "ん", "で", "や",
            "稲", "なり", "だけ", "だ", "から", "か", "。"
        ])
        #expect(segments.map(\.surface).joined() == debugSentence)
        #expect(describe(segments) == [
            ["ちょっと", "chotto", nil], ["まあ", "maa", nil], ["いい", "ii", nil],
            ["ん", "n", nil], ["だ", "da", nil], ["けど", "kedo", nil], ["さ", "sa", nil],
            ["な", "na", nil], ["ん", "n", nil], ["で", "de", nil], ["や", "ya", nil],
            ["稲", "ine", "いね"], ["なり", "nari", nil], ["だけ", "dake", nil],
            ["だ", "da", nil], ["から", "kara", nil], ["か", "ka", nil], ["。", "。", nil]
        ])
        // Every recovered piece is a real word: none is long enough, or
        // reading-less, to be an unknown run again.
        #expect(segments.allSatisfy { segment in segment.surface.unicodeScalars.count < Self.threshold })
        // The eleven pieces the recovery produced, on a stream whose only
        // resolved row before the repair was ち/ちる. The count is pinned so a
        // shorter stream cannot make this vacuously true, and the window is
        // stated as a prefix so a changed tail cannot slide it onto the wrong
        // elements. Not the lemma *values*: this fixture's decoded windows
        // carry invented bases (only the tokenizer's own bindings are real), so
        // what is asserted is that every one of them is tappable.
        #expect(segments.count == 18, "streams: \(describe(segments))")
        #expect(segments.prefix(11).allSatisfy { segment in segment.lemma != nil })
    }

    @Test("the left kana neighbour is rewritten: ち bound to ちる becomes ちょっと")
    func kanaLeftNeighbourIsPulledIn() {
        let fake = FakeCollapseTokenizer(collapseWindows())

        let repaired = ReadingAnnotator.repairedTokens(
            collapsedDebugSentence, of: debugSentence, tokenize: { text in fake.tokenize(text) }
        )

        #expect(repaired.first?.text == "ちょっと")
        #expect(repaired.first?.base == "ちょっと")
        #expect(repaired.first?.start == 0)
        // The bare region is tried first and only then the one that grows
        // left — the growth loop is load-bearing, not a formality.
        #expect(fake.windows == [
            "ょっとまあいいんだけどさ", "ちょっとまあいいんだけど", "さなんでや"
        ])
    }

    @Test("repeats of real words are recovered too (あいいいいいいいい → five tappable pieces)")
    func repeatedRealWordsAreRecovered() throws {
        // The whole string collapses, and the one window the repair re-decodes
        // is that same string — so the fake has to tell the two calls apart.
        let text = "あいいいいいいいい"
        let fake = ScriptedCollapseTokenizer(
            transcript: [token(text, start: 0)],
            decodes: [
                text: tokens(
                    ["あ", "いい", "いい", "いい", "いい"],
                    readings: ["あ", "いい", "いい", "いい", "いい"],
                    bases: ["あ", "いい", "いい", "いい", "いい"]
                )
            ]
        )

        let segments = try #require(fake.annotator().segments(for: text))

        #expect(segments.map(\.surface) == ["あ", "いい", "いい", "いい", "いい"])
        #expect(segments.map(\.romaji) == ["a", "ii", "ii", "ii", "ii"])
        #expect(segments.map(\.surface).joined() == text)
        // The repair really ran: the transcript collapsed, one window came back.
        #expect(fake.windows == [text])
    }

    /// Two collapses in one sentence, adjacent, the second reachable only by
    /// widening across the first. The widened splice overlaps a span the pass
    /// has already replaced, so trimming it needs the entries the *original*
    /// indices contributed rather than the count of those indices — a count
    /// that only matches while every original token still stands for exactly
    /// one entry, which the first splice has already invalidated. Getting this
    /// wrong emits the first run's scalars a second time and breaks every join
    /// anchored on the concatenated surfaces.
    @Test("a second collapse reaching back across an already-repaired span still tiles")
    func secondCollapseAcrossRepairedSpanStillTiles() {
        let text = kanaRun + syntheticCollapse
        let collapsed = [
            token(kanaRun, start: 0),
            token(syntheticCollapse, start: kanaRun.unicodeScalars.count)
        ]
        let firstWindow = kanaRunWords + ["がっこう"]
        let fake = FakeCollapseTokenizer([
            // The first collapse, on its own, re-decodes into real words.
            kanaRun: tokens(
                kanaRunWords,
                readings: [String](repeating: "いい", count: 4),
                bases: [String](repeating: "いい", count: 4)
            ),
            // The second, on its own, stays collapsed — so its region has to
            // grow left, and that growth reaches back over the first splice.
            syntheticCollapse: [token(syntheticCollapse, start: 0)],
            kanaRun + "がっこう": tokens(
                firstWindow,
                readings: kanaRunWords + ["がっこう"],
                bases: kanaRunWords + ["学校"]
            ),
            "へいきます": tokens(
                ["へ", "いきます"], readings: ["へ", "いきます"], bases: ["へ", "行く"]
            )
        ])

        let repaired = ReadingAnnotator.repairedTokens(
            collapsed, of: text, tokenize: { window in fake.tokenize(window) }
        )

        // Both collapses went: the first re-decoded on its own, then swallowed
        // whole by the widened region that recovered the second.
        #expect(fake.windows == [kanaRun, syntheticCollapse, kanaRun + "がっこう", "へいきます"])
        #expect(repaired.map(\.text) == kanaRunWords + ["がっこう", "へ", "いきます"])
        #expect(tilesText(repaired, text))
    }

    @Test("rebased offsets stay contiguous and ascending, covering the region inside the original text")
    func rebasedOffsetsCoverTheRegion() {
        let fake = FakeCollapseTokenizer(collapseWindows())

        let repaired = ReadingAnnotator.repairedTokens(
            collapsedDebugSentence, of: debugSentence, tokenize: { text in fake.tokenize(text) }
        )

        let scalars = Array(debugSentence.unicodeScalars)
        // The repaired span replaces indices 0…1 (ち + the collapse) and the
        // tail keeps its original offsets, so the whole stream still tiles the
        // text from end to end.
        #expect(repaired.first?.start == 0)
        #expect(repaired.last?.end == scalars.count)
        #expect(zip(repaired, repaired.dropFirst()).allSatisfy { token, next in
            token.end == next.start
        })
        #expect(repaired.allSatisfy { token in
            token.text == String(String.UnicodeScalarView(scalars[token.start ..< token.end]))
        })
    }

    // MARK: left-context walk

    /// Scripted so the *bare* region still collapses: the walk has to start
    /// before it can be stopped, and a fixture that decodes the bare region
    /// cleanly would leave these green with the walk deleted outright. The
    /// neighbour is scripted to decode as real words if it were ever reached,
    /// so the only reason the run stays collapsed is the guard.
    @Test("the walk stops at a kanji / Latin / punctuation / numeral neighbour", arguments: [
        "橋", "A", "、", "二"
    ])
    func nonKanaNeighbourStopsTheWalk(neighbour: String) {
        let text = neighbour + syntheticCollapse
        let collapsed = tokens([neighbour, syntheticCollapse], readings: ["は", nil])
        var decodes = stillCollapsingWindows()
        decodes[text] = tokens(
            [neighbour] + ["がっこう", "へ", "いきます"],
            readings: ["は", "がっこう", "へ", "いきます"],
            bases: [neighbour, "学校", "へ", "行く"]
        )
        let fake = FakeCollapseTokenizer(decodes)

        let repaired = ReadingAnnotator.repairedTokens(
            collapsed, of: text, tokenize: { window in fake.tokenize(window) }
        )

        // The one window is the bare region: nothing reached the neighbour.
        #expect(fake.windows == [syntheticCollapse], "the walk reached: \(fake.windows)")
        #expect(repaired.map { token in token.text } == [neighbour, syntheticCollapse])
    }

    /// Same shape as above, reached through adjacency rather than script: a
    /// whitespace-gapped neighbour is not next door, so the walk must not step
    /// over the gap. `stillCollapsingWindows` is what makes the walk start.
    @Test("the walk stops at a gap: a whitespace-gapped neighbour is not adjacent")
    func gapStopsTheWalk() {
        let text = "ん " + syntheticCollapse
        let gapped = spacedTokens(["ん"], readings: ["ん"])
            + [token(syntheticCollapse, start: 2)]
        var decodes = stillCollapsingWindows()
        // What a step across the gap would ask for, scripted clean so that
        // reaching it is visible in the window log.
        decodes["んがっこうへいきます"] = tokens(
            ["ん", "がっこう", "へ", "いきます"],
            readings: ["ん", "がっこう", "へ", "いきます"],
            bases: ["ん", "学校", "へ", "行く"]
        )
        let fake = FakeCollapseTokenizer(decodes)

        let repaired = ReadingAnnotator.repairedTokens(
            gapped, of: text, tokenize: { window in fake.tokenize(window) }
        )

        #expect(fake.windows == [syntheticCollapse], "the walk crossed: \(fake.windows)")
        #expect(repaired.map { token in token.text } == ["ん", syntheticCollapse])
    }

    @Test("a candidate at offset 0 never grows left, so a still-collapsing decode declines")
    func candidateAtOffsetZeroDeclines() {
        let collapsed = [token(syntheticCollapse, start: 0)]
        let fake = FakeCollapseTokenizer()

        let repaired = ReadingAnnotator.repairedTokens(
            collapsed, of: syntheticCollapse, tokenize: { window in fake.tokenize(window) }
        )

        #expect(fake.windows == [syntheticCollapse])
        #expect(repaired == collapsed)
    }

    @Test("the left-context budget stops the walk: a neighbour wider than the budget can't be pulled in")
    func budgetStopsTheWalk() {
        let left = "あいうえおかいきくけこさ" // 12 scalars, past the 8-scalar budget
        let collapsed = tokens([left], readings: [left])
            + [token(syntheticCollapse, start: left.unicodeScalars.count)]
        var decodes = stillCollapsingWindows()
        // Reachable, and resolvable, if the budget did not stop the step.
        decodes[left + syntheticCollapse] = tokens(
            [left, "がっこう", "へ", "いきます"],
            readings: [left, "がっこう", "へ", "いきます"],
            bases: [left, "学校", "へ", "行く"]
        )
        let fake = FakeCollapseTokenizer(decodes)

        let repaired = ReadingAnnotator.repairedTokens(
            collapsed, of: left + syntheticCollapse, tokenize: { window in fake.tokenize(window) }
        )

        // The whole left run is one token, so a single step overruns the
        // budget and the walk never starts.
        #expect(fake.windows == [syntheticCollapse], "the walk stepped: \(fake.windows)")
        #expect(repaired.map(\.text) == [left, syntheticCollapse])
    }

    /// The budget is spent across a whole run of neighbours, not just against
    /// one oversized token: steps keep coming until one would overrun, and here
    /// the budget is what stops the walk three 3-scalar tokens in.
    @Test("the walk keeps stepping until the next neighbour would overrun the budget")
    func budgetStopsTheWalkMidRun() {
        // あいう うえお おかき くけこ — the walk takes くけこ then おかき, and
        // stops at うえお, which would push the budget from 6 past 8.
        let text = "あいう" + "うえお" + "おかき" + "くけこ" + syntheticCollapse
        let collapsed = tokens(
            ["あいう", "うえお", "おかき", "くけこ"], readings: [nil, nil, nil, nil]
        ) + [token(syntheticCollapse, start: 12)]
        let fake = FakeCollapseTokenizer()

        let repaired = ReadingAnnotator.repairedTokens(
            collapsed, of: text, tokenize: { window in fake.tokenize(window) }
        )

        // Every attempt declined, so the windows say exactly how far the walk
        // got: three regions, none reaching past おかき. The widest stops at
        // its first window — a later one is never handed over once one fails.
        #expect(fake.windows == [
            syntheticCollapse, "くけこ" + syntheticCollapse, "おかきくけこがっこうへい"
        ])
        #expect(repaired == collapsed)
    }

    @Test("attempt sizes grow one token at a time: a fake that only succeeds at size 1 proves the loop")
    func attemptSizesGrowOneTokenAtATime() {
        let text = "ん" + syntheticCollapse
        let collapsed = tokens(["ん", syntheticCollapse], readings: ["ん", nil])
        var decodes: [String: [DictionaryToken]?] = syntheticWindows()
        // The bare region still collapses…
        decodes[syntheticCollapse] = [token(syntheticCollapse, start: 0)]
        // …so the region has to grow, and only then does the word come apart.
        decodes[text] = tokens(
            ["ん", "がっこう", "へ", "いきます"],
            readings: ["ん", "がっこう", "へ", "いきます"],
            bases: ["ん", "学校", "へ", "行く"]
        )
        let fake = FakeCollapseTokenizer(decodes)

        let repaired = ReadingAnnotator.repairedTokens(
            collapsed, of: text, tokenize: { window in fake.tokenize(window) }
        )

        #expect(fake.windows == [syntheticCollapse, text])
        #expect(repaired.map { token in token.text } == ["ん", "がっこう", "へ", "いきます"])
    }

    // MARK: rejection paths

    @Test("a nil window decode rejects the attempt and leaves the tokens untouched")
    func nilWindowDecodeRejects() {
        let collapsed = [token(syntheticCollapse, start: 0)]
        let fake = FakeCollapseTokenizer([syntheticCollapse: nil])

        let repaired = ReadingAnnotator.repairedTokens(
            collapsed, of: syntheticCollapse, tokenize: { window in fake.tokenize(window) }
        )

        #expect(repaired == collapsed)
    }

    @Test("a window whose payload covers only part of it rejects — no scalar may be dropped")
    func nonCoveringDecodeRejects() {
        let collapsed = [token(syntheticCollapse, start: 0)]
        // Four scalars short of the window it was asked to decode.
        let fake = FakeCollapseTokenizer([
            syntheticCollapse: tokens(["がっこう", "へ"], readings: ["がっこう", "へ"])
        ])

        let repaired = ReadingAnnotator.repairedTokens(
            collapsed, of: syntheticCollapse, tokenize: { window in fake.tokenize(window) }
        )

        #expect(fake.windows == [syntheticCollapse])
        #expect(repaired == collapsed)
    }

    /// A multi-window region is accepted whole or not at all. A payload that
    /// leaves a scalar uncovered three windows in still drops it, so an early
    /// window decoding cleanly buys nothing.
    @Test("a later window failing to cover rejects the windows that already decoded")
    func laterWindowFailureRejectsTheAttempt() {
        // 18 scalars, so the region needs two windows.
        let text = syntheticCollapse + syntheticCollapse
        let collapsed = [token(text, start: 0)]
        let fake = FakeCollapseTokenizer([
            "がっこうへいきますがっこ": tokens(
                ["がっこう", "へ", "いきます", "がっこ"],
                readings: ["がっこう", "へ", "いきます", "がっこう"],
                bases: ["学校", "へ", "行く", "学校"]
            ),
            // Covers only two of the second window's six scalars.
            "うへいきます": tokens(["う", "へ"], readings: ["う", "へ"], bases: ["う", "へ"])
        ])

        let repaired = ReadingAnnotator.repairedTokens(
            collapsed, of: text, tokenize: { window in fake.tokenize(window) }
        )

        #expect(fake.windows == ["がっこうへいきますがっこ", "うへいきます"])
        #expect(repaired == collapsed)
    }

    /// Nothing to collapse, nothing to spend: the pass hands the input array
    /// straight back, so degenerate input costs nothing either.
    @Test("an empty stream is passed through without a re-decode")
    func emptyStreamIsUntouched() {
        let fake = FakeCollapseTokenizer()

        let repaired = ReadingAnnotator.repairedTokens(
            [], of: "", tokenize: { window in fake.tokenize(window) }
        )

        #expect(fake.windows.isEmpty)
        #expect(repaired.isEmpty)
    }

    @Test("a window that covers its whole length but still carries a long unknown run rejects")
    func stillCollapsedWindowRejects() {
        // A payload that tiles perfectly and carries a lemma on the long piece,
        // so the long-unknown rule is the only one it fails: distinct from the
        // offset-zero case, where the decode never covered anything worth
        // judging, and from the unresolved-payload case, where the piece is
        // short but unreadable.
        let text = syntheticCollapse + "ね"
        let collapsed = [token(text, start: 0)]
        let fake = FakeCollapseTokenizer([
            text: tokens(
                [syntheticCollapse, "ね"],
                readings: [nil, "ね"], bases: [syntheticCollapse, "ね"]
            )
        ])

        let repaired = ReadingAnnotator.repairedTokens(
            collapsed, of: text, tokenize: { window in fake.tokenize(window) }
        )

        #expect(fake.windows == [text])
        #expect(repaired == collapsed)
    }

    /// Adoption is not "the window came back shorter": every decoded token has
    /// to be a row the lexicon actually resolved. A payload that merely re-cuts
    /// the unknown into shorter unreadable pieces is the same collapse behind a
    /// different seam, and adopting it would split a long name here — ahead of
    /// the fallback tier, whose headword gate is what keeps a
    /// dictionary-covered name whole.
    @Test("a payload of short unreadable pieces rejects, leaving the name whole for the gate")
    func unresolvedPayloadRejects() {
        let collapsed = [token(syntheticCollapse, start: 0)]
        let fake = FakeCollapseTokenizer([
            syntheticCollapse: tokens(
                ["がっこうへ", "いきます"], readings: [nil, "いきます"], bases: [nil, "行く"]
            )
        ])

        let repaired = ReadingAnnotator.repairedTokens(
            collapsed, of: syntheticCollapse, tokenize: { window in fake.tokenize(window) }
        )

        #expect(fake.windows == [syntheticCollapse])
        #expect(repaired == collapsed)
    }

    @Test("a declining repair leaves the fallback tier's rows exactly as they were", arguments: [
        "モいモいモいもいモい", "のじゃのじゃのじゃ", "ソラシナソラシカ"
    ])
    func declinedRepairFallsBackToFragmentation(input: String) throws {
        // The text-blind tokenizer the fallback suite uses: every input replays
        // the same payload, so no re-decode can ever cover its window.
        let canned = tokens([input], readings: [nil])
        let annotator = makeAnnotator(canned, headwordGate: { _ in false })
        let fake = FakeCollapseTokenizer([input: canned])

        let repaired = ReadingAnnotator.repairedTokens(
            canned, of: input, tokenize: { window in fake.tokenize(window) }
        )

        // An attempt did run and did decline, rather than the pass never firing.
        #expect(fake.windows == [input])
        #expect(repaired == canned)
        let segments = try #require(annotator.segments(for: input))
        #expect(segments.count >= 2, "\(input) stayed whole: \(describe(segments))")
        #expect(segments.map(\.surface).joined() == input)
    }

    @Test("an ordinary sentence costs no tokenizer calls at all")
    func ordinaryTextIsFree() throws {
        let fake = FakeCollapseTokenizer([
            "今日はとてもいい天気ですね": tokens(
                ["今日", "は", "とても", "いい", "天気", "です", "ね"],
                readings: ["きょう", "は", "とても", "いい", "てんき", "です", "ね"]
            )
        ])

        let text = "今日はとてもいい天気ですね"
        let segments = try #require(fake.annotator().segments(for: text))

        #expect(segments.map(\.surface).joined() == text)
        // The transcript call and nothing else: no window was re-decoded.
        #expect(fake.windows == [text])
    }

    @Test("a short unreadable name is not a collapse: the repair never looks at it")
    func shortUnknownIsNotACollapse() throws {
        let fake = FakeCollapseTokenizer([
            "シュワルツェネッガー": [token("シュワルツェネッガー", start: 0)]
        ])
        let annotator = fake.annotator()

        let short = try #require(annotator.segments(for: "山上太郎"))
        #expect(short.map(\.surface) == ["山上太郎"])
        #expect(fake.windows == ["山上太郎"])

        // …while the long unknown name does reach the repair, and declines:
        // its one window decodes straight back to the same long unknown, so
        // the pass falls through to the entry gate.
        let long = try #require(annotator.segments(for: "シュワルツェネッガー"))
        #expect(long.map(\.surface) == ["シュワルツェネッガー"])
        #expect(fake.windows == ["山上太郎", "シュワルツェネッガー", "シュワルツェネッガー"])
    }

    /// Growing left is the better answer when it works, so the peel — the
    /// attempt below this one in the ladder — only runs on what left context
    /// could not reach. Scripting the peeled remainder as a clean decode proves
    /// the order: had the peel gone first this same sentence would have come
    /// back as a stranded `ょっ` plus `とまあ…`, and never as one ちょっと.
    @Test("growing left wins: the peel only runs where left context gave up")
    func leftContextIsTriedBeforeThePeel() {
        let text = debugSentence
        var decodes = collapseWindows()
        // The remainder a peel would reach, scripted clean so that asking for it
        // would be visible in the windows below.
        let remainder = String(collapsedDebugSentence[1].text.dropFirst())
        decodes[remainder] = tokens(
            ["と", "まあ", "いい", "ん", "だ", "けど", "さ", "な", "ん", "で", "や"],
            readings: ["と", "まあ", "いい", "ん", "だ", "けど", "さ", "な", "ん", "で", "や"]
        )
        let fake = FakeCollapseTokenizer(decodes)

        let repaired = ReadingAnnotator.repairedTokens(
            collapsedDebugSentence, of: text, tokenize: { window in fake.tokenize(window) }
        )

        #expect(fake.windows == [
            "ょっとまあいいんだけどさ", "ちょっとまあいいんだけど", "さなんでや"
        ])
        #expect(repaired.first?.text == "ちょっと")
    }
}
