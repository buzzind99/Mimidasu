import Foundation
@testable import Mimidasu
import Observation
import Synchronization
import Testing

/// Host wiring for dictionary taps on `AppModel`: the request forwarder, the
/// content-only presentation, the separately owned popover anchor, fallback
/// and pager forwarding, and session clear. The lookup lifecycle itself —
/// dispatch, staleness, effect routing, fallback promotion, and paging —
/// belongs to `TapLookupSessionTests`; verdicts stay behind `LookupDisplay`.
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
        "a tap forwards its anchor and lands the matched headword with a content id",
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
        #expect(model.lookupAnchor == anchor)
        #expect(presentation.content.displayResult?.matched == "お")
        #expect(presentation.id == "お", "the identity is the matched content alone")
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
        #expect(model.lookupAnchor == anchor)
        #expect(model.lookupPopoverItem(for: anchor) == presentation)
        // A different word on the same row is a different anchor…
        #expect(
            model.lookupPopoverItem(for: .transcript(sentenceIndex: 3, tokenIndex: 2)) == nil
        )
        // …as is the same word on a different row, and the strip.
        #expect(
            model.lookupPopoverItem(for: .transcript(sentenceIndex: 4, tokenIndex: 1)) == nil
        )
        #expect(model.lookupPopoverItem(for: .liveStrip) == nil)
    }

    @Test("a second tap moves the anchor while the presentation identity stays content-only")
    func secondTapMovesAnchor() async {
        let model = makeModel()
        let word = LookupAnchor.transcript(sentenceIndex: 1, tokenIndex: 0)

        await tapHit(model, anchor: word)
        let contentID = model.lookupPresentation?.id

        await tapHit(model, anchor: .liveStrip)

        #expect(model.lookupAnchor == .liveStrip)
        #expect(model.lookupPresentation?.id == contentID, "the anchor is not part of the identity")
        #expect(model.lookupPopoverItem(for: .liveStrip) == model.lookupPresentation)
        #expect(model.lookupPopoverItem(for: word) == nil)
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

        #expect(model.lookupAnchor == anchor)
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

        #expect(model.lookupAnchor == .transcript(sentenceIndex: 1, tokenIndex: 5))
        #expect(model.lookupPresentation?.content.displayResult?.matched == "あめ")
    }

    @Test("the model forwards the session anchor after a tap")
    func lookupAnchorForwardsAfterTap() async {
        let model = makeModel()
        let word = LookupAnchor.transcript(sentenceIndex: 6, tokenIndex: 2)

        #expect(model.lookupAnchor == nil)

        await tapHit(model, anchor: word)

        #expect(model.lookupAnchor == word)
        #expect(model.lookupPopoverItem(for: word) == model.lookupPresentation)
        #expect(model.lookupPresentation?.id == "お")
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
        #expect(model.lookupAnchor == .liveStrip)

        // …the strip's own dismiss clears it, and the pinned content and
        // entry stay.
        model.dismissLookupPopover(from: .liveStrip)
        #expect(model.lookupAnchor == nil)
        #expect(
            model.lookupPresentation == pinned,
            "dismissal leaves the pinned presentation intact"
        )
        #expect(model.lookupPopoverItem(for: .liveStrip) == nil)
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
        #expect(model.lookupAnchor == .liveStrip)
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
        #expect(model.lookupAnchor == .liveStrip)

        model.sessionController.onSessionBegin?()

        #expect(model.lookupPresentation == nil)
        #expect(model.lookupAnchor == nil)
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

/// Observation forwarding across the two lookup surfaces: a tap touches both,
/// while a pager step and a fallback promotion touch the presentation alone.
/// `withObservationTracking` is one-shot, so each property gets a fresh
/// registration and the test triggers exactly one mutation.
extension AppModelLookupTests {

    @Test("a tap notifies both the presentation and the anchor observers")
    func tapNotifiesPresentationAndAnchor() async {
        let model = makeModel()
        let presentationChanges = Mutex(0)
        withObservationTracking {
            _ = model.lookupPresentation
        } onChange: {
            presentationChanges.withLock { count in count += 1 }
        }
        let anchorChanges = Mutex(0)
        withObservationTracking {
            _ = model.lookupAnchor
        } onChange: {
            anchorChanges.withLock { count in count += 1 }
        }

        await tapHit(model, anchor: .liveStrip)

        #expect(presentationChanges.withLock { count in count } == 1)
        #expect(anchorChanges.withLock { count in count } == 1)
    }

