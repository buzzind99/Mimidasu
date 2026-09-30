import Foundation
@testable import Mimidasu
import Testing

// MARK: - What the pass will and will not look at

// The collapse gate, the unstartable set it hands the peel, and the span the
// peel reuses. Split out of the ladder suite: these are about which runs the
// pass considers at all, and about the two sets whose contents are load-bearing
// claims rather than tuning numbers.

/// Both sets the pass reasons from are claims, not numbers: the collapse gate
/// decides which runs are worth a tokenizer call at all, and
/// `unstartableScalars` is what the peel's gate — and through it this pass's
/// licence to run ahead of the fallback tier's headword gate — rests on. A wrong
/// entry in either is invisible to the ladder tests, so they are pinned here
/// against the code they claim to describe.
@Suite("ReadingAnnotator collapse gate")
struct ReadingAnnotatorTokenRepairGateTests {

    /// The ladder's numbers, pinned literally. Tautological on its own — it
    /// restates the source — and it earns that by catching a constant that the
    /// other tests were *rewritten around*: `peelIsBounded` derives its fixture
    /// from `repairPeelLimit` and so cannot detect a wrong limit, and the walk
    /// tests measure a step against `repairLeftContext`.
    @Test("the window cap, the left-context budget and the peel limit are the shared constants")
    func repairConstants() {
        #expect(ReadingAnnotator.repairWindow == 12)
        #expect(ReadingAnnotator.repairLeftContext == 8)
        #expect(ReadingAnnotator.fragmentLengthThreshold == 8)
        #expect(ReadingAnnotator.repairPeelLimit == 2)
    }

    /// Nothing outside Japanese script has word boundaries to recover, and a
    /// re-decode would spend the whole attempt budget to decline. Latin and
    /// digit runs are left to the fallback tier, which already declines them.
    ///
    /// The last two arguments are the reason the gate is not just
    /// `containsJapanese`: ・ and ー are counted as kana by
    /// `KanaClassification` (both inside `0x30A1...0x30FF`), so a run made
    /// only of them reads as Japanese and still has no headword to find — and no
    /// unstartable opening to peel, so every attempt would decline, under the
    /// tokenizer's global lock, on every live-partial revision.
    @Test("a long run with nothing word-forming in it is never re-decoded", arguments: [
        "abcdefghijklmnop", "1234567890123", "ABCDEFGHIJKLMNOPQRST",
        "・・・・・・・・", "ーーーーーーーー", "・・・・ーーーーーー"
    ])
    func nonJapaneseRunIsNeverConsidered(text: String) {
        let collapsed = [token(text, start: 0)]
        let fake = FakeCollapseTokenizer()

        let repaired = ReadingAnnotator.repairedTokens(
            collapsed, of: text, tokenize: { window in fake.tokenize(window) }
        )

        #expect(fake.windows.isEmpty)
        #expect(repaired == collapsed)
    }

    /// `unstartableScalars` is the set the peel's gate — and, through it, the
    /// pass's licence to run ahead of the fallback tier's headword gate — rests
    /// on, and it had no coverage at all. Two properties, both load-bearing:
    ///
    /// - it holds the small kana and the geminate in both widths, and
    /// - it holds *nothing that can open a word*, because the gate is the only
    ///   thing keeping a dictionary-covered long name from being cut here.
    ///   `ヴ` was in it and is not: `KanaRomaji` reads `ヴァ` as one unit and
    ///   converts a bare `ヴ` on its own, so a name opening `ヴァ…` would have
    ///   been peeled with the gate bypassed.
    @Test("the unstartable set is the small kana and the geminate, in every width")
    func unstartableSetIsTheSmallKana() {
        let hiragana: Set<Unicode.Scalar> = [
            "ぁ", "ぃ", "ぅ", "ぇ", "ぉ", "ゃ", "ゅ", "ょ", "ゎ", "ゕ", "ゖ", "っ"
        ]
        let katakana: Set<Unicode.Scalar> = [
            "ァ", "ィ", "ゥ", "ェ", "ォ", "ャ", "ュ", "ョ", "ヮ", "ヵ", "ヶ", "ッ"
        ]
        let halfwidth: Set<Unicode.Scalar> = [
            "\u{ff67}", "\u{ff68}", "\u{ff69}", "\u{ff6a}", "\u{ff6b}",
            "\u{ff6c}", "\u{ff6d}", "\u{ff6e}", "\u{ff6f}", "\u{ff9c}"
        ]
        #expect(ReadingAnnotator.unstartableScalars == hiragana.union(katakana).union(halfwidth))

        // And it holds nothing that can open a word. The two that used to be in
        // it are out, and `KanaRomaji` is the evidence: both are the *first*
        // scalar of a digraph — ヴァ/ゔぁ → "va" — and a bare ヴ converts on its
        // own, so neither is word-unstartable and neither may be peeled past
        // the fallback tier's headword gate.
        #expect(!ReadingAnnotator.unstartableScalars.contains("ヴ"))
        #expect(!ReadingAnnotator.unstartableScalars.contains("ゔ"))
        #expect(KanaRomaji.romaji(fromKana: "ヴァ") == "va")
        #expect(KanaRomaji.romaji(fromKana: "ゔぁ") == "va")
        #expect(KanaRomaji.romaji(fromKana: "ヴ") == "vu")
        // The two that stay, for contrast: each is the *second* half of a
        // digraph and opens nothing on its own.
        #expect(KanaRomaji.romaji(fromKana: "きゃ") == "kya")
        #expect(KanaRomaji.romaji(fromKana: "しゃ") == "sha")
    }

