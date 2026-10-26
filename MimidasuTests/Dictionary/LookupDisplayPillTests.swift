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
        // Both related hits match the shared reading あめ, so the favorite 雨
        // is eligible in each; the two results carry different entries, and
        // the re-selected choice itself is filtered out of the pill row.
        let tapped = LookupResult(
            matched: "あめ",
            entries: [
                harness.entry(keb: "飴", reb: "あめ", seq: 1),
                harness.entry(keb: "雨", reb: "あめ", seq: 2)
            ]
        )
        let sibling = LookupResult(
            matched: "あめ",
            entries: [
                harness.entry(keb: "別", reb: "あめ", seq: 3),
                harness.entry(keb: "雨", reb: "あめ", seq: 4)
            ]
        )
        let content = LookupContent.notFound(surface: "雨尾", related: [tapped, sibling])
        let favorites = FavoriteIdentity(keys: [FavoriteIdentity.normalize("雨")])

        let promoted = display.promote(tapped, in: content, favorites: favorites)

        guard case let .found(displayed, also, origin) = promoted else {
            Issue.record("the related selection stopped being found")
            return
        }
        #expect(origin == .tappedSurface)
        #expect(displayed.matched == "あめ")
        #expect(displayed.entries.map(\.entSeq) == [2, 1])
        #expect(displayed.entries.map(\.keb) == ["雨", "飴"])
        #expect(also.count == 1)
        #expect(also.first?.matched == "あめ")
        #expect(also.first?.entries.map(\.entSeq) == [4, 3])
        #expect(also.first?.entries.first?.keb == "雨")
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

    @Test(
        "the pager steps the display entries and clamps at both ends",
        arguments: [(1, 1), (99, 1), (-5, 0)]
    )
    func pagerStepsAndClamps(target: Int, expected: Int) async throws {
        let content = try await harness.shownContent(for: harness.requestAme())

        let count = try #require(content.displayResult?.entries.count)
        #expect(count == 2)

        let stepped = harness.makeDisplay().steppedEntry(in: content, to: target)

        #expect(stepped == expected)
    }

    @Test("the pager is inert on not-found content and without content")
    func pagerInertWithoutDisplay() {
        let notFound = LookupContent.notFound(
            surface: "雨尾", related: [harness.result(["雨"])]
        )

        let fromNotFound = harness.makeDisplay().steppedEntry(in: notFound, to: 0)
        let fromNil = harness.makeDisplay().steppedEntry(in: nil, to: 0)

        #expect(fromNotFound == nil)
        #expect(fromNil == nil)
    }
}
