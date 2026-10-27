@testable import Mimidasu
import Testing

/// Tap re-anchoring over the shared Lookup Display harness: the drifted-tap
/// resolution end to end, plus the `reAnchoredTapIndex` seam directly — the
/// defensive single place where a request whose stored index disagrees with
/// its segments is recovered before the engine lookup.
@Suite("LookupDisplay re-anchor")
final class LookupDisplayReanchorTests {
    private let harness: LookupDisplayHarness

    init() throws {
        harness = try LookupDisplayHarness()
    }

    @Test("an out-of-bounds tap re-anchors to the matching surface and shows")
    func outOfBoundsTapReanchorsToMatchingSurface() async {
        let display = harness.makeDisplay()
        let request = TapLookupRequest(
            segments: [
                LookupSegment(surface: "お"),
                LookupSegment(surface: "土産", lemma: "土産")
            ],
            tappedAt: 9,
            sentenceText: "お土産",
            surface: "お"
        )

        let effect = await display.resolve(request, favorites: .empty)

        guard case let .show(content, _) = effect else {
            Issue.record("expected show, got \(effect)")
            return
        }
        #expect(content.displayResult?.matched == "お")
        // The re-anchor picked the first segment, not the drifted slot: the
        // verdict matches the in-bounds tap exactly, pills included.
        #expect(content.fallbackResults.map(\.matched) == ["お土産"])
        guard case let .found(_, _, origin) = content else {
            Issue.record("expected found content")
            return
        }
        #expect(origin == .tappedSurface)
    }

    // MARK: Re-anchor seam

    @Test("the seam re-anchors a duplicate surface to its first occurrence")
    func seamReanchorsDuplicateSurfaceToFirstOccurrence() {
        // Stored 9 is out of bounds, so the re-anchor must pick the first of
        // the two お segments — the tiebreak the end-to-end fixture cannot
        // discriminate.
        #expect(
            LookupDisplay.reAnchoredTapIndex(
                stored: 9,
                surface: "お",
                in: [LookupSegment(surface: "お"), LookupSegment(surface: "お", lemma: "尾")]
            ) == 0
        )
    }

    @Test("the seam keeps the stored slot over a rescan at a second occurrence")
    func seamKeepsStoredOverRescanAtSecondOccurrence() {
        // The keep-vs-rescan discriminator: the stored slot 1 itself agrees
        // (its surface is お), so keep-stored answers 1 — an always-rescan
        // implementation would answer the first occurrence, 0.
        #expect(
            LookupDisplay.reAnchoredTapIndex(
                stored: 1,
                surface: "お",
                in: [LookupSegment(surface: "お"), LookupSegment(surface: "お", lemma: "尾")]
            ) == 1
        )
    }

    @Test("the seam falls through to the segment count when no surface matches")
    func seamFallsThroughToSegmentCountWithoutMatch() {
        // Pins the `?? segments.count` fallthrough directly: the stored slot
        // disagrees and no segment carries the surface, so the out-of-band
        // count is all that is left to answer.
        #expect(
            LookupDisplay.reAnchoredTapIndex(
                stored: 0,
                surface: "xyz",
                in: [LookupSegment(surface: "お"), LookupSegment(surface: "土産")]
            ) == 2
        )
    }

    @Test("the seam rescans an in-bounds stored slot whose surface disagrees")
    func seamRescansDisagreeingStoredSlot() {
        // Stored slot 1 is 土産, which disagrees with お, so the stored index
        // is discarded and the rescan answers the earlier first occurrence.
        #expect(
            LookupDisplay.reAnchoredTapIndex(
                stored: 1,
                surface: "お",
                in: [LookupSegment(surface: "お"), LookupSegment(surface: "土産")]
            ) == 0
        )
    }

    @Test("the seam re-anchors an out-of-bounds stored index to a later match")
    func seamReanchorsOutOfBoundsToLaterMatch() {
        // Stored 9 is out of bounds, so the rescan walks the segments and
        // answers the second occurrence of 土産, not the front.
        #expect(
            LookupDisplay.reAnchoredTapIndex(
                stored: 9,
                surface: "土産",
                in: [LookupSegment(surface: "お"), LookupSegment(surface: "土産")]
            ) == 1
        )
    }

    @Test("the seam fails closed to the stored index on nil and empty segments")
    func seamFailsClosedWithoutSegments() {
        #expect(LookupDisplay.reAnchoredTapIndex(stored: 3, surface: "お", in: nil) == 3)
        #expect(LookupDisplay.reAnchoredTapIndex(stored: 3, surface: "お", in: []) == 3)
    }
}
