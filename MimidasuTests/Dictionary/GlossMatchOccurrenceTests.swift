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
            pattern: "iced", column: "cold; iced (e.g. iced tea, iced coffee"
        )

        #expect(match.kind == .glossWordBoundary)
        #expect(match.gloss == "iced (e.g. iced tea, iced coffee")
        #expect(match.range == 11 ..< 15)
    }

    @Test("a tied tier keeps the leftmost occurrence's span")
    func tiedTierKeepsLeftmost() {
        // The first occurrence already reached the best tier there is, so the
        // scan stops there and its span is the one the row highlights.
        let match = DictionarySearchEngine.glossMatch(pattern: "iced", column: "iced; iced tea")

        #expect(match.kind == .glossWordBoundary)
        #expect(match.gloss == "iced")
        #expect(match.range == 0 ..< 4)
    }
}
