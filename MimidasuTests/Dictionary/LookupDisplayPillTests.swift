@testable import Mimidasu
import Testing

/// Pill re-promotion purity, pager clamping, and tap re-anchoring over the
/// shared Lookup Display harness: promotions are copy-on-write verdict
/// rebuilds that fail closed on foreign choices, the pager steps and clamps
/// without ever surfacing a not-found entry, and the re-anchor suite covers
/// the drifted-tap resolutions end to end plus the `reAnchoredTapIndex`
/// seam directly.
@Suite("LookupDisplay pills and pager")
final class LookupDisplayPillTests {
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

    @Test("an in-bounds tap shows the same verdict")
    func inBoundsTapShowsSameVerdict() async {
        let display = harness.makeDisplay()
        let request = TapLookupRequest(
            segments: [
                LookupSegment(surface: "お"),
                LookupSegment(surface: "土産", lemma: "土産")
            ],
            tappedAt: 0,
            sentenceText: "お土産",
            surface: "お"
        )

        let effect = await display.resolve(request, favorites: .empty)

        guard case let .show(content, _) = effect else {
            Issue.record("expected show, got \(effect)")
            return
        }
        // Stored 0 is also the first rescan hit, so the verdict is the same
        // either way: this pins the verdict only, not the keep-stored
        // mechanism — the keep-vs-rescan discrimination lives in the seam
        // tests below.
        #expect(content.displayResult?.matched == "お")
        #expect(content.fallbackResults.map(\.matched) == ["お土産"])
        guard case let .found(_, _, origin) = content else {
            Issue.record("expected found content")
            return
        }
        #expect(origin == .tappedSurface)
    }

