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

    @Test("a record's down button is offered only while there is content below")
    func archiveDownButtonFollowsTheContentBelow() {
        // Flush with the bottom: there is no newer sentence to jump to.
        #expect(
            !TranscriptScrollPin.visibility(
                pinned: false, snapshot: snapshot(offsetY: 600), mode: .archive
            ).down
        )
        // Mid-record: the newest sentence is still below the viewport.
        #expect(
            TranscriptScrollPin.visibility(
                pinned: false, snapshot: snapshot(offsetY: 300), mode: .archive
            ).down
        )
    }

    @Test("a record's down button is offered by the content, not by the pin")
    func archiveDownButtonIgnoresThePin() {
        // A record's pin is always released, so the pin must not decide
        // whether the button is offered.
        #expect(
            !TranscriptScrollPin.visibility(
                pinned: true, snapshot: snapshot(offsetY: 600), mode: .archive
            ).down
        )
        #expect(
            TranscriptScrollPin.visibility(
                pinned: true, snapshot: snapshot(offsetY: 300), mode: .archive
            ).down
        )
    }

    // MARK: - The pending top jump

    @Test("the pending jump settles at the content top")
    func topJumpSettlesAtTheTop() {
        let decision = TranscriptScrollPin.topJump(
            old: snapshot(offsetY: 300),
            new: snapshot(offsetY: 0),
            jumpInFlight: false
        )

        #expect(decision == .settled)
    }

    @Test("the reader's scroll away from the top cancels the pending jump")
    func topJumpIsCancelledByTheReader() {
        // The content grew in the same tick, but the reader moved first:
        // their place wins over the jump.
        let decision = TranscriptScrollPin.topJump(
            old: snapshot(offsetY: 300),
            new: snapshot(offsetY: 420, contentHeight: 1200),
            jumpInFlight: false
        )

        #expect(decision == .cancelled)
    }

    @Test("the reader's scroll up cancels the pending jump too")
    func topJumpIsCancelledByAnUpwardScroll() {
        // Heading for the oldest sentence is still the reader's own move:
        // the jump must not pull them the rest of the way.
        let decision = TranscriptScrollPin.topJump(
            old: snapshot(offsetY: 300),
            new: snapshot(offsetY: 260),
            jumpInFlight: false
        )

        #expect(decision == .cancelled)
    }

    @Test("the content swap's clamping is not the reader's move")
    func topJumpSurvivesTheSwapClamp() {
        // A record shorter than the live feed pulls the offset up as the
        // rows land: that is the swap's clamping, so the jump is still owed.
        let decision = TranscriptScrollPin.topJump(
            old: snapshot(offsetY: 300),
            new: snapshot(offsetY: 40, contentHeight: 500),
            jumpInFlight: false
        )

        #expect(decision == .retry)
    }

    @Test("the reader's scroll up wins even while the content grows")
    func topJumpIsCancelledByAnUpwardScrollOverGrowth() {
        // Growing content never pulls the offset up, so an offset that
        // moved up while the content grew is the reader's own move.
        let decision = TranscriptScrollPin.topJump(
            old: snapshot(offsetY: 300),
            new: snapshot(offsetY: 120, contentHeight: 1200),
            jumpInFlight: false
        )

        #expect(decision == .cancelled)
    }

    @Test("the jump's flush landing settles even while it is in flight")
    func topJumpSettlesWhileInFlight() {
        let decision = TranscriptScrollPin.topJump(
            old: snapshot(offsetY: 300),
            new: snapshot(offsetY: 0),
            jumpInFlight: true
        )

        #expect(decision == .settled)
    }

    @Test("the reader's scroll down wins over the jump in flight")
    func topJumpIsCancelledByTheReaderOverTheJumpInFlight() {
        // The reader's move is the only thing that moves the offset down:
        // it is theirs even while the jump is on its way.
        let decision = TranscriptScrollPin.topJump(
            old: snapshot(offsetY: 300),
            new: snapshot(offsetY: 420),
            jumpInFlight: true
        )

        #expect(decision == .cancelled)
    }

    @Test("a move below the tolerance leaves the pending jump alone")
    func topJumpIgnoresAMoveBelowTheTolerance() {
        // A move within the settle epsilon is not the reader taking over:
        // the pending jump stays as it is.
        let decision = TranscriptScrollPin.topJump(
            old: snapshot(offsetY: 300),
            new: snapshot(offsetY: 301.5),
            jumpInFlight: false
        )

        #expect(decision == .none)
    }

    @Test("the jump counts as settled exactly at the settle epsilon")
    func topJumpSettlesAtExactlyTheEpsilon() {
        let decision = TranscriptScrollPin.topJump(
            old: snapshot(offsetY: 300),
            new: snapshot(offsetY: TranscriptScrollPin.settleEpsilon),
            jumpInFlight: true
        )

        #expect(decision == .settled)
    }

    @Test("the top distance counts the viewport inset")
    func topJumpSettlesWithAnInset() {
        // At the content top the raw offset is the negative inset, so the
        // jump must not read it as a short landing.
        let decision = TranscriptScrollPin.topJump(
            old: snapshot(offsetY: 300),
            new: snapshot(offsetY: -20, insetTop: 20),
            jumpInFlight: true
        )

        #expect(decision == .settled)
    }

    @Test("a small upward settle under growth leaves the jump owed")
    func topJumpRetriesOnGrowthWithASmallUpwardMove() {
        // The offset moved up less than the epsilon while the content grew:
        // that is layout, not the reader, so the jump is still owed.
        let decision = TranscriptScrollPin.topJump(
            old: snapshot(offsetY: 300),
            new: snapshot(offsetY: 298.5, contentHeight: 1200),
            jumpInFlight: false
        )

        #expect(decision == .retry)
    }

    @Test("a record hides both buttons before its first tick")
    func archiveVisibilityHidesBeforeTheFirstTick() {
        let visibility = TranscriptScrollPin.visibility(
            pinned: false, snapshot: nil, mode: .archive
        )

        #expect(!visibility.up)
        #expect(!visibility.down)
    }

    @Test("content growth under a reader who has not moved retries the jump")
    func topJumpRetriesOnGrowth() {
        let decision = TranscriptScrollPin.topJump(
            old: snapshot(offsetY: 300),
            new: snapshot(offsetY: 300, contentHeight: 1200),
            jumpInFlight: false
        )

        #expect(decision == .retry)
    }

    @Test("the jump's own short landing leaves the retry owed")
    func topJumpRetriesAfterAShortLanding() {
        // The jump fired and the viewport is still below the content top:
        // the movement there is the jump's, not the reader's.
        let decision = TranscriptScrollPin.topJump(
            old: snapshot(offsetY: 300),
            new: snapshot(offsetY: 40),
            jumpInFlight: true
        )

        #expect(decision == .retry)
    }

    @Test("a tick that moves nothing leaves the pending jump alone")
    func topJumpStaysPendingWhenNothingMoves() {
        let decision = TranscriptScrollPin.topJump(
            old: snapshot(offsetY: 300),
            new: snapshot(offsetY: 300),
            jumpInFlight: false
        )

        #expect(decision == .none)
    }
}
