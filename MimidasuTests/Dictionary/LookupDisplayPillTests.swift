@testable import Mimidasu
import Testing

/// Pill re-promotion purity and pager clamping over the shared Lookup
/// Display harness: promotions are copy-on-write verdict rebuilds that fail
/// closed on foreign choices, and the pager steps and clamps without ever
/// surfacing a not-found entry.
@Suite("LookupDisplay pills and pager")
final class LookupDisplayPillTests {
    private let harness: LookupDisplayHarness

    init() throws {
        harness = try LookupDisplayHarness()
    }

    @Test(
        "tap re-anchor keeps the stored index while segments agree, else re-anchors to the surface",
        arguments: [
            (stored: 1, surface: "土産", expected: 1),
            (stored: 1, surface: "お", expected: 0),
            (stored: 0, surface: "xyz", expected: 2),
            (stored: 9, surface: "土産", expected: 1)
        ]
    )
    func reAnchoredTapIndex(stored: Int, surface: String, expected: Int) {
        let segments: [LookupSegment]? = [
            LookupSegment(surface: "お"), LookupSegment(surface: "土産", lemma: "土産")
        ]

        #expect(LookupDisplay.reAnchoredTapIndex(
            stored: stored, surface: surface, in: segments
        ) == expected)
    }

    @Test("tap re-anchor fails closed over nil and empty segments")
    func reAnchoredTapIndexNilSegments() {
        #expect(LookupDisplay.reAnchoredTapIndex(stored: 3, surface: "お", in: nil) == 3)
        #expect(LookupDisplay.reAnchoredTapIndex(stored: 3, surface: "お", in: []) == 3)
    }

    @Test("tap re-anchor breaks duplicate-surface ties on the first occurrence")
    func reAnchoredTapIndexDuplicateSurfaces() {
        let segments: [LookupSegment]? = [
            LookupSegment(surface: "お"), LookupSegment(surface: "お", lemma: "尾")
        ]

        #expect(LookupDisplay.reAnchoredTapIndex(
            stored: 9, surface: "お", in: segments
        ) == 0)
    }

    @Test("an also-pill promotion fully re-selects and the row recomputes")
    func promoteAlsoPillRecomputesRow() async throws {
        let content = try await harness.shownContent(for: harness.requestO())
        let choice = try #require(content.fallbackResults.first)

        let promoted = harness.makeDisplay().promote(choice, in: content, favorites: [])

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
        let favorites = Set([FavoriteWord.normalize("見る")])

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

        let promoted = display.promote(foreign, in: content, favorites: [])

        #expect(promoted == content)
    }

    @Test("re-promoting the display preserves its join origin")
    func promoteSameDisplayPreservesOrigin() {
        let display = harness.makeDisplay()
        let joined = harness.result(["お土産"])
        let content = LookupContent.found(
            result: joined, also: [harness.result(["お"])], origin: .join
        )

        let promoted = display.promote(joined, in: content, favorites: [])

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
        let moved = display.promote(single, in: start, favorites: [])
        let back = display.promote(joined, in: moved, favorites: [])
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
