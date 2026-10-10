import Foundation
@testable import Mimidasu
import Testing

/// The gloss sub-tiers are chosen across **every** occurrence of the pattern
/// in a sense column, not just the leftmost one within each gloss. Offline
/// pins for the shapes that decide a row's tier; the graded-corpus proof that
/// the fast path agrees lives in `GlossGradingDifferentialTests`.
@Suite("GlossMatch occurrence grading")
struct GlossMatchOccurrenceTests {

    @Test("a later word-boundary occurrence outranks the leftmost one")
    func laterOccurrenceOutranks() {
        // The first `iced` opens the fragment (prefix tier) while the second
        // stands alone between spaces; the row takes the better tier, and the
        // span of the occurrence that earned it — not the leftmost span.
        let match = DictionarySearchEngine.glossMatch(
            pattern: "iced",
            column: "cold" + String(JMDictPin.glossJoiner) + "iced (e.g. iced tea, iced coffee"
        )

        #expect(match.kind == .glossWordBoundary)
        #expect(match.gloss == "iced (e.g. iced tea, iced coffee")
        #expect(match.range == 11 ..< 15)
    }

    @Test("a tied tier keeps the leftmost occurrence's span")
    func tiedTierKeepsLeftmost() {
        // The first occurrence already reached the best tier there is, so the
        // scan stops there and its span is the one the row highlights.
        let match = DictionarySearchEngine.glossMatch(
            pattern: "iced", column: "iced" + String(JMDictPin.glossJoiner) + "iced tea"
        )

        #expect(match.kind == .glossWordBoundary)
        #expect(match.gloss == "iced")
        #expect(match.range == 0 ..< 4)
    }

    @Test("a gloss whose own text contains \"; \" stays one gloss")
    func embeddedSemicolonSpaceStaysOneGloss() {
        // The historical joiner occurs inside real glosses, which is why the
        // stored joiner is a character a gloss cannot carry: the column below
        // is one gloss, not three, and the match spans inside it whole.
        let column = "to scoop up (and remove; sand, earth, etc.)"
        let match = DictionarySearchEngine.glossMatch(pattern: "sand", column: column)

        #expect(match.gloss == column)
        #expect(match.range == 25 ..< 29)
    }

    private static let joiner = String(JMDictPin.glossJoiner)

    private static let glossListInputs = [
        "to eat" + joiner + "to live on",
        "a" + joiner + "a" + joiner + " ",
        "",
        "to scoop up (and remove; sand, earth, etc.)"
    ]

    private static let glossListExpected: [[String]] = [
        ["to eat", "to live on"],
        ["a"],
        [],
        ["to scoop up (and remove; sand, earth, etc.)"]
    ]

    @Test("splits a sense's stored gloss column back into glosses",
          arguments: zip(glossListInputs, glossListExpected))
    func glossList(input: String, expected: [String]) {
        #expect(DictionarySearchEngine.glossList(input) == expected)
    }
}
