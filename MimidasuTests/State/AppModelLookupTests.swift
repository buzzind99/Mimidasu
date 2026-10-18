import Foundation
@testable import Mimidasu
import Testing

/// Thin host wiring for dictionary taps on `AppModel`: the tap entry point
/// (live annotator, raw render-time index), popover anchor exclusivity and
/// dismissal, engine-ranking preservation without favorites, and session
/// clear. Tap-to-verdict outcomes (hit-pins, join-lead, split demotion,
/// miss pill, faults, promotion, pager clamping) live behind the
/// `LookupDisplay` seam and are proven there — this suite only proves the
/// wiring around it, over the committed JMDict fixture database.
@MainActor
@Suite("AppModel dictionary lookup")
final class AppModelLookupTests {

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
            translationSettings: isolatedTranslationSettings(suite: "test.AppModelLookup"),
            asrModelSettings: isolatedASRModelSettings(suite: "test.AppModelLookup"),
            favorites: isolatedFavorites(),
            archive: isolatedArchive(),
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

    private func runHit(_ model: AppModel, source: SelectedLookup.Source) async {
        await model.runLookup(
            segments: lookupO(), tappedAt: 0, sentenceText: "お土産",
            surface: "お", source: source
        )
    }

    // MARK: - Tap entry point

    @Test(
        "live tokenizer: handleLookupTap resolves segments at tap time and lands the miss pill",
        .enabled(if: DictionaryStore.resolve() != nil)
    )
    func handleLookupTapLandsOutcome() async {
        // Live-tokenizer coverage only: the gate above skips — visibly, as a
        // skipped test rather than a silent pass — when no prepared
        // tokenizer is on disk. The deterministic routing below proves the
        // same pill without the tokenizer.
        let model = makeModel()

        // "xyz" misses the fixture whichever way the real annotator
        // resolves it — a plain run or token-derived segments — so the tap
        // deterministically ends at the warning pill. Gated on a prepared
        // tokenizer: without one the segments come back empty and the tap
        // surfaces the annotator-unavailable error instead.
        model.handleLookupTap(
            LookupToken(
                surface: "xyz", reading: nil, lemma: nil,
                tokenIndex: 0, sentenceText: "xyz"
            ),
            source: .transcript(sentenceIndex: 0, tokenIndex: 0)
        )

        // The tap's Task runs the lookup off-main; poll until it lands —
        // the wait ends as soon as the pill is observable.
        #expect(
            await pollUntil(timeout: 5) { model.notices.message != nil },
            "the tap lands the miss pill"
        )
        #expect(model.notices.message == "No dictionary entry for \"xyz\"")
        #expect(model.notices.tone == .warning)
        #expect(model.selectedLookup == nil)
    }

    @Test("runLookup with injected segments lands the miss pill without the tokenizer")
    func injectedSegmentsLandMissPill() async {
        let model = makeModel()

        await model.runLookup(
            segments: [LookupSegment(surface: "xyz")], tappedAt: 0,
            sentenceText: "xyz", surface: "xyz",
            source: .transcript(sentenceIndex: 0, tokenIndex: 0)
        )

        #expect(model.notices.message == "No dictionary entry for \"xyz\"")
        #expect(model.notices.tone == .warning)
        #expect(model.selectedLookup == nil)
    }

    @Test("lookup identity distinguishes sources and travels with the matched headword")
    func lookupIdentity() async throws {
        let model = makeModel()

        await runHit(model, source: .transcript(sentenceIndex: 0, tokenIndex: 0))
        #expect(model.selectedLookup?.source == .transcript(sentenceIndex: 0, tokenIndex: 0))
        #expect(model.selectedLookup?.content.displayResult?.matched == "お")
        let transcriptID = try #require(model.selectedLookup?.id)

        await model.runLookup(
            segments: lookupO(), tappedAt: 0, sentenceText: "お土産",
            surface: "お", source: .liveStrip
        )
        #expect(model.selectedLookup?.source == .liveStrip)
        #expect(model.selectedLookup?.content.displayResult?.matched == "お")
        let stripID = try #require(model.selectedLookup?.id)
        #expect(transcriptID != stripID)
    }

    @Test("lookup identity format joins source and token (debug-id contract)")
    func lookupIdentityFormat() async throws {
        let model = makeModel()

        await runHit(model, source: .transcript(sentenceIndex: 0, tokenIndex: 0))
        let transcriptID = try #require(model.selectedLookup?.id)

        #expect(transcriptID.hasSuffix("-お"))
    }

    @Test(
        "a lookup selection carries its source and matched headword",
        arguments: [
            SelectedLookup.Source.transcript(sentenceIndex: 0, tokenIndex: 0),
            SelectedLookup.Source.liveStrip
        ]
    )
    func lookupCarriesSourceAndMatch(source: SelectedLookup.Source) async {
        let model = makeModel()

        await model.runLookup(
            segments: lookupO(), tappedAt: 0, sentenceText: "お土産",
            surface: "お", source: source
        )

        #expect(model.selectedLookup?.source == source)
        #expect(model.selectedLookup?.content.displayResult?.matched == "お")
    }

    @Test("sequential taps land in order; each tap bumps the generation")
    func sequentialTapsLandInOrder() async throws {
        // The token is internal, so the bump reads directly; it runs on a
        // throwaway model so the tap's spawned Task never races the model below.
        let bumpModel = makeModel()
        let before = bumpModel.lookupGeneration
        bumpModel.handleLookupTap(
            LookupToken(surface: "お", reading: nil, lemma: nil, tokenIndex: 0, sentenceText: "お土産"),
            source: .liveStrip
        )
        #expect(bumpModel.lookupGeneration == before + 1)

        // Concurrent rapid taps would race detached SQLite lookups with no
        // engineered latency — flaky — so ordering lands sequentially here;
        // the stale-generation drops themselves are proven by the
        // generation-parameter drops in the effect tests. No gated-continuation
        // race is pinned here: the engine is concrete with no stub seam, so
        // none is introduced.
        let model = makeModel()
        await model.runLookup(
            segments: lookupO(), tappedAt: 0, sentenceText: "お土産", surface: "お", source: .liveStrip
        )
        await model.runLookup(
            segments: [LookupSegment(surface: "あめ")], tappedAt: 0,
            sentenceText: "あめ", surface: "あめ", source: .liveStrip
        )

        let selected = try #require(model.selectedLookup)
        #expect(selected.content.displayResult?.matched == "あめ")
    }

    @Test("nil segments warn while empty segments fault, with no cross-talk")
    func nilVersusEmptySegmentsRouting() async throws {
        // Nil segments warn with the tapped surface — host routing, no tokenizer gate.
        let warned = makeModel()
        await warned.runLookup(
            segments: nil, tappedAt: 0, sentenceText: "お土産", surface: "お", source: .liveStrip
        )

        #expect(warned.notices.message == "No dictionary entry for \"お\"")
        #expect(warned.notices.tone == .warning)
        #expect(warned.toasts.toasts.isEmpty, "a miss never toasts")
        #expect(warned.selectedLookup == nil)
        #expect(warned.pinnedLookup == nil)

        // Empty segments fault as annotator-unavailable — a toast, never the pill.
        let faulted = makeModel()
        await faulted.runLookup(
            segments: [], tappedAt: 0, sentenceText: "お土産", surface: "お", source: .liveStrip
        )

        let toast = try #require(faulted.toasts.toasts.first)
        #expect(toast.key == ToastKey.dictionaryLookup)
        #expect(toast.body == TapLookupFault.annotatorUnavailable.localizedDescription)
        #expect(faulted.notices.message == nil, "a fault never posts the pill")
        #expect(faulted.selectedLookup == nil)
        #expect(faulted.pinnedLookup == nil)
    }

    @Test("an unfavorited lookup still leads with the entry the dictionary ranked first")
    func unfavoritedLookupKeepsItsRanking() async throws {
        let model = makeModel()
        await model.runLookup(
            segments: [LookupSegment(surface: "あめ")], tappedAt: 0,
            sentenceText: "あめ", surface: "あめ",
            source: .transcript(sentenceIndex: 0, tokenIndex: 0)
        )

        let leading = try #require(model.selectedLookup?.content.displayResult?.entries.first)
        #expect(leading.keb == "飴")
    }

    // MARK: - Popover anchor exclusivity

    @Test("only the surface whose anchor matches presents the popover")
    func popoverAnchorExclusivity() async {
        let model = makeModel()

        await runHit(model, source: .transcript(sentenceIndex: 3, tokenIndex: 1))

        let selected = model.selectedLookup
        #expect(
            selected?.popoverItem(for: .transcript(sentenceIndex: 3, tokenIndex: 1)) == selected
        )
        // A different word on the same row is a different anchor…
        #expect(
            selected?.popoverItem(for: .transcript(sentenceIndex: 3, tokenIndex: 2)) == nil
        )
        // …as is the same word on a different row, and the strip.
        #expect(
            selected?.popoverItem(for: .transcript(sentenceIndex: 4, tokenIndex: 1)) == nil
        )
        #expect(selected?.popoverItem(for: .liveStrip) == nil)
    }

    @Test("a second tap moves the selection to the new surface")
    func secondTapMovesPopover() async {
        let model = makeModel()

        await runHit(model, source: .transcript(sentenceIndex: 1, tokenIndex: 0))
        await model.runLookup(
            segments: lookupO(), tappedAt: 0, sentenceText: "お土産",
            surface: "お", source: .liveStrip
        )

        #expect(model.selectedLookup?.source == .liveStrip)
    }

    @Test("a second tap on the same word swaps the content while the anchor stays")
    func secondTapSameWordSwapsContent() async {
        let model = makeModel()

        await runHit(model, source: .transcript(sentenceIndex: 1, tokenIndex: 2))
        await model.runLookup(
            segments: [LookupSegment(surface: "あめ")], tappedAt: 0,
            sentenceText: "あめ", surface: "あめ",
            source: .transcript(sentenceIndex: 1, tokenIndex: 2)
        )

        #expect(model.selectedLookup?.source == .transcript(sentenceIndex: 1, tokenIndex: 2))
        #expect(model.selectedLookup?.content.displayResult?.matched == "あめ")
    }

    @Test("a second tap on a different word of the same row moves the anchor")
    func secondTapSameRowDifferentWordMovesAnchor() async {
        let model = makeModel()

        await runHit(model, source: .transcript(sentenceIndex: 1, tokenIndex: 2))
        await model.runLookup(
            segments: [LookupSegment(surface: "あめ")], tappedAt: 0,
            sentenceText: "あめ", surface: "あめ",
            source: .transcript(sentenceIndex: 1, tokenIndex: 5)
        )

        #expect(model.selectedLookup?.source == .transcript(sentenceIndex: 1, tokenIndex: 5))
        #expect(model.selectedLookup?.content.displayResult?.matched == "あめ")
    }

    @Test("dismissal clears the selection only when the dismissing surface owns it; pinned persists")
    func dismissClearsSelectionOnly() async {
        let model = makeModel()
        await runHit(model, source: .liveStrip)
        let pinnedBefore = model.pinnedLookup

        // A stale transcript-row binding (virtualized-off anchor) cannot
        // clobber the live strip's selection…
        model.dismissLookupPopover(source: .transcript(sentenceIndex: 7, tokenIndex: 0))
        #expect(model.selectedLookup != nil)

        // …the strip's own dismiss clears it, and the pinned card stays.
        model.dismissLookupPopover(source: .liveStrip)
        #expect(model.selectedLookup == nil)
        #expect(model.pinnedLookup == pinnedBefore)
    }

    // MARK: - Lifecycle

    @Test("session clear resets the popover, the pinned card, and in-flight lookups")
    func sessionClearResets() async {
        let model = makeModel()
        await runHit(model, source: .liveStrip)

        model.sessionController.onSessionBegin?()

        #expect(model.selectedLookup == nil)
        #expect(model.pinnedLookup == nil)

        // A lookup spawned before the clear (stale generation) must not
        // resurrect state afterwards.
        await model.runLookup(
            segments: lookupO(), tappedAt: 0, sentenceText: "お土産",
            surface: "お", source: .liveStrip, generation: -999
        )
        #expect(model.selectedLookup == nil)
        #expect(model.pinnedLookup == nil)
    }
}