    @Test("a pager step notifies the presentation but not the anchor")
    func pagerStepLeavesAnchorUnobserved() async {
        let model = makeModel()
        let anchor = LookupAnchor.transcript(sentenceIndex: 1, tokenIndex: 2)
        await model.handleLookupTap(
            request(
                segments: [LookupSegment(surface: "あめ")],
                sentenceText: "あめ", surface: "あめ"
            ),
            anchor: anchor
        ).value
        let presentationChanges = Mutex(0)
        withObservationTracking {
            _ = model.lookupPresentation
        } onChange: {
            presentationChanges.withLock { count in count += 1 }
        }
        let anchorChanges = Mutex(0)
        withObservationTracking {
            _ = model.lookupAnchor
        } onChange: {
            anchorChanges.withLock { count in count += 1 }
        }

        model.stepLookupEntry(to: 1)

        #expect(model.lookupPresentation?.entryIndex == 1, "the step moved the page")
        #expect(presentationChanges.withLock { count in count } == 1)
        #expect(anchorChanges.withLock { count in count } == 0)
    }

    @Test("a same-anchor retap notifies the presentation but not the anchor")
    func sameAnchorRetapLeavesAnchorUnobserved() async {
        let model = makeModel()
        let anchor = LookupAnchor.transcript(sentenceIndex: 1, tokenIndex: 2)
        await tapHit(model, anchor: anchor)
        let presentationChanges = Mutex(0)
        withObservationTracking {
            _ = model.lookupPresentation
        } onChange: {
            presentationChanges.withLock { count in count += 1 }
        }
        let anchorChanges = Mutex(0)
        withObservationTracking {
            _ = model.lookupAnchor
        } onChange: {
            anchorChanges.withLock { count in count += 1 }
        }

        await model.handleLookupTap(
            request(
                segments: [LookupSegment(surface: "あめ")],
                sentenceText: "あめ", surface: "あめ"
            ),
            anchor: anchor
        ).value

        #expect(model.lookupPresentation?.content.displayResult?.matched == "あめ")
        #expect(presentationChanges.withLock { count in count } == 1)
        #expect(
            anchorChanges.withLock { count in count } == 0,
            "an unchanged anchor is not written again"
        )
    }

    @Test("the popover binding observes the anchor, not the presentation")
    func popoverBindingReadsTheAnchorOnly() async {
        let model = makeModel()
        let anchor = LookupAnchor.transcript(sentenceIndex: 2, tokenIndex: 1)
        await tapHit(model, anchor: anchor)

        let changes = Mutex(0)
        withObservationTracking {
            _ = model.lookupPopoverBinding(for: anchor).wrappedValue
        } onChange: {
            changes.withLock { count in count += 1 }
        }

        model.stepLookupEntry(to: 1)

        #expect(
            changes.withLock { count in count } == 0,
            "a pager step must not touch the binding"
        )

        model.dismissLookupPopover(from: anchor)

        #expect(
            changes.withLock { count in count } == 1,
            "dismissal moves the anchor the binding reads"
        )
    }

    @Test("a fallback promotion notifies the presentation but not the anchor")
    func fallbackPromotionLeavesAnchorUnobserved() async throws {
        let model = makeModel()
        await tapHit(model, anchor: .liveStrip)
        let fallback = try #require(model.lookupPresentation?.content.fallbackResults.first)
        let presentationChanges = Mutex(0)
        withObservationTracking {
            _ = model.lookupPresentation
        } onChange: {
            presentationChanges.withLock { count in count += 1 }
        }
        let anchorChanges = Mutex(0)
        withObservationTracking {
            _ = model.lookupAnchor
        } onChange: {
            anchorChanges.withLock { count in count += 1 }
        }

        model.selectAlsoPill(fallback)

        #expect(presentationChanges.withLock { count in count } == 1)
        #expect(anchorChanges.withLock { count in count } == 0)
    }
}
