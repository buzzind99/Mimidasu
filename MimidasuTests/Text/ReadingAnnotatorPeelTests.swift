import Foundation
@testable import Mimidasu
import Testing

// MARK: - Unstartable-opening peel fixtures

/// The shape the real runtime produced for the second collapse in
/// `debug/test.md`: a known `なき` (ない) followed by a run opening on the
/// stray `ゃ` of a sokuon the ASR dropped (書かなくちゃ → 書なきゃ). No window
/// width and no amount of kana left context resolves it — measured across
/// widths 2…12 and both left-context sizes, every one collapses again — but
/// with that opening set aside the run is an ordinary sentence.
private let sokuonLossNeighbour = "なき"
private let sokuonLossCollapse = "ゃいけないからとかって"
private let sokuonLossText = sokuonLossNeighbour + sokuonLossCollapse
private let sokuonLossRemainder = "いけないからとかって"
private let sokuonLossDecoded = ["いけ", "ない", "から", "と", "かっ", "て"]
private let sokuonLossBases = ["ける", "ない", "から", "と", "かう", "て"]

/// The real runtime's own binding of the folded span, which is what makes
/// fusing worth a tokenizer call: なき + ゃ is a single token read なきゃ.
/// (Its lemma is ない — the dictionary's answer for that span, not a claim
/// this pass makes about it.)
private let sokuonLossFold = "なきゃ"
private let sokuonLossFolded = tokens(
    [sokuonLossFold], readings: [sokuonLossFold], bases: ["ない"]
)

/// The remainder decode on its own, plus the folded span when the caller wants
/// the fusion to be available.
private func sokuonLossDecodes(
    folded: [DictionaryToken]? = sokuonLossFolded
) -> [String: [DictionaryToken]?] {
    var decodes: [String: [DictionaryToken]?] = [
        sokuonLossRemainder: tokens(
            sokuonLossDecoded, readings: sokuonLossDecoded, bases: sokuonLossBases
        )
    ]
    if let folded {
        decodes[sokuonLossFold] = folded
    }
    return decodes
}

/// The transcript a `sokuonLossText` run arrives as: a resolved neighbour and
/// the collapse after it.
private var sokuonLossCollapsed: [DictionaryToken] {
    tokens([sokuonLossNeighbour, sokuonLossCollapse], readings: ["なき", nil])
}

/// The collapse alone, with nothing to fold its opening into.
private var orphanCollapsed: [DictionaryToken] {
    [token(sokuonLossCollapse, start: 0)]
}

/// A folded span the lattice would in fact resolve: one resolved row, tiling its
/// own text. For the fold-*refusal* tests, which have to prove the guard refuses
/// rather than the decode, so the guard is the only thing standing between the
/// fixture and the fold.
private func foldableSpan(_ text: String) -> [DictionaryToken] {
    tokens([text], readings: [text], bases: [text])
}

/// The `debug/test.md` line exactly as the real tokenizer binds it: a
/// well-tokenized head, then two grouped unknown nodes, each opening on the
/// stray `ゃ` of a sokuon the ASR dropped (覚えなきゃ / 覚えなきゃ). Every other
/// token is a resolved lexicon row, so the two runs are the whole of the
/// problem — and neither is reachable by windowing or by kana left context.
private let sokuonLossSentence =
    "でうそうダンスレッスンが大変でもう覚えなきゃいけないことがめちゃくちゃってそうだよね。"
        + "なんかね悩んでたよね。めっちゃ覚えなきゃいけないからとかって。"

private var sokuonLossSentenceCollapsed: [DictionaryToken] {
    tokens(
        [
            "で", "う", "そう", "ダンス", "レッスン", "が", "大変", "で", "もう", "覚え",
            "なき", "ゃいけないことがめちゃくちゃってそうだよね", "。", "なんか", "ね", "悩ん",
            "で", "た", "よ", "ね", "。", "めっちゃ", "覚え", "なき",
            "ゃいけないからとかって", "。"
        ],
        readings: [
            "で", "う", "そう", "だんす", "れっすん", "が", "たいへん", "で", "もう", "おぼえ",
            "なき", nil, "。", "なんか", "ね", "なやん", "で", "た", "よ", "ね", "。",
            "めっちゃ", "おぼえ", "なき", nil, "。"
        ],
        bases: [
            "で", "うい", "そう", "ダンス", "レッスン", "が", "大変", "だ", "もう", "覚える",
            "ない", nil, "。", "なんか", "ね", "悩む", "で", "た", "よ", "ね", "。",
            "めっちゃ", "覚える", "ない", nil, "。"
        ]
    )
}

