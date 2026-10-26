import CoreGraphics
@testable import Mimidasu
import Testing

/// A 1000pt-tall content in a 400pt viewport: flush-bottom offset is
/// 600, flush-top is 0.
private func snapshot(
    offsetY: CGFloat = 0,
    contentHeight: CGFloat = 1000,
    containerHeight: CGFloat = 400,
    insetTop: CGFloat = 0,
    insetBottom: CGFloat = 0
) -> TranscriptScrollPin.Snapshot {
    TranscriptScrollPin.Snapshot(
        offsetY: offsetY,
        contentHeight: contentHeight,
        containerHeight: containerHeight,
        insetTop: insetTop,
        insetBottom: insetBottom
    )
}

/// Tests the pure tick→decision core of the transcript's manual bottom
/// pin: the chase on short re-anchor landings, direction-decided
/// unpin/repin, the mixed-tick deferral, growth handling under a
/// stationary offset, the jump-button visibility mapping, and the
/// mode-flip mapping for the live feed vs. a finished record.
@Suite("Transcript scroll pin")
struct TranscriptScrollPinTests {

    // MARK: - Chase while pinned

    @Test("a short re-anchor landing keeps chasing while pinned")
    func shortLandingChases() {
        let tick = TranscriptScrollPin.tick(
            old: snapshot(offsetY: 590), new: snapshot(offsetY: 596), pinned: true, mode: .live
        )

        #expect(tick.reanchors)
        #expect(tick.pinnedAfter)
    }

    @Test("a flush landing stops the chase")
    func flushLandingStops() {
        let tick = TranscriptScrollPin.tick(
            old: snapshot(offsetY: 590), new: snapshot(offsetY: 600), pinned: true, mode: .live
        )

        #expect(!tick.reanchors)
        #expect(tick.pinnedAfter)
    }

    // MARK: - Unpin / repin

    @Test("dragging up beyond the tolerance drops the pin on a still span")
    func dragUpDropsPin() {
        let tick = TranscriptScrollPin.tick(
            old: snapshot(offsetY: 600), new: snapshot(offsetY: 550), pinned: true, mode: .live
        )

        #expect(!tick.reanchors)
        #expect(!tick.pinnedAfter)
    }

    @Test("dragging up within the tolerance keeps the pin")
    func dragUpWithinToleranceKeepsPin() {
        let tick = TranscriptScrollPin.tick(
            old: snapshot(offsetY: 600), new: snapshot(offsetY: 594), pinned: true, mode: .live
        )

        #expect(!tick.reanchors)
        #expect(tick.pinnedAfter)
    }

    @Test("a mixed up-tick defers the pin decision")
    func mixedUpTickDefers() {
        let tick = TranscriptScrollPin.tick(
            old: snapshot(offsetY: 600),
            new: snapshot(offsetY: 550, contentHeight: 1040),
            pinned: true,
            mode: .live
        )

        #expect(!tick.reanchors)
        #expect(tick.pinnedAfter)
    }

    @Test("scrolling down into the bottom re-engages the pin and chases")
    func scrollDownRepins() {
        let tick = TranscriptScrollPin.tick(
            old: snapshot(offsetY: 500), new: snapshot(offsetY: 598), pinned: false, mode: .live
        )

        #expect(tick.reanchors)
        #expect(tick.pinnedAfter)
    }

    @Test("scrolling down short of the bottom while unpinned does nothing")
    func scrollDownShortStaysUnpinned() {
        let tick = TranscriptScrollPin.tick(
            old: snapshot(offsetY: 500), new: snapshot(offsetY: 520), pinned: false, mode: .live
        )

        #expect(!tick.reanchors)
        #expect(!tick.pinnedAfter)
    }

    // MARK: - Growth under a stationary offset

    @Test("growth under a stationary offset re-anchors while pinned")
    func growthReanchorsWhilePinned() {
        let tick = TranscriptScrollPin.tick(
            old: snapshot(offsetY: 600),
            new: snapshot(offsetY: 600, contentHeight: 1060),
            pinned: true,
            mode: .live
        )

        #expect(tick.reanchors)
        #expect(tick.pinnedAfter)
    }

    @Test("growth under a stationary offset does nothing while unpinned")
    func growthDoesNothingWhileUnpinned() {
        let tick = TranscriptScrollPin.tick(
            old: snapshot(offsetY: 300),
            new: snapshot(offsetY: 300, contentHeight: 1060),
            pinned: false,
            mode: .live
        )

        #expect(!tick.reanchors)
        #expect(!tick.pinnedAfter)
    }

