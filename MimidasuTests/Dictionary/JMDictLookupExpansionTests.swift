import Foundation
@testable import Mimidasu
import Testing

/// The engine-level expansion entry point over the fixture database.
@Suite("JMDictLookup forward expansion")
final class JMDictLookupExpansionTests {
    private let databaseURL: URL
    private let engine: JMDictLookup

    init() throws {
        let built = try JMDictFixtureDatabase.build()
        databaseURL = built.url
        engine = JMDictLookup(resolveDatabase: { [url = built.url] in url })
    }

    deinit {
        engine.close()
        JMDictFixtureDatabase.Built(url: databaseURL).remove()
    }

    private struct ResolutionMismatch: Error {}

    /// Unwraps a found resolution — recording a failure for a not-found
    /// one (the split-only demotion) so the expectation stays in the
    /// assertion that asked for it.
    private func foundOutcome(_ resolution: LookupResolution) throws -> LookupOutcome {
        guard case let .found(outcome) = resolution else {
            Issue.record("expected .found, got \(resolution)")
            throw ResolutionMismatch()
        }
        return outcome
    }

    @Test("displays the tapped piece: お resolves お, お土産 lands in also")
    func compoundHit() throws {
        let outcome = try foundOutcome(engine.lookup(
            segments: [LookupSegment(surface: "お"), LookupSegment(surface: "土産", lemma: "土産")],
            tappedAt: 0,
            sentenceText: "お土産"
        ))

        #expect(outcome.display.matched == "お")
        #expect(outcome.displayOrigin == .tappedSurface)
        #expect(outcome.display.entries.map(\.entSeq) == [9_990_040])
    }

    @Test("displays the join when the tapped piece alone misses, labeled by the join origin")
    func joinFallbackHit() throws {
        let outcome = try foundOutcome(engine.lookup(
            segments: [LookupSegment(surface: "お土"), LookupSegment(surface: "産", lemma: "産")],
            tappedAt: 0,
            sentenceText: "お土産"
        ))

        #expect(outcome.display.matched == "お土産")
        #expect(outcome.displayOrigin == .join)
        #expect(outcome.display.entries.map(\.entSeq) == [1_002_500])
    }

    @Test("joins across a whitespace gap the segments carry")
    func whitespaceGapHit() throws {
        let outcome = try foundOutcome(engine.lookup(
            segments: [
                LookupSegment(surface: "お"),
                LookupSegment(surface: " "),
                LookupSegment(surface: "土産", lemma: "土産")
            ],
            tappedAt: 0,
            sentenceText: "お 土産"
        ))

        #expect(outcome.display.matched == "お")
        #expect(outcome.also.map(\.matched) == ["お土産"])
    }

    @Test("falls back to the lemma when the joins miss")
    func lemmaFallbackHit() throws {
        let outcome = try foundOutcome(engine.lookup(
            segments: [
                LookupSegment(surface: "食べ", lemma: "食べる"),
                LookupSegment(surface: "ま"),
                LookupSegment(surface: "した")
            ],
            tappedAt: 0,
            sentenceText: "食べました"
        ))

        #expect(outcome.display.matched == "食べる")
        #expect(outcome.displayOrigin == .tappedLemma)
        #expect(outcome.display.entries.map(\.entSeq) == [1_358_280])
    }

    @Test("a potential-form lemma resolves through the unwrapped source verb")
    func potentialLemmaResolutionHit() throws {
        let outcome = try foundOutcome(engine.lookup(
            segments: [LookupSegment(surface: "食べられ", lemma: "食べられる")],
            tappedAt: 0,
            sentenceText: "食べられ"
        ))

        #expect(outcome.display.matched == "食べる")
        #expect(outcome.displayOrigin == .tappedLemma)
        #expect(outcome.display.entries.map(\.entSeq) == [1_358_280])
    }

    @Test("retains the longer-join hits that add new entries as results")
    func shorterHitsRetained() throws {
        let outcome = try foundOutcome(engine.lookup(
            segments: [LookupSegment(surface: "お"), LookupSegment(surface: "土産", lemma: "土産")],
            tappedAt: 0,
            sentenceText: "お土産"
        ))

        #expect(outcome.also.map(\.matched) == ["お土産"])
        #expect(outcome.also[0].entries.map(\.entSeq) == [1_002_500])
    }