/// The two remainder decodes the real tokenizer produces once each run's
/// unstartable opening is set aside, plus the folded span both of them share.
private func sokuonLossSentenceDecodes() -> [String: [DictionaryToken]?] {
    let first = ["いけ", "ない", "こと", "が", "めちゃくちゃ", "って", "そう", "だ", "よ", "ね"]
    return [
        "いけないことがめちゃくちゃってそうだよね": tokens(first, readings: first, bases: first),
        sokuonLossRemainder: tokens(
            sokuonLossDecoded, readings: sokuonLossDecoded, bases: sokuonLossBases
        ),
        sokuonLossFold: sokuonLossFolded
    ]
}

/// A run that opens on a scalar no word can begin with is not a word the
/// lattice could not find — it is a boundary the lattice lost, and it hides
/// behind the one opening that made it unresolvable. Setting that opening
/// aside and re-decoding the rest whole recovers the real segmentation; left to
/// the fallback tier the same run is cut at a fixed width and every boundary in
/// it is wrong.
@Suite("ReadingAnnotator unstartable-opening peel")
struct ReadingAnnotatorPeelTests {

    private static let threshold = ReadingAnnotator.fragmentLengthThreshold

    // MARK: the regression

    /// The `debug/test.md` line as the real tokenizer binds it: a well-tokenized
    /// head, then two grouped unknown nodes, each opening on the stray `ゃ` of a
    /// sokuon the ASR dropped (書かなくちゃ → 書なきゃ). Every other token is a
    /// resolved lexicon row, so those two runs are the whole of the problem —
    /// and neither is reachable by windowing or by kana left context, which is
    /// why the fixed-width cut the fallback tier would otherwise apply shows up
    /// in this sentence as three untappable blobs.
    @Test("the sokuon-loss sentence comes back as its real words")
    func sokuonLossSentenceRecoversItsWords() throws {
        let text = sokuonLossSentence
        let collapsed = sokuonLossSentenceCollapsed
        let decodes = sokuonLossSentenceDecodes()
        // `repairedTokens` is handed the stream, so it never spends a transcript
        // call on the fake the way `annotator()` does — the text-keyed fake is
        // the right one here, and the scripted one is not (its first call would
        // hand the whole 26-token sentence back as if it were a re-decode
        // window).
        let repairFake = FakeCollapseTokenizer(decodes)

        let repaired = ReadingAnnotator.repairedTokens(
            collapsed, of: text, tokenize: { window in repairFake.tokenize(window) }
        )

        // Both openings set aside, both remainders whole, both folded into the
        // neighbour on their left — and the seams still line up with the text.
        #expect(repaired.map(\.text) == [
            "で", "う", "そう", "ダンス", "レッスン", "が", "大変", "で", "もう", "覚え",
            sokuonLossFold, "いけ", "ない", "こと", "が", "めちゃくちゃ", "って", "そう",
            "だ", "よ", "ね", "。", "なんか", "ね", "悩ん", "で", "た", "よ", "ね", "。",
            "めっちゃ", "覚え", sokuonLossFold, "いけ", "ない", "から", "と", "かっ", "て",
            "。"
        ])
        #expect(tilesText(repaired, text))
        // Nothing long or unreadable is left for the fallback tier to cut.
        #expect(!repaired.contains { token in
            token.reading == nil && token.end - token.start >= Self.threshold
        })
        // The recovered words are resolved lexicon rows, so each is tappable.
        let recovered = repaired.filter { token in
            ["いけ", "ない", "こと", "から", "かっ"].contains(token.text)
        }
        #expect(recovered.count == 7, "the recovered words are missing: \(repaired.map(\.text))")
        #expect(recovered.allSatisfy { token in token.base != nil })

        let segments = try #require(
            ScriptedCollapseTokenizer(transcript: collapsed, decodes: decodes)
                .annotator().segments(for: text)
        )
        #expect(segments.map(\.surface).joined() == text)
        #expect(
            segments.allSatisfy { segment in
                segment.surface.unicodeScalars.count < Self.threshold
            },
            "\(describe(segments))"
        )
        // The regression, stated as what it looked like: none of the three
        // fixed-width cuts is a segment any more.
        let surfaces = Set(segments.map(\.surface))
        #expect(surfaces.isDisjoint(with: ["ゃいけないこと", "がめちゃくちゃ", "ってそうだよね"]))
    }

    @Test("the peeled opening folds into the token on its left, so なき + ゃ reads as なきゃ")
    func peeledOpeningFoldsIntoItsNeighbour() {
        let text = sokuonLossText
        let fake = FakeCollapseTokenizer(sokuonLossDecodes())

        let repaired = ReadingAnnotator.repairedTokens(
            sokuonLossCollapsed, of: text, tokenize: { window in fake.tokenize(window) }
        )

        // Left context is tried first, at both sizes, and declines — the fold is
        // the last attempt, and only then is the opening set aside.
        #expect(fake.windows == [
            sokuonLossCollapse, "なきゃいけないからとかっ", sokuonLossRemainder, sokuonLossFold
        ])
        #expect(repaired.map(\.text) == [sokuonLossFold] + sokuonLossDecoded)
        #expect(repaired.first?.reading == sokuonLossFold)
        #expect(repaired.first?.base == "ない")
        #expect(tilesText(repaired, text))
    }

    // MARK: where the opening goes when it cannot fold

    /// The fold is preferred but never forced. With no neighbour to fold into —
    /// at offset 0, or across a script break or a numeral run — the opening
    /// stands alone and every other token is left exactly as it was.
    ///
    /// Each neighbour's folded span is scripted *resolvable*, so `tiles` cannot
    /// be the thing refusing the fold: delete the guard under test and the fold
    /// is taken. That is the whole point — a fixture that leaves the span
    /// undecodable (as these did) passes on the decode refusing, whichever guard
    /// happens to fire first.
    @Test("with nothing to fold into, the opening stands alone", arguments: [
        "", "橋", "二"
    ])
    func openingStandsAloneWithoutAFoldableNeighbour(neighbour: String) {
        let collapse = sokuonLossCollapse
        let text = neighbour + collapse
        var collapsed: [DictionaryToken] = if neighbour.isEmpty {
            orphanCollapsed
        } else {
            [token(neighbour, start: 0, reading: neighbour, base: neighbour)]
                + [token(collapse, start: neighbour.unicodeScalars.count)]
        }
        if neighbour == "二" {
            // A numeral run is held back for counter fusion, so it carries no
            // reading of its own — the repair only has to decline the fold.
            collapsed[0] = token(neighbour, start: 0, reading: "に", base: "二")
        }
        var decodes = sokuonLossDecodes()
        decodes[neighbour + "ゃ"] = foldableSpan(neighbour + "ゃ")

        let fake = FakeCollapseTokenizer(decodes)
        let repaired = ReadingAnnotator.repairedTokens(
            collapsed, of: text, tokenize: { window in fake.tokenize(window) }
        )

        #expect(repaired.map(\.text) == (neighbour.isEmpty ? [] : [neighbour])
            + ["ゃ"] + sokuonLossDecoded)
        // The fold was never even asked for: neither the bare region nor the
        // grown one can fold, so the two windowed attempts and the remainder
        // decode are the whole cost.
        #expect(!fake.windows.contains(neighbour + "ゃ"), "the fold was asked: \(fake.windows)")
        if !neighbour.isEmpty {
            #expect(repaired.first?.text == neighbour)
            #expect(repaired.first?.base != nil, "the neighbour lost its lemma")
        }
        #expect(tilesText(repaired, text))
    }

    /// A whitespace gap is not adjacency, so the token on the left of it is not
    /// a neighbour the opening can fold into — the same refusal as a script
    /// break, reached through a different guard. The folded span across the gap
    /// is scripted resolvable, so the gap is the only thing refusing it.
    @Test("a gap keeps the opening from folding across it")
    func gapKeepsTheOpeningFromFolding() {
        let collapse = sokuonLossCollapse
        let text = "ん " + collapse
        let collapsed = spacedTokens(["ん"], readings: ["ん"])
            + [token(collapse, start: 2)]
        var decodes = sokuonLossDecodes()
        decodes["んゃ"] = foldableSpan("んゃ")
        let fake = FakeCollapseTokenizer(decodes)

        let repaired = ReadingAnnotator.repairedTokens(
            collapsed, of: text, tokenize: { window in fake.tokenize(window) }
        )

        #expect(repaired.map(\.text) == ["ん", "ゃ"] + sokuonLossDecoded)
        #expect(!fake.windows.contains("んゃ"), "the fold crossed the gap: \(fake.windows)")
        #expect(tilesText(repaired, text))
    }

    /// The positive case the refusals above are measured against: a kana
    /// neighbour that is adjacent, non-numeric and all-kana takes the fold, and
    /// does so *after* the left-context walk has already declined it. So the
    /// refusal tests are refusing this and not merely declining a decode.
    @Test("a kana neighbour takes the fold, where the walk already gave up", arguments: [
        "よう", "ん", "き"
    ])
    func foldableNeighbourTakesTheFold(neighbour: String) {
        let collapse = sokuonLossCollapse
        let text = neighbour + collapse
        let collapsed = [token(neighbour, start: 0, reading: neighbour, base: neighbour)]
            + [token(collapse, start: neighbour.unicodeScalars.count)]
        let fold = neighbour + "ゃ"
        var decodes = sokuonLossDecodes()
        decodes[fold] = foldableSpan(fold)
        let fake = FakeCollapseTokenizer(decodes)

        let repaired = ReadingAnnotator.repairedTokens(
            collapsed, of: text, tokenize: { window in fake.tokenize(window) }
        )

        // The grown region's *first* window, which is as far as a windowed
        // attempt gets once it declines — the region is longer than one window
        // for any neighbour here, and a later window is never asked for once an
        // earlier one fails.
        let grown = String((neighbour + collapse).unicodeScalars.prefix(ReadingAnnotator.repairWindow))
        #expect(fake.windows == [collapse, grown, sokuonLossRemainder, fold],
                "windows: \(fake.windows)")
        #expect(repaired.map(\.text) == [fold] + sokuonLossDecoded)
        #expect(repaired.first?.base != nil)
        #expect(tilesText(repaired, text))
    }

    /// At most `repairPeelLimit` scalars are ever set aside: a third unstartable
    /// scalar belongs to the remainder, and the remainder's decode is what then
    /// has to carry it.
    @Test("no more than the peel limit is set aside")
    func peelIsBounded() {
        // One unstartable scalar more than the limit allows, on a run still wide
        // enough to be a collapse. What the lattice makes of the remainder is
        // scripted as one resolved row so the attempt succeeds and the width of
        // what it set aside is visible.
        let over = String(repeating: "っ", count: ReadingAnnotator.repairPeelLimit + 1)
        let tail = "あいうえお"
        let collapse = over + tail
        let setAside = String(repeating: "っ", count: ReadingAnnotator.repairPeelLimit)
        let remainder = String(over.dropFirst(ReadingAnnotator.repairPeelLimit)) + tail
        let fake = FakeCollapseTokenizer([
            remainder: tokens([remainder], readings: [remainder], bases: [remainder])
        ])

        let repaired = ReadingAnnotator.repairedTokens(
            [token(collapse, start: 0)], of: collapse, tokenize: { window in fake.tokenize(window) }
        )

        // The third unstartable scalar stayed with the remainder.
        #expect(repaired.map(\.text) == [setAside, remainder])
        #expect(tilesText(repaired, collapse))
    }

    // MARK: two collapses side by side

    /// Two collapses that *touch*: the first repair's span ends on the second's
    /// neighbour, so the second's fold would read a span this pass had already
    /// replaced. It must not. Folding there would re-decode the raw text of a
    /// run the previous attempt had just proven recoverable, and adopt that
    /// second answer in place of the first — losing the recovered words for a
    /// worse guess at the same characters.
    ///
    /// The first collapse is a repeated-vocable run, which the windowed rungs
    /// *can* resolve; the second opens on a stranded `ゃ`, which only the peel
    /// can. So the first repair is accepted, and the second runs immediately
    /// after with the first's replacement sitting where its neighbour used to
    /// be.
    @Test("a fold never reaches into a span an earlier repair replaced")
    func foldRefusesAnAlreadyRepairedNeighbour() {
        let first = kanaRun
        let text = first + sokuonLossCollapse
        // The fold the second peel would take if it could reach its neighbour.
        let fold = first + "ゃ"
        var decodes = sokuonLossDecodes()
        // The first run resolves windowed, the second's own region does not.
        decodes[first] = tokens(
            kanaRunWords, readings: kanaRunWords, bases: kanaRunWords
        )
        decodes[sokuonLossCollapse] = [token(sokuonLossCollapse, start: 0)]
        decodes[text] = [token(text, start: 0)]
        // The fold is resolvable, so the refusal is the watermark's and not the
        // decode's.
        decodes[fold] = foldableSpan(fold)
        let fake = FakeCollapseTokenizer(decodes)

        let repaired = ReadingAnnotator.repairedTokens(
            // Both entries reading-less: the first has to be a collapse for the
            // repair that rewrites it to happen at all.
            tokens([first, sokuonLossCollapse], readings: [nil, nil]),
            of: text,
            tokenize: { window in fake.tokenize(window) }
        )

        // The first run came apart; the second's opening stands alone rather
        // than folding into a neighbour the pass has already rewritten. The
        // grown region's first window is as far as it gets, since that one
        // declines.
        let grown = String(text.unicodeScalars.prefix(ReadingAnnotator.repairWindow))
        #expect(fake.windows == [
            first, sokuonLossCollapse, grown, sokuonLossRemainder
        ], "windows: \(fake.windows)")
        #expect(!fake.windows.contains(fold), "the fold reached back: \(fake.windows)")
        #expect(repaired.map(\.text) == kanaRunWords + ["ゃ"] + sokuonLossDecoded)
        #expect(tilesText(repaired, text))
    }

    // MARK: the attempt's place in the ladder

    /// The peel is gated on the opening, not offered for every decline. A long
    /// unknown that opens on a full-size kana may well be the
    /// dictionary-covered name the fallback tier's headword gate exists to
    /// protect — and this pass runs *ahead* of that gate, so the gate is the
    /// only thing standing between such a name and a cut. Offering the peel
    /// here would bypass it.
    ///
    /// Both halves of the claim are pinned: the ladder really did run and
    /// decline (so this is not "nothing happened"), and the peel's own window
    /// never appeared (so the gate is what stopped it). Neither assertion alone
    /// distinguishes those cases — an unrun ladder produces the same stream.
    @Test("a run opening on a full-size kana is never peeled", arguments: [
        "ソラシナソラシカ", "アルゴリズムです"
    ])
    func fullSizeOpeningIsNeverPeeled(collapse: String) {
        let neighbour = "な"
        let text = neighbour + collapse
        let collapsed = [token(neighbour, start: 0, reading: neighbour, base: neighbour)]
            + [token(collapse, start: 1)]
        // What a peel would ask for, scripted clean so that asking is visible.
        let peelWindow = String(collapse.dropFirst())
        let fake = FakeCollapseTokenizer([
            collapse: [token(collapse, start: 0)],
            neighbour + collapse: [token(text, start: 0)],
            peelWindow: foldableSpan(peelWindow)
        ])

        let repaired = ReadingAnnotator.repairedTokens(
            collapsed, of: text, tokenize: { window in fake.tokenize(window) }
        )

        // The walk ran to its end and the region still would not resolve…
        #expect(fake.windows == [collapse, text], "the ladder stopped early: \(fake.windows)")
        // …and the run does not open on anything a word cannot begin with, so
        // the peel's own window is never asked for.
        #expect(!fake.windows.contains(peelWindow), "the peel ran: \(fake.windows)")
        #expect(repaired.map(\.text) == [neighbour, collapse])
    }

    /// A peel the remainder will not resolve leaves the run exactly as the
    /// windowed attempts left it, and the fallback tier still fragments it — the
    /// peel is an added attempt, never a replacement for the old ones.
    @Test("a remainder that will not resolve declines to the fallback tier")
    func unresolvableRemainderDeclinesToFragmentation() throws {
        let input = "ゃ" + "ソラシナソラシカ"
        let canned = tokens([input], readings: [nil])
        let annotator = makeAnnotator(canned, headwordGate: { _ in false })
        let fake = FakeCollapseTokenizer([input: canned])

        let repaired = ReadingAnnotator.repairedTokens(
            canned, of: input, tokenize: { window in fake.tokenize(window) }
        )

        #expect(repaired == canned)
        let segments = try #require(annotator.segments(for: input))
        #expect(segments.count >= 2, "stayed whole: \(describe(segments))")
        #expect(segments.map(\.surface).joined() == input)
    }

    /// The peel's own budget, and what it costs when the fold is refused: the
    /// folded span is asked about either way — that is how the fold is found
    /// unfoldable — so a peel is two extra tokenizer calls on top of the two the
    /// left-context walk already spent declining.
    @Test("a peel costs exactly the remainder decode and the fold", arguments: [true, false])
    func peelCostIsBounded(canFold: Bool) {
        let fake = FakeCollapseTokenizer(
            sokuonLossDecodes(folded: canFold ? sokuonLossFolded : nil)
        )

        let repaired = ReadingAnnotator.repairedTokens(
            sokuonLossCollapsed, of: sokuonLossText, tokenize: { window in fake.tokenize(window) }
        )

        #expect(fake.windows == [
            sokuonLossCollapse, "なきゃいけないからとかっ", sokuonLossRemainder, sokuonLossFold
        ])
        // Only the acceptance differs: a foldable span is taken, an unfoldable
        // one leaves the opening alone and the neighbour as it was.
        #expect(repaired.map(\.text) == (canFold ? [sokuonLossFold] : [sokuonLossNeighbour, "ゃ"])
            + sokuonLossDecoded)
    }
}
