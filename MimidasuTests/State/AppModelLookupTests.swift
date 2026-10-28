import Foundation
@testable import Mimidasu
import Observation
import Synchronization
import Testing

/// Host wiring for dictionary taps on `AppModel`: the request forwarder, the
/// one presentation both hosts read, popover anchor exclusivity and dismissal,
/// fallback and pager forwarding, and session clear. The lookup lifecycle
/// itself — dispatch, staleness, effect routing, fallback promotion, and
/// paging — belongs to `TapLookupSessionTests`; verdicts stay behind
/// `LookupDisplay`.
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
        makeIdleModel(
            suite: "test.AppModelLookup",
            jmDictLookup: jmDictLookup ?? JMDictLookup(resolveDatabase: { [fixture] in fixture.url })
        )
    }

    /// お in お土産: the tapped surface お leads, then the forward joins
    /// お土産 and the lemma 土産 — all three hit in the fixture.
    private func lookupO() -> [LookupSegment] {
        [LookupSegment(surface: "お"), LookupSegment(surface: "土産", lemma: "土産")]
    }

    private func request(
        segments: [LookupSegment]?, tappedAt: Int = 0,
        sentenceText: String, surface: String
    ) -> TapLookupRequest {
        TapLookupRequest(
            segments: segments, tappedAt: tappedAt,
            sentenceText: sentenceText, surface: surface
        )
    }

    private func tapHit(_ model: AppModel, anchor: LookupAnchor) async {
        await model.handleLookupTap(
            request(segments: lookupO(), sentenceText: "お土産", surface: "お"),
            anchor: anchor
        ).value
    }

    private func entry(keb: String, reb: String, seq: Int) -> JMDictEntry {
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

    // MARK: - Tap entry point

    @Test("a request with injected segments lands the miss pill without the tokenizer")
    func injectedSegmentsLandMissPill() async {
        let model = makeModel()

        await model.handleLookupTap(
            request(
                segments: [LookupSegment(surface: "xyz")],
                sentenceText: "xyz", surface: "xyz"
            ),
            anchor: .transcript(sentenceIndex: 0, tokenIndex: 0)
        ).value

        #expect(model.notices.message == "No dictionary entry for \"xyz\"")
        #expect(model.notices.tone == .warning)
        #expect(model.lookupPresentation == nil)
    }

    @Test(
        "a lookup selection carries its anchor, matched headword, and debug id",
        arguments: [
            LookupAnchor.transcript(sentenceIndex: 0, tokenIndex: 0),
            LookupAnchor.liveStrip
        ]
    )
    func lookupCarriesAnchorAndMatch(anchor: LookupAnchor) async throws {
        let model = makeModel()

        await model.handleLookupTap(
            request(segments: lookupO(), sentenceText: "お土産", surface: "お"),
            anchor: anchor
        ).value

        let presentation = try #require(model.lookupPresentation)
        #expect(presentation.anchor == anchor)
        #expect(presentation.content.displayResult?.matched == "お")
        #expect(
            presentation.id.hasSuffix("-お"),
            "the identity format joins the anchor and the matched token"
        )
    }

    @Test("sequential taps land in order")
    func sequentialTapsLandInOrder() async throws {
        let model = makeModel()
        await model.handleLookupTap(
            request(segments: lookupO(), sentenceText: "お土産", surface: "お"),
            anchor: .liveStrip
        ).value
        await model.handleLookupTap(
            request(
                segments: [LookupSegment(surface: "あめ")],
                sentenceText: "あめ", surface: "あめ"
            ),
            anchor: .liveStrip
        ).value

        let presentation = try #require(model.lookupPresentation)
        #expect(presentation.content.displayResult?.matched == "あめ")
    }

    @Test("nil segments warn while empty segments fault, with no cross-talk")
    func nilVersusEmptySegmentsRouting() async throws {
        // Nil segments warn with the tapped surface — host routing, no tokenizer gate.
        let warned = makeModel()
        await warned.handleLookupTap(
            request(segments: nil, sentenceText: "お土産", surface: "お"),
            anchor: .liveStrip
        ).value

        #expect(warned.notices.message == "No dictionary entry for \"お\"")
        #expect(warned.notices.tone == .warning)
        #expect(warned.toasts.toasts.isEmpty, "a miss never toasts")
        #expect(warned.lookupPresentation == nil)

        // Empty segments fault as annotator-unavailable — a toast, never the pill.
        let faulted = makeModel()
        await faulted.handleLookupTap(
            request(segments: [], sentenceText: "お土産", surface: "お"),
            anchor: .liveStrip
        ).value

        let toast = try #require(faulted.toasts.toasts.first)
        #expect(toast.key == ToastKey.dictionaryLookup)
        #expect(toast.style == .yellowAuto)
        #expect(toast.title == "Dictionary lookup failed")
        #expect(toast.body == DictionaryError.annotatorUnavailable.localizedDescription)
        #expect(faulted.notices.message == nil, "a fault never posts the pill")
        #expect(faulted.lookupPresentation == nil)
    }

    @Test("an unfavorited lookup still leads with the entry the dictionary ranked first")
    func unfavoritedLookupKeepsItsRanking() async throws {
        let model = makeModel()
        await model.handleLookupTap(
            request(
                segments: [LookupSegment(surface: "あめ")],
                sentenceText: "あめ", surface: "あめ"
            ),
            anchor: .transcript(sentenceIndex: 0, tokenIndex: 0)
        ).value

        let leading = try #require(model.lookupPresentation?.content.displayResult?.entries.first)
        #expect(leading.keb == "飴")
    }

    // MARK: - Popover anchor exclusivity

    @Test("only the surface whose anchor matches presents the popover")
    func popoverAnchorExclusivity() async throws {
        let model = makeModel()
        let anchor = LookupAnchor.transcript(sentenceIndex: 3, tokenIndex: 1)

        await tapHit(model, anchor: anchor)

        let presentation = try #require(model.lookupPresentation)
        #expect(presentation.popoverItem(for: anchor) == presentation)
        // A different word on the same row is a different anchor…
        #expect(
            presentation.popoverItem(for: .transcript(sentenceIndex: 3, tokenIndex: 2)) == nil
        )
        // …as is the same word on a different row, and the strip.
        #expect(
            presentation.popoverItem(for: .transcript(sentenceIndex: 4, tokenIndex: 1)) == nil
        )
        #expect(presentation.popoverItem(for: .liveStrip) == nil)
    }

    @Test("a second tap moves the selection to the new surface")
    func secondTapMovesPopover() async {
        let model = makeModel()

        await tapHit(model, anchor: .transcript(sentenceIndex: 1, tokenIndex: 0))
        let transcriptID = model.lookupPresentation?.id
        await tapHit(model, anchor: .liveStrip)

        #expect(model.lookupPresentation?.anchor == .liveStrip)
        #expect(model.lookupPresentation?.id != transcriptID, "the anchor is part of the identity")
    }

    @Test("a second tap on the same word swaps the content while the anchor stays")
    func secondTapSameWordSwapsContent() async {
        let model = makeModel()
        let anchor = LookupAnchor.transcript(sentenceIndex: 1, tokenIndex: 2)

        await tapHit(model, anchor: anchor)
        await model.handleLookupTap(
            request(
                segments: [LookupSegment(surface: "あめ")],
                sentenceText: "あめ", surface: "あめ"
            ),
            anchor: anchor
        ).value

        #expect(model.lookupPresentation?.anchor == anchor)
        #expect(model.lookupPresentation?.content.displayResult?.matched == "あめ")
    }

    @Test("a second tap on a different word of the same row moves the anchor")
    func secondTapSameRowDifferentWordMovesAnchor() async {
        let model = makeModel()

        await tapHit(model, anchor: .transcript(sentenceIndex: 1, tokenIndex: 2))
        await model.handleLookupTap(
            request(
                segments: [LookupSegment(surface: "あめ")],
                sentenceText: "あめ", surface: "あめ"
            ),
            anchor: .transcript(sentenceIndex: 1, tokenIndex: 5)
        ).value

        #expect(model.lookupPresentation?.anchor == .transcript(sentenceIndex: 1, tokenIndex: 5))
        #expect(model.lookupPresentation?.content.displayResult?.matched == "あめ")
    }

    @Test("dismissal clears the anchor only when the dismissing surface owns it; pinned persists")
    func dismissClearsSelectionOnly() async throws {
        let model = makeModel()
        await model.handleLookupTap(
            request(
                segments: [LookupSegment(surface: "あめ")],
                sentenceText: "あめ", surface: "あめ"
            ),
            anchor: .liveStrip
        ).value
        model.stepLookupEntry(to: 1)
        let pinned = try #require(model.lookupPresentation)
        #expect(pinned.entryIndex == 1)

        // A stale transcript-row binding (virtualized-off anchor) cannot
        // clobber the live strip's selection…
        model.dismissLookupPopover(from: .transcript(sentenceIndex: 7, tokenIndex: 0))
        #expect(model.lookupPresentation?.anchor == .liveStrip)

        // …the strip's own dismiss clears it, and the pinned content and
        // entry stay.
        model.dismissLookupPopover(from: .liveStrip)
        #expect(model.lookupPresentation?.anchor == nil)
        #expect(model.lookupPresentation?.content == pinned.content)
        #expect(model.lookupPresentation?.entryIndex == pinned.entryIndex)
        #expect(model.lookupPresentation?.popoverItem(for: .liveStrip) == nil)
    }

    // MARK: - Fallback pills

    @Test("the model forwards a fallback pill selection to the session")
    func forwardsFallbackSelection() async throws {
        let model = makeModel()

        await tapHit(model, anchor: .liveStrip)
        let fallback = try #require(model.lookupPresentation?.content.fallbackResults.first)

        model.selectAlsoPill(fallback)

        #expect(model.lookupPresentation?.content.displayResult == fallback)
        #expect(model.lookupPresentation?.entryIndex == 0)
        #expect(model.lookupPresentation?.anchor == .liveStrip)
    }

    @Test("reading lookupPresentation registers the session observation")
    func presentationReadIsObserved() async {
        let model = makeModel()
        let changes = Mutex(0)
        withObservationTracking {
            _ = model.lookupPresentation
        } onChange: {
            changes.withLock { count in count += 1 }
        }

        await tapHit(model, anchor: .liveStrip)

        #expect(changes.withLock { count in count } == 1)
    }

    // MARK: - Lifecycle

    @Test("session begin clears the popover and the pinned card")
    func sessionClearResets() async {
        let model = makeModel()
        await tapHit(model, anchor: .liveStrip)

        model.sessionController.onSessionBegin?()

        #expect(model.lookupPresentation == nil)
    }

    // MARK: - Favorites probe

    @Test("the pill star probe reads the promoted lead entry")
    func pillStarProbeReadsLead() {
        let model = makeModel()
        model.favorites.add(
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
    }
}