    /// A halfwidth opening peels like its fullwidth twin. `KanaClassification`
    /// counts `0xFF66...0xFF9F` as kana, so the left-context walk already
    /// accepts these; before they were in the set the walk would step in and
    /// the peel would then decline for ever, on a transcript it had reached.
    /// The transcript itself carries the halfwidth scalar — a fullwidth one
    /// would be a different test, and `scalarSlice` reads the text, not the
    /// token's own copy of it.
    @Test("a halfwidth unstartable opening peels, and folds like the fullwidth one")
    func halfwidthUnstartableOpeningPeels() {
        let neighbour = "なき"
        let head = "\u{ff6c}" // halfwidth small ya
        let tail = String(repeating: "あ", count: 7)
        let collapse = head + tail
        let text = neighbour + collapse
        let fold = neighbour + head
        let fake = FakeCollapseTokenizer([
            // Both the bare region and the one-token-wider region still collapse.
            collapse: [token(collapse, start: 0)],
            text: [token(text, start: 0)],
            tail: tokens([tail], readings: [tail], bases: [tail]),
            fold: tokens([fold], readings: ["なや"], bases: ["なや"])
        ])

        let repaired = ReadingAnnotator.repairedTokens(
            tokens([neighbour, collapse], readings: ["なき", nil]),
            of: text,
            tokenize: { window in fake.tokenize(window) }
        )

        #expect(fake.windows == [collapse, text, tail, fold], "windows: \(fake.windows)")
        #expect(repaired.map(\.text) == [fold, tail])
        #expect(tilesText(repaired, text))
    }

    /// `peeledRepair` reuses the collapse's declared span verbatim, so it guards
    /// it the way `redecoded` does — `scalarSlice` clamps, and a clamped span
    /// would rebase its replacement off an offset the text cannot answer for,
    /// dropping the tail the clamp hid. Not producible through the shipped
    /// tokenizer (vibrato's `range_char()` is always in range), so this pins the
    /// guard rather than a live crash: a span starting off the front of the
    /// text, and one running past its end.
    @Test("a collapse whose span leaves the text is declined, not clamped", arguments: [
        -3, 13
    ])
    func outOfRangeCollapseIsDeclined(start: Int) {
        let text = "ゃ" + "いけないからとかって"
        let width = text.unicodeScalars.count
        let collapsed = [DictionaryToken(
            text: text, start: start, end: start + width, reading: nil, base: nil, pos: nil
        )]
        let fake = FakeCollapseTokenizer()

        let repaired = ReadingAnnotator.repairedTokens(
            collapsed, of: text, tokenize: { window in fake.tokenize(window) }
        )

        #expect(repaired == collapsed, "span at \(start) was adopted")
        // Nothing was even handed to the tokenizer: the span is refused before
        // either the re-decode or the peel can reuse it.
        #expect(fake.windows.isEmpty, "windows: \(fake.windows)")
    }
}
