import Foundation
@testable import Mimidasu
import Testing

/// Effect routing on `AppModel`: a show pins + selects, a no-hit posts the
/// amber pill and leaves state, a fault posts the dictionary-lookup toast
/// and never the pill, a cancellation applies nothing, and a stale
/// generation drops every effect. Most effects are canned values with no
/// database and no annotator, while the stale-generation drops and the
/// starred also-pill run over the fixture database — these tests prove the
/// routing, while `LookupDisplayTests` proves the verdicts.
@MainActor
@Suite("AppModel lookup effect routing")
final class AppModelLookupEffectTests {

    private let fixture: JMDictFixtureDatabase.Built

    init() throws {
        fixture = try JMDictFixtureDatabase.build()
    }

    deinit {
        fixture.remove()
    }

    // MARK: - Fixtures

    private func makeModel() -> AppModel {
        AppModel(
            translationSettings: isolatedTranslationSettings(suite: "test.AppModelLookupEffects"),
            asrModelSettings: isolatedASRModelSettings(suite: "test.AppModelLookupEffects"),
            favorites: isolatedFavorites(),
            highFidelityProbe: { _ in false },
            jmDictLookup: JMDictLookup(resolveDatabase: { [fixture] in fixture.url }),
            initialModelResolve: { _ in nil }
        )
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
            senses: [JMDictSense(
                pos: nil, glosses: ["gloss"], misc: nil,
                restrictedKanji: nil, restrictedKana: nil
            )]
        )
    }

    /// A hand-built entry whose writing and reading differ, so a test can tie
    /// an entry to the matched text through its reading alone.
    private func entry(keb: String?, reb: String?, seq: Int) -> JMDictEntry {
        JMDictEntry(
            entSeq: seq,
            keb: keb,
            reb: reb,
            common: false,
            jlpt: nil,
            hatsuon: nil,
            accPatts: nil,
            zoPatts: nil,
            senses: [JMDictSense(
                pos: nil, glosses: ["gloss"], misc: nil,
                restrictedKanji: nil, restrictedKana: nil
            )]
        )
    }

    /// A hand-built lookup hit: one entry per headword, ranked as given.
    private func result(_ headwords: [String]) -> LookupResult {
        LookupResult(
            matched: headwords[0],
            entries: headwords.enumerated().map { index, headword in
                entry(headword, seq: index + 1)
            }
        )
    }

    // MARK: - Effect routing

    @Test("a show effect selects the popover and pins the card at the effect entry")
    func showEffectPinsAndSelects() throws {
        let model = makeModel()
        let content = LookupContent.found(
            result: result(["お"]), also: [result(["お土産"])], origin: .tappedSurface
        )

        model.applyEffect(.show(content: content, entryIndex: 0), source: .liveStrip)

        let selected = try #require(model.selectedLookup)
        #expect(selected.source == .liveStrip)
        #expect(selected.content == content)
        #expect(selected.entryIndex == 0)
        let pinned = try #require(model.pinnedLookup)
        #expect(pinned.content == content)
        #expect(pinned.entryIndex == 0)
    }

    @Test("a no-hit effect posts the warning pill and leaves state untouched")
    func warnNoHitPostsPillAndLeavesState() throws {
        let model = makeModel()
        let content = LookupContent.found(
            result: result(["お"]), also: [], origin: .tappedSurface
        )
        model.applyEffect(.show(content: content, entryIndex: 0), source: .liveStrip)
        let pinnedBefore = try #require(model.pinnedLookup)

        model.applyEffect(.warnNoHit(surface: "無語"), source: .liveStrip)

        #expect(model.notices.message == "No dictionary entry for \"無語\"")
        #expect(model.notices.tone == .warning)
        #expect(model.selectedLookup?.content == content, "the popover stays up")
        #expect(model.pinnedLookup == pinnedBefore)
    }

    @Test("a fault effect posts the dictionaryLookup toast and never the pill")
    func faultPostsToastNeverPill() throws {
        let model = makeModel()

        model.applyEffect(.fault(.databaseMissing), source: .liveStrip)

        let toast = try #require(model.toasts.toasts.first)
        #expect(toast.key == ToastKey.dictionaryLookup)
        #expect(toast.style == .yellowAuto)
        #expect(toast.title == "Dictionary lookup failed")
        #expect(toast.body == TapLookupFault.databaseMissing.localizedDescription)
        #expect(model.selectedLookup == nil, "no popover on error")
        #expect(model.pinnedLookup == nil, "pinned unchanged")
        #expect(model.notices.message == nil, "the pill is reserved for no-hit")
    }

    @Test("a cancelled effect applies nothing: no pin, no pill, no toast")
    func cancelledAppliesNothing() throws {
        let model = makeModel()
        let content = LookupContent.found(
            result: result(["お"]), also: [], origin: .tappedSurface
        )
        model.applyEffect(.show(content: content, entryIndex: 0), source: .liveStrip)
        let pinnedBefore = try #require(model.pinnedLookup)

        model.applyEffect(.cancelled, source: .liveStrip)

        #expect(model.toasts.toasts.isEmpty, "cancellation never toasts")
        #expect(model.notices.message == nil, "cancellation never pills")
        #expect(model.selectedLookup?.content == content, "the popover stays up")
        #expect(model.pinnedLookup == pinnedBefore)
    }

    // MARK: - Stale-generation drops

    @Test("a stale show lands nothing")
    func staleShowDropped() async {
        let model = makeModel()

        await model.runLookup(
            segments: [LookupSegment(surface: "お")], tappedAt: 0,
            sentenceText: "お", surface: "お",
            source: .liveStrip, generation: -999
        )

        #expect(model.selectedLookup == nil)
        #expect(model.pinnedLookup == nil)
    }

    @Test("a stale no-hit posts no pill and leaves state untouched")
    func staleWarnDropped() async throws {
        let model = makeModel()
        let content = LookupContent.found(
            result: result(["お"]), also: [], origin: .tappedSurface
        )
        model.applyEffect(.show(content: content, entryIndex: 0), source: .liveStrip)
        let pinnedBefore = try #require(model.pinnedLookup)

        await model.runLookup(
            segments: [LookupSegment(surface: "無語")], tappedAt: 0,
            sentenceText: "無語", surface: "無語",
            source: .liveStrip, generation: -999
        )

        #expect(model.notices.message == nil)
        #expect(model.selectedLookup?.content == content)
        #expect(model.pinnedLookup == pinnedBefore)
    }

    @Test("a stale fault posts no toast")
    func staleFaultDropped() async {
        let model = makeModel()

        await model.runLookup(
            segments: [], tappedAt: 0, sentenceText: "お土産",
            surface: "お", source: .liveStrip, generation: -999
        )

        #expect(model.toasts.toasts.isEmpty)
    }

    // MARK: - Pager and pills over canned content

    @Test("the pager steps popover and pinned card together")
    func pagerStepsBoth() {
        let model = makeModel()
        let content = LookupContent.found(
            result: result(["飴", "雨"]), also: [], origin: .tappedSurface
        )
        model.applyEffect(.show(content: content, entryIndex: 0), source: .liveStrip)

        model.stepLookupEntry(to: 1)

        #expect(model.selectedLookup?.entryIndex == 1)
        #expect(model.pinnedLookup?.entryIndex == 1)
    }

    @Test("the pager clamps past the last entry")
    func pagerClampsPastEnd() {
        let model = makeModel()
        let content = LookupContent.found(
            result: result(["飴", "雨"]), also: [], origin: .tappedSurface
        )
        model.applyEffect(.show(content: content, entryIndex: 0), source: .liveStrip)

        model.stepLookupEntry(to: 99)

        #expect(model.selectedLookup?.entryIndex == 1, "clamped to the last entry")
        #expect(model.pinnedLookup?.entryIndex == 1, "clamped to the last entry")
    }

    @Test("the pager clamps before the first entry")
    func pagerClampsBeforeStart() {
        let model = makeModel()
        let content = LookupContent.found(
            result: result(["飴", "雨"]), also: [], origin: .tappedSurface
        )
        model.applyEffect(.show(content: content, entryIndex: 0), source: .liveStrip)

        model.stepLookupEntry(to: -5)

        #expect(model.selectedLookup?.entryIndex == 0, "clamped to the first entry")
        #expect(model.pinnedLookup?.entryIndex == 0, "clamped to the first entry")
    }

    @Test("the pager is inert over not-found content")
    func pagerInertOnNotFound() throws {
        let model = makeModel()
        let content = LookupContent.notFound(surface: "雨尾", related: [result(["雨"])])
        model.applyEffect(.show(content: content, entryIndex: 0), source: .liveStrip)
        let selectedBefore = try #require(model.selectedLookup)
        let pinnedBefore = try #require(model.pinnedLookup)

        model.stepLookupEntry(to: 1)

        #expect(model.selectedLookup?.entryIndex == selectedBefore.entryIndex)
        #expect(model.pinnedLookup?.entryIndex == pinnedBefore.entryIndex)
    }

    @Test("an also-pill tap fully re-selects: popover and pinned update, the row recomputes")
    func alsoPillReselects() throws {
        let model = makeModel()
        let content = LookupContent.found(
            result: result(["お"]), also: [result(["お土産"])], origin: .tappedSurface
        )
        model.applyEffect(.show(content: content, entryIndex: 0), source: .liveStrip)

        let expansion = try #require(model.pinnedLookup?.content.fallbackResults.first)
        model.selectAlsoPill(expansion)

        #expect(model.selectedLookup?.content.displayResult?.matched == "お土産")
        #expect(model.selectedLookup?.source == .liveStrip, "the anchor follows the re-select")
        #expect(model.selectedLookup?.entryIndex == 0)
        let pinned = try #require(model.pinnedLookup)
        #expect(pinned.content.displayResult?.matched == "お土産")
        #expect(pinned.content.fallbackResults.map(\.matched) == ["お"])
    }

    @Test("an also-pill tap with no pin is a no-op")
    func alsoPillWithoutPinNoOp() {
        let model = makeModel()

        model.selectAlsoPill(result(["お"]))

        #expect(model.selectedLookup == nil)
        #expect(model.pinnedLookup == nil)
    }

    @Test("an also-pill tap for a foreign result keeps the pinned content")
    func alsoPillForeignChoiceFailClosed() {
        let model = makeModel()
        let content = LookupContent.found(
            result: result(["お", "土産"]), also: [result(["お土産"])], origin: .tappedSurface
        )
        model.applyEffect(.show(content: content, entryIndex: 0), source: .liveStrip)
        model.stepLookupEntry(to: 1)

        // promote() fails closed on a result the tap never resolved.
        model.selectAlsoPill(result(["飴"]))

        #expect(model.pinnedLookup?.content == content)
        #expect(model.selectedLookup?.content == content)
        #expect(model.pinnedLookup?.entryIndex == 1, "a failed pill keeps the pager")
        #expect(model.selectedLookup?.entryIndex == 1, "a failed pill keeps the pager")
    }

    @Test("a starred also-pill opens on the starred word over the real fixture")
    func starredAlsoPillOpensOnStarredWord() async throws {
        let model = makeModel()
        model.favorites.toggle(
            FavoriteWord(headword: "お土産", reading: "おみやげ", romaji: "omiyage", addedAt: 1)
        )

        // Tap お leads with お itself; お土産 rides as an "also:" fallback.
        await model.runLookup(
            segments: [LookupSegment(surface: "お"), LookupSegment(surface: "土産", lemma: "土産")],
            tappedAt: 0, sentenceText: "お土産", surface: "お", source: .liveStrip
        )
        #expect(model.selectedLookup?.content.displayResult?.matched == "お")
        let fallbacks = model.pinnedLookup?.content.fallbackResults ?? []
        let also = try #require(fallbacks.first(where: { fallback in fallback.matched == "お土産" }))

        model.selectAlsoPill(also)

        let display = try #require(model.selectedLookup?.content.displayResult)
        #expect(display.matched == "お土産")
        #expect(display.entries.first?.keb == "お土産", "the single fixture entry leads")
        #expect(model.isFavoriteLead(display) == true)
        #expect(model.pinnedLookup?.content.displayResult?.matched == "お土産")
    }

    @Test("a related-pill tap promotes through the favorites snapshot")
    func relatedPillAppliesFavoritesSnapshot() throws {
        let model = makeModel()
        model.favorites.toggle(
            FavoriteWord(headword: "雨", reading: "あめ", romaji: "ame", addedAt: 1)
        )
        // Hand-built in engine order — a real pin arrives with each related
        // result already promoted — so the favorite sits second in both,
        // tied to the match through its shared あめ reading alone; the
        // re-select path's re-promotion is what moves it front.
        let tapped = LookupResult(matched: "あめ", entries: [
            entry(keb: "飴", reb: "あめ", seq: 1),
            entry(keb: "雨", reb: "あめ", seq: 2)
        ])
        let sibling = LookupResult(matched: "あめ", entries: [
            entry(keb: "別", reb: "あめ", seq: 3),
            entry(keb: "雨", reb: "あめ", seq: 4)
        ])
        let content = LookupContent.notFound(surface: "雨尾", related: [tapped, sibling])
        model.pinnedLookup = PinnedLookup(content: content, entryIndex: 0)
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
        #expect(display.entries.map { entry in entry.keb } == ["雨", "飴"])
        #expect(also.map(\.matched) == ["あめ"], "the sibling pill survives the re-selection")
        let promotedSibling = try #require(also.first)
        #expect(promotedSibling.entries.map(\.entSeq) == [4, 3], "the sibling pill re-promotes too")
        #expect(promotedSibling.entries.first?.keb == "雨")
        #expect(model.selectedLookup?.content.displayResult?.entries.first?.keb == "雨")
        #expect(model.selectedLookup?.entryIndex == 0)
        #expect(model.selectedLookup?.source == .liveStrip, "the anchor follows the re-select")
        #expect(model.isFavoriteLead(display) == true)
    }

    @Test("the pill star probe reads the promoted lead entry")
    func pillStarProbeReadsLead() throws {
        let model = makeModel()
        model.favorites.toggle(
            FavoriteWord(headword: "雨", reading: "あめ", romaji: "ame", addedAt: 1)
        )

        // Both entries share the matched あめ reading; only the lead differs.
        let unpromoted = LookupResult(matched: "あめ", entries: [
            entry(keb: "飴", reb: "あめ", seq: 1),
            entry(keb: "雨", reb: "あめ", seq: 2)
        ])
        let promoted = LookupResult(matched: "あめ", entries: [
            entry(keb: "雨", reb: "あめ", seq: 2),
            entry(keb: "飴", reb: "あめ", seq: 1)
        ])
        #expect(model.isFavoriteLead(unpromoted) == false)
        #expect(model.isFavoriteLead(promoted) == true)

        // Promotion and the probe agree: re-selecting the unpromoted display
        // moves the favorite front, and the probe flips with it.
        let content = LookupContent.found(
            result: unpromoted, also: [], origin: .tappedSurface
        )
        model.applyEffect(.show(content: content, entryIndex: 0), source: .liveStrip)
        let displayBefore = try #require(model.pinnedLookup?.content.displayResult)
        #expect(model.isFavoriteLead(displayBefore) == false)
        model.selectAlsoPill(displayBefore)
        let displayAfter = try #require(model.pinnedLookup?.content.displayResult)
        #expect(displayAfter.entries.first?.keb == "雨")
        #expect(model.isFavoriteLead(displayAfter) == true)
    }
}