    // MARK: - Jump-button visibility

    @Test("the up button hides until the content top leaves the tolerance")
    func upButtonFollowsDistanceToTop() {
        #expect(!TranscriptScrollPin.visibility(pinned: true, snapshot: nil, mode: .live).up)
        #expect(
            !TranscriptScrollPin.visibility(
                pinned: true, snapshot: snapshot(offsetY: 8), mode: .live
            ).up
        )
        #expect(
            TranscriptScrollPin.visibility(
                pinned: true, snapshot: snapshot(offsetY: 9), mode: .live
            ).up
        )
    }

    @Test("the down button tracks the pin flag, including before any tick")
    func downButtonTracksPin() {
        #expect(!TranscriptScrollPin.visibility(pinned: true, snapshot: nil, mode: .live).down)
        #expect(TranscriptScrollPin.visibility(pinned: false, snapshot: nil, mode: .live).down)
        #expect(
            TranscriptScrollPin.visibility(
                pinned: false, snapshot: snapshot(offsetY: 600), mode: .live
            ).down
        )
    }

    // MARK: - Boundaries of the live pin rules

    @Test("scrolling down to exactly the tolerance re-engages the pin")
    func scrollDownToTheToleranceRepins() {
        let tick = TranscriptScrollPin.tick(
            old: snapshot(offsetY: 500),
            new: snapshot(offsetY: 592),
            pinned: false,
            mode: .live
        )

        #expect(tick.reanchors)
        #expect(tick.pinnedAfter)
    }

    @Test("a mixed up-tick exactly at the settle epsilon is trusted")
    func mixedUpTickAtTheEpsilonIsTrusted() {
        // The span moved by exactly the epsilon, so the distance counts as
        // still and drives the pin decision.
        let tick = TranscriptScrollPin.tick(
            old: snapshot(offsetY: 600),
            new: snapshot(offsetY: 550, contentHeight: 1002),
            pinned: true,
            mode: .live
        )

        #expect(!tick.reanchors)
        #expect(!tick.pinnedAfter)
    }

    @Test(
        "only the live feed's newest row fades in",
        arguments: [
            (TranscriptScrollPin.Mode.live, true, true),
            (.live, false, false),
            (.archive, true, false),
            (.archive, false, false),
        ]
    )
    func rowFadeMapping(mode: TranscriptScrollPin.Mode, isNewest: Bool, expected: Bool) {
        #expect(TranscriptScrollPin.rowFadesIn(in: mode, isNewest: isNewest) == expected)
    }
}

/// Archive mode and the opening jump share the same pure core; they are a
/// second suite so neither struct outgrows the type-length rule.
@Suite("Transcript scroll pin archive mode")
struct TranscriptScrollPinArchiveTests {

    // MARK: - Archive record mode

    @Test("a flip to a record asks for a top jump and releases the pin")
    func archiveModeJumpsToTopAndReleasesThePin() {
        let change = TranscriptScrollPin.modeChange(to: .archive)

        #expect(change.jumpsToTop)
        #expect(!change.pinnedAfter)
    }

    @Test("a flip to the live feed keeps the pin and asks for no jump")
    func liveModeKeepsThePin() {
        let change = TranscriptScrollPin.modeChange(to: .live)

        #expect(!change.jumpsToTop)
        #expect(change.pinnedAfter)
    }

    @Test("only the live feed follows a content change")
    func onlyTheLiveFeedFollowsTheTail() {
        #expect(TranscriptScrollPin.followsTail(in: .live))
        #expect(!TranscriptScrollPin.followsTail(in: .archive))
    }