    @Test("an out-of-bounds tap with no matching surface warns")
    func outOfBoundsTapWithoutMatchingSurfaceWarns() async {
        let display = harness.makeDisplay()
        let request = TapLookupRequest(
            segments: [
                LookupSegment(surface: "お"),
                LookupSegment(surface: "土産", lemma: "土産")
            ],
            tappedAt: 9,
            sentenceText: "お土産",
            surface: "xyz"
        )

        let effect = await display.resolve(request, favorites: .empty)

        #expect(effect == .warnNoHit(surface: "xyz"))
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

    @Test("the seam keeps an in-bounds stored index whose surface agrees")
    func seamKeepsAgreeingStoredIndex() {
        // Agreement is checked at the stored slot itself: 1 matches 土産, so
        // the stored index is kept.
        #expect(
            LookupDisplay.reAnchoredTapIndex(
                stored: 1,
                surface: "土産",
                in: [LookupSegment(surface: "お"), LookupSegment(surface: "土産", lemma: "土産")]
            ) == 1
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

    @Test("a duplicate surface re-anchors to the first occurrence and shows")
    func duplicateSurfaceReanchorsToFirstOccurrence() async {
        let display = harness.makeDisplay()
        let request = TapLookupRequest(
            segments: [
                LookupSegment(surface: "お"),
                LookupSegment(surface: "お", lemma: "尾")
            ],
            tappedAt: 9,
            sentenceText: "おお",
            surface: "お"
        )

        let effect = await display.resolve(request, favorites: .empty)

        guard case let .show(content, _) = effect else {
            Issue.record("expected show, got \(effect)")
            return
        }
        #expect(content.displayResult?.matched == "お")
        // Behavior smoke only: the tapped surface candidate reaches the
        // engine before the lemma, so either tiebreak order resolves
        // identically through the fixture — the discriminating
        // first-occurrence pin lives in the re-anchor seam tests above.
        guard case let .found(_, _, origin) = content else {
            Issue.record("expected found content")
            return
        }
        #expect(origin == .tappedSurface)
    }

    @Test("an also-pill promotion fully re-selects and the row recomputes")
    func promoteAlsoPillRecomputesRow() async throws {
        let content = try await harness.shownContent(for: harness.requestO())
        let choice = try #require(content.fallbackResults.first)

        let promoted = harness.makeDisplay().promote(choice, in: content, favorites: .empty)

        guard case let .found(display, also, origin) = promoted else {
            Issue.record("expected found content")
            return
        }
        #expect(display.matched == "お土産")
        #expect(also.map(\.matched) == ["お"])
        #expect(origin == .tappedSurface)
    }

    @Test("a related-pill promotion opens on the favorite and sibling pills re-promote")
    func promoteRelatedPillOpensOnFavorite() {
        let display = harness.makeDisplay()
        let tapped = harness.result(["雨", "見る"])
        let sibling = harness.result(["尾", "見る"])
        let content = LookupContent.notFound(surface: "雨尾", related: [tapped, sibling])
        let favorites = FavoriteIdentity(keys: [FavoriteIdentity.normalize("見る")])

        let promoted = display.promote(tapped, in: content, favorites: favorites)

        guard case let .found(displayed, also, origin) = promoted else {
            Issue.record("the related selection stopped being found")
            return
        }
        #expect(origin == .tappedSurface)
        #expect(displayed.entries.map(\.keb) == ["見る", "雨"])
        #expect(also.map(\.matched) == ["尾"])
        #expect(also.first?.entries.first?.keb == "見る")
    }

    @Test("promoting a foreign choice fails closed to the content unchanged")
    func promoteForeignChoiceFailsClosed() {
        let display = harness.makeDisplay()
        let content = LookupContent.found(
            result: harness.result(["お"]),
            also: [harness.result(["お土産"])],
            origin: .tappedSurface
        )
        let foreign = harness.result(["foreign"])

        let promoted = display.promote(foreign, in: content, favorites: .empty)

        #expect(promoted == content)
    }

    @Test("re-promoting the display preserves its join origin")
    func promoteSameDisplayPreservesOrigin() {
        let display = harness.makeDisplay()
        let joined = harness.result(["お土産"])
        let content = LookupContent.found(
            result: joined, also: [harness.result(["お"])], origin: .join
        )

        let promoted = display.promote(joined, in: content, favorites: .empty)

        guard case let .found(redisplay, also, origin) = promoted else {
            Issue.record("expected found content")
            return
        }
        #expect(redisplay == joined)
        #expect(also.map(\.matched) == ["お"])
        #expect(origin == .join)
    }

    @Test("a cross-pill round trip drops the join badge for good")
    func promoteRoundTripDropsJoinOrigin() {
        let display = harness.makeDisplay()
        let joined = harness.result(["お土産"])
        let single = harness.result(["お"])
        let start = LookupContent.found(result: joined, also: [single], origin: .join)
        let moved = display.promote(single, in: start, favorites: .empty)
        let back = display.promote(joined, in: moved, favorites: .empty)
        #expect(moved == .found(result: single, also: [joined], origin: .tappedSurface))
        #expect(back == .found(result: joined, also: [single], origin: .tappedSurface))
    }

    @Test("the pager steps the display entries")
    func pagerStepsToEntry() async throws {
        let content = try await harness.shownContent(for: harness.requestAme())

        let count = try #require(content.displayResult?.entries.count)
        #expect(count == 2)

        let stepped = harness.makeDisplay().steppedEntry(in: content, to: 1)

        #expect(stepped == 1)
    }

    @Test("the pager clamps past the last entry")
    func pagerClampsPastEnd() async throws {
        let content = try await harness.shownContent(for: harness.requestAme())

        let stepped = harness.makeDisplay().steppedEntry(in: content, to: 99)

        #expect(stepped == (content.displayResult?.entries.count ?? 0) - 1)
    }

    @Test("the pager clamps before the first entry")
    func pagerClampsBeforeStart() async throws {
        let content = try await harness.shownContent(for: harness.requestAme())

        let stepped = harness.makeDisplay().steppedEntry(in: content, to: -5)

        #expect(stepped == 0)
    }

    @Test("the pager is inert on not-found content")
    func pagerNilOnNotFound() {
        let content = LookupContent.notFound(
            surface: "雨尾", related: [harness.result(["雨"])]
        )

        let stepped = harness.makeDisplay().steppedEntry(in: content, to: 0)

        #expect(stepped == nil)
    }

    @Test("the pager is inert without content")
    func pagerNilOnNilContent() {
        let stepped = harness.makeDisplay().steppedEntry(in: nil, to: 0)

        #expect(stepped == nil)
    }
}
