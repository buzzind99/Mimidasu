import Foundation
@testable import Mimidasu
import Testing

/// The scalar-offset arithmetic behind the accent highlight. This is the one
/// class of bug most likely to ship silently — a wrong offset does not crash,
/// it lights up the wrong morae — so the boundaries are pinned directly.
@Suite("MatchHighlight")
struct MatchHighlightTests {
    @Test("splits a field around the match")
    func splits() {
        let parts = MatchHighlight.split("to be defeated", at: 6 ..< 9)

        #expect(parts.before == "to be ")
        #expect(parts.match == "def")
        #expect(parts.after == "eated")
    }

    @Test("counts scalars, not characters, so a voiced kana is one unit")
    func scalarOffsets() {
        // 負 (kanji) け (hiragana) る (hiragana) — one scalar each.
        let parts = MatchHighlight.split("負ける", at: 0 ..< 1)
        #expect(parts.match == "負")
        #expect(parts.after == "ける")

        // The decomposed spelling is two scalars, and slicing must not split the
        // pair: 0 ..< 2 is the whole が, 0 ..< 1 is the か plus its mark.
        let decomposed = MatchHighlight.split("か\u{3099}", at: 0 ..< 1)
        #expect(decomposed.match == "か")
        #expect(decomposed.after == "\u{3099}")

        let composed = MatchHighlight.split("が", at: 0 ..< 1)
        #expect(composed.match == "が")
        #expect(composed.after.isEmpty)
    }

    @Test("clamps a span that no longer fits the string")
    func clamps() {
        #expect(MatchHighlight.split("愛", at: 0 ..< 9).match == "愛")
        #expect(MatchHighlight.split("愛", at: 4 ..< 9).match.isEmpty)
        #expect(MatchHighlight.split("", at: 0 ..< 1).match.isEmpty)
        // An inverted span is not reachable: `3 ..< 1` traps inside the range
        // literal itself, so out-of-range is the only clamp worth having.
    }

    @Test("finds the matched run case-insensitively, as the SQL LIKE does")
    func findsCaseInsensitively() {
        #expect(MatchHighlight.range(of: "lose", in: "to Lose, to be defeated") == 3 ..< 7)
        #expect(MatchHighlight.range(of: "lose", in: "to LOSE") == 3 ..< 7)
        #expect(MatchHighlight.range(of: "to", in: "to eat") == 0 ..< 2)
        #expect(MatchHighlight.range(of: "eat", in: "to eat") == 3 ..< 6)
        #expect(MatchHighlight.range(of: "eat", in: "to eat and to eat") == 3 ..< 6)
        // Nothing to find, nothing to highlight.
        #expect(MatchHighlight.range(of: "z", in: "to eat") == nil)
        #expect(MatchHighlight.range(of: "to eat and", in: "to eat") == nil)
        // An empty needle would match everywhere, which is never a highlight.
        #expect(MatchHighlight.range(of: "", in: "to eat") == nil)
    }
}