    @Test("a whole-word miss resolved only by splits is not-found with related hits")
    func splitOnlyResolutionIsNotFound() throws {
        let resolution = try engine.lookup(
            segments: [LookupSegment(surface: "雨尾")],
            tappedAt: 0,
            sentenceText: "雨尾"
        )

        // 雨尾 is no headword: the split candidates resolve both kanji —
        // but neither leads the display result. The demoted hits travel
        // as related, longest match first (ties keep candidate order).
        guard case let .notFound(related) = resolution else {
            Issue.record("expected .notFound, got \(resolution)")
            return
        }

        #expect(related.map(\.matched) == ["雨", "尾"])
        #expect(related.map { hit in hit.entries.map(\.entSeq) } == [[9_990_030], [9_990_040]])
    }

    @Test("related drops a later split hit that only re-resolves known entries")
    func relatedDeduplicatesByEntries() throws {
        let resolution = try engine.lookup(
            segments: [LookupSegment(surface: "前先")],
            tappedAt: 0,
            sentenceText: "前先"
        )

        // 前先 is no headword: both single-kanji splits resolve — but 先 is
        // an alternate writing of the entry 前 already resolved, so it is a
        // duplicate pill, not a new one.
        guard case let .notFound(related) = resolution else {
            Issue.record("expected .notFound, got \(resolution)")
            return
        }
        #expect(related.map(\.matched) == ["前"])
        #expect(related.map { hit in hit.entries.map(\.entSeq) } == [[9_990_060, 9_990_050]])
    }

    @Test("a compound hit displays and its split hits trail in also")
    func compoundDisplaySplitsTrail() throws {
        // 風通し keeps the also-list empty — the 風通 / 風 / 通 splits all
        // miss the fixture (風呂敷 can't: the boundary-crossing 呂敷 split
        // resolves the synthetic entry).
        let outcome = try foundOutcome(engine.lookup(
            segments: [LookupSegment(surface: "風通し")],
            tappedAt: 0,
            sentenceText: "風通し"
        ))

        #expect(outcome.display.matched == "風通し")
        #expect(outcome.display.entries.map(\.entSeq) == [1_500_010])
        #expect(outcome.also.isEmpty)
    }

    @Test("a cross-boundary split of the join trails in also")
    func joinedSplitCrossBoundaryHit() throws {
        let outcome = try foundOutcome(engine.lookup(
            segments: [LookupSegment(surface: "風呂"), LookupSegment(surface: "敷")],
            tappedAt: 0,
            sentenceText: "風呂敷"
        ))

        // The join 風呂敷 displays (origin .join); the tapped surface's
        // splits (風, 呂) miss the fixture and the boundary-crossing 呂敷
        // split resolves the compound's inner word as an "also:" result.
        #expect(outcome.display.matched == "風呂敷")
        #expect(outcome.displayOrigin == .join)
        #expect(outcome.display.entries.map(\.entSeq) == [1_500_150])
        #expect(outcome.also.map(\.matched) == ["呂敷"])
        #expect(outcome.also[0].entries.map(\.entSeq) == [9_990_090])
    }

    @Test("the tap's furigana ranks the matching entry first in the display result")
    func furiganaRanksEntryFirst() throws {
        let outcome = try foundOutcome(engine.lookup(
            segments: [LookupSegment(surface: "前", reading: "まえ")],
            tappedAt: 0,
            sentenceText: "前"
        ))

        #expect(outcome.display.entries.map(\.entSeq) == [9_990_060, 9_990_050])
    }

    @Test("every candidate missing is an empty not-found, not an error")
    func noHitReturnsEmptyNotFound() throws {
        let resolution = try engine.lookup(
            segments: [LookupSegment(surface: "きのこっぷ")],
            tappedAt: 0,
            sentenceText: "きのこっぷ"
        )

        #expect(resolution == .notFound(related: []))
    }

    @Test("an infrastructure error on any query aborts the tap as a throw")
    func infraErrorPropagates() throws {
        _ = try engine.lookup(LookupCandidate(text: "食べる"))
        engine.close()

        let thrown = #expect(throws: JMDictLookupError.self) {
            try engine.lookup(
                segments: [LookupSegment(surface: "食べ", lemma: "食べる"), LookupSegment(surface: "ま")],
                tappedAt: 0,
                sentenceText: "食べま"
            )
        }

        #expect(thrown == .databaseClosed)
    }
}
