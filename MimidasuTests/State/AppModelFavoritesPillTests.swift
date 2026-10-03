import Foundation
@testable import Mimidasu
import Testing

/// Tests the favorites-pill behavior on `AppModel`'s lookup state: a
/// favorited also-pill reads starred through the model probe and re-selecting
/// it opens on its lead, a related-pill tap promotes the content it rebuilds
/// — the pager leads the favorite and sibling pills re-promote — while the
/// not-found content is never built promoted. The pipeline test runs over the
/// committed JMDict fixture database; the promotion test injects hand-built
/// results, because the fixture's multi-entry hits are either display results
/// (あめ) or same-headword homographs (例子/雨村), so a fallback-pill promotion
/// relabel is unobservable there.
@MainActor
@Suite("AppModel favorites pills")
final class AppModelFavoritesPillTests {

    private let fixture: JMDictFixtureDatabase.Built

    init() throws {
        fixture = try JMDictFixtureDatabase.build()
    }

    deinit {
        fixture.remove()
    }

    // MARK: - Fixtures

    private func makeModel(jmDictLookup: JMDictLookup? = nil) -> AppModel {
        AppModel(
            translationSettings: isolatedTranslationSettings(suite: "test.AppModelFavoritesPills"),
            asrModelSettings: isolatedASRModelSettings(suite: "test.AppModelFavoritesPills"),
            favorites: isolatedFavorites(),
            highFidelityProbe: { _ in false },
            jmDictLookup: jmDictLookup ?? JMDictLookup(resolveDatabase: { [fixture] in fixture.url }),
            initialModelResolve: { _ in nil }
        )
    }

    /// お in お土産: the tapped surface お leads, then the forward joins
    /// お土産 and the lemma 土産 — all three hit in the fixture.
    private func lookupO() -> [LookupSegment] {
        [LookupSegment(surface: "お"), LookupSegment(surface: "土産", lemma: "土産")]
    }

    private func entry(_ headword: String, seq: Int) -> JMDictEntry {
        JMDictEntry(
            entSeq: seq,
            keb: headword,
            reb: headword,
            common: false,
            jlpt: nil,
            hatsuon: nil,
            accPatts: nil,
            zoPatts: nil,
            senses: [JMDictSense(pos: nil, glosses: ["gloss"], misc: nil,
                                 restrictedKanji: nil, restrictedKana: nil)]
        )
    }

    /// A hand-built fallback hit: one entry per headword, dictionary-ranked
    /// as given (the fixture's multi-entry hits never relabel a fallback
    /// pill — they are display results or same-headword homographs).
    private func result(_ headwords: [String]) -> LookupResult {
        LookupResult(
            matched: headwords[0],
            entries: headwords.enumerated().map { index, headword in
                entry(headword, seq: index + 1)
            }
        )
    }

    // MARK: - "also:" pills

    @Test("a favorited also-pill reads starred, and selecting it opens on it")
    func favoritedAlsoPillReadsStarredAndReselectOpensOnIt() async throws {
        let model = makeModel()
        model.favorites.toggle(
            FavoriteWord(headword: "お土産", reading: "おみやげ", romaji: "omiyage", addedAt: 1)
        )
        await model.runLookup(
            segments: lookupO(), tappedAt: 0, sentenceText: "お土産",
            surface: "お", source: .liveStrip
        )

        // The fixture's お土産 resolves single-entry, so this pins the
        // pipeline wiring — the starred probe on a tapped pill and the
        // re-select opening at entry 0; the multi-entry reorder itself is
        // pinned by the promotion unit suite and the related-pill tap test
        // below.
        let pill = try #require(model.pinnedLookup?.content.fallbackResults.first)
        #expect(pill.matched == "お土産")
        #expect(pill.entries.first?.keb == "お土産")
        #expect(model.isFavoriteLead(pill), "the pill's lead entry is the favorite")

        model.selectAlsoPill(pill)
        #expect(model.selectedLookup?.entryIndex == 0)
        #expect(model.selectedLookup?.content.displayResult?.entries.first?.keb == "お土産")
    }

    @Test("a related-pill tap promotes: the pager leads the favorite and sibling pills re-promote")
    func relatedPillTapPromotes() throws {
        let model = makeModel()
        model.favorites.toggle(
            FavoriteWord(headword: "見る", reading: "みる", romaji: "miru", addedAt: 1)
        )
        // A not-found pin never promotes (a split hit must not present
        // itself as the tapped word), so its related results arrive
        // dictionary-ranked — the favorite sits second in both.
        let tapped = result(["雨", "見る"])
        let sibling = result(["尾", "見る"])
        let content = LookupContent.notFound(surface: "雨尾", related: [tapped, sibling])
        model.pinnedLookup = PinnedLookup(content: content, entryIndex: 0)
        // The popover is up over the pin, like a real related-pill tap.
        model.selectedLookup = SelectedLookup(
            content: content, source: .liveStrip, entryIndex: 0
        )

        model.selectAlsoPill(tapped)

        let pinned = try #require(model.pinnedLookup)
        guard case let .found(display, also, origin) = pinned.content else {
            Issue.record("the related selection stopped being found")
            return
        }
        #expect(origin == .tappedSurface, "an explicitly chosen hit is never a fallback lead")
        #expect(display.entries.map { entry in entry.keb } == ["見る", "雨"])
        #expect(model.isFavoriteLead(display), "the tapped pill's pager leads the favorite")
        #expect(also.map(\.matched) == ["尾"], "the sibling pill survives the re-selection")
        let promotedSibling = try #require(also.first)
        #expect(promotedSibling.entries.first?.keb == "見る", "the sibling pill re-promotes too")
        #expect(model.selectedLookup?.content.displayResult?.entries.first?.keb == "見る")
        #expect(model.selectedLookup?.entryIndex == 0)
        #expect(model.selectedLookup?.source == .liveStrip, "the anchor follows the re-select")
    }
}