    @Test("the pin and the tail follow the same mode")
    func pinAndTailAgree() {
        // The two mappings are independent, so a divergence between them
        // — a live feed that claims to follow its tail while its pin is
        // released — would silently stop the feed from following.
        #expect(
            TranscriptScrollPin.modeChange(to: .live).pinnedAfter
                == TranscriptScrollPin.followsTail(in: .live)
        )
        #expect(
            TranscriptScrollPin.modeChange(to: .archive).pinnedAfter
                == TranscriptScrollPin.followsTail(in: .archive)
        )
    }

    @Test("only the live feed's down button re-pins")
    func onlyTheLiveFeedRepins() {
        // A finished record has no tail to follow: its down button is a
        // one-shot jump to the newest sentence.
        #expect(TranscriptScrollPin.downButtonRepins(in: .live))
        #expect(!TranscriptScrollPin.downButtonRepins(in: .archive))
    }

    @Test("a record's scroll to the bottom does not re-pin it")
    func archiveScrollToBottomDoesNotRepin() {
        // The live feed re-pins when the reader reaches the bottom; a
        // finished record keeps its pin released, so nothing chases the
        // marker afterwards.
        let tick = TranscriptScrollPin.tick(
            old: snapshot(offsetY: 500),
            new: snapshot(offsetY: 598),
            pinned: true,
            mode: .archive
        )

        #expect(!tick.reanchors)
        #expect(!tick.pinnedAfter)
    }

    @Test("a record's growth never re-anchors, whatever the pin says")
    func archiveGrowthNeverReanchors() {
        // The live feed re-anchors on growth while pinned; a finished
        // record never does, so a landed translation cannot drag the
        // reader down to the bottom.
        let tick = TranscriptScrollPin.tick(
            old: snapshot(offsetY: 300),
            new: snapshot(offsetY: 300, contentHeight: 1060),
            pinned: true,
            mode: .archive
        )

        #expect(!tick.reanchors)
        #expect(!tick.pinnedAfter)
    }

    @Test(
        "a record's down button is offered by the content below, not by the pin",
        arguments: [
            (false, CGFloat(600), false),
            (false, CGFloat(300), true),
            (true, CGFloat(600), false),
            (true, CGFloat(300), true),
        ]
    )
    func archiveDownButtonFollowsTheContentBelow(pinned: Bool, offsetY: CGFloat, down: Bool) {
        let visibility = TranscriptScrollPin.visibility(
            pinned: pinned, snapshot: snapshot(offsetY: offsetY), mode: .archive
        )

        #expect(visibility.down == down)
    }

    @Test("a record hides both buttons before its first tick")
    func archiveVisibilityHidesBeforeTheFirstTick() {
        let visibility = TranscriptScrollPin.visibility(
            pinned: false, snapshot: nil, mode: .archive
        )

        #expect(!visibility.up)
        #expect(!visibility.down)
    }

    // MARK: - The pending top jump

    @Test(
        "the pending jump settles flush at the content top, epsilon and inset included",
        arguments: [
            (300, 0, 1000, false, 0),
            (300, 0, 1000, true, 0),
            (300, TranscriptScrollPin.settleEpsilon, 1000, true, 0),
            (300, -20, 1000, true, 20),
        ]
    )
    func topJumpSettlesAtTheTop(
        oldOffset: CGFloat, newOffset: CGFloat, contentHeight: CGFloat,
        jumpInFlight: Bool, insetTop: CGFloat
    ) {
        let decision = TranscriptScrollPin.topJump(
            old: snapshot(offsetY: oldOffset),
            new: snapshot(offsetY: newOffset, contentHeight: contentHeight, insetTop: insetTop),
            jumpInFlight: jumpInFlight
        )

        #expect(decision == .settled)
    }

    @Test(
        "the reader's own scroll outranks the pending jump, in flight or not",
        arguments: [
            (420, 1200, false),
            (420, 1000, true),
            (260, 1000, false),
            (120, 1200, false),
        ]
    )
    func topJumpIsCancelledByTheReader(
        newOffset: CGFloat, contentHeight: CGFloat, jumpInFlight: Bool
    ) {
        let decision = TranscriptScrollPin.topJump(
            old: snapshot(offsetY: 300),
            new: snapshot(offsetY: newOffset, contentHeight: contentHeight),
            jumpInFlight: jumpInFlight
        )

        #expect(decision == .cancelled)
    }

    @Test(
        "the jump stays owed after its own short landing or a content move",
        arguments: [
            (40, 500, false),
            (300, 1200, false),
            (298.5, 1200, false),
            (40, 1000, true),
        ]
    )
    func topJumpRetriesWhileOwed(newOffset: CGFloat, contentHeight: CGFloat, jumpInFlight: Bool) {
        let decision = TranscriptScrollPin.topJump(
            old: snapshot(offsetY: 300),
            new: snapshot(offsetY: newOffset, contentHeight: contentHeight),
            jumpInFlight: jumpInFlight
        )

        #expect(decision == .retry)
    }

    @Test(
        "a tick that moves less than the epsilon leaves the pending jump alone",
        arguments: [301.5, 300]
    )
    func topJumpStaysPendingWhenNothingMoves(newOffset: CGFloat) {
        let decision = TranscriptScrollPin.topJump(
            old: snapshot(offsetY: 300),
            new: snapshot(offsetY: newOffset),
            jumpInFlight: false
        )

        #expect(decision == .none)
    }
}
