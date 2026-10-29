import Foundation
@testable import Mimidasu
import Testing

/// A lookup resolver that parks every call until the test lands an answer, so
/// dispatch order, staleness, and feedback routing stay deterministic.
private actor GatedTapLookupResolver: TapLookupResolving {
    private struct Pending {
        let request: TapLookupRequest
        let continuation: CheckedContinuation<LookupAnswer?, Never>
    }

    private var pending: [Pending] = []
    private var isCancelled = false

    var pendingCount: Int {
        pending.count
    }

    func resolve(
        _ request: TapLookupRequest, favorites: FavoriteIdentity
    ) async -> LookupAnswer? {
        guard !isCancelled else { return nil }
        return await withCheckedContinuation { continuation in
            pending.append(Pending(request: request, continuation: continuation))
        }
    }

    /// Lands `answer` on the parked request that tapped `surface`.
    func land(_ answer: LookupAnswer?, surface: String) {
        guard let index = pending.firstIndex(where: { entry in
            entry.request.surface == surface
        }) else { return }
        pending.remove(at: index).continuation.resume(returning: answer)
    }

    /// Releases every parked call as a drop (nil), and any later call too —
    /// the failure path's cleanup, so a timed-out wait cannot leak a checked
    /// continuation.
    func cancelAll() {
        let parked = pending
        pending.removeAll()
        isCancelled = true
        for entry in parked {
            entry.continuation.resume(returning: nil)
        }
    }
}

@MainActor
private final class TapLookupFeedbackSpy: TapLookupFeedbackSink {
    private(set) var warnings: [String] = []
    private(set) var faults: [DictionaryError] = []

    func tapLookupDidWarnNoHit(surface: String) {
        warnings.append(surface)
    }

    func tapLookupDidFail(_ fault: DictionaryError) {
        faults.append(fault)
    }
}

@MainActor
private final class TapLookupSessionHarness {
    let resolver = GatedTapLookupResolver()
    let spy = TapLookupFeedbackSpy()
    let session: TapLookupSession

    init(attachFeedback: Bool = true) {
        session = TapLookupSession(resolver: resolver)
        if attachFeedback {
            session.feedback = spy
        }
    }
}

private struct LookupNeverResolved: Error {}

/// Bounded wait for the resolver to park `expected` calls. Yields between
/// polls so the tap tasks reach the resolver first.
@MainActor
private func waitForPending(
    _ expected: Int, in resolver: GatedTapLookupResolver, timeout: TimeInterval = 2
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await resolver.pendingCount >= expected {
            return true
        }
        await Task.yield()
    }
    return await resolver.pendingCount >= expected
}

/// Bounded wait that cancels every parked call on timeout, so a failed wait
/// cannot leak a checked continuation or leave a tap task parked.
@MainActor
private func waitOrCancel(
    _ expected: Int, in resolver: GatedTapLookupResolver
) async throws {
    guard await waitForPending(expected, in: resolver) else {
        await resolver.cancelAll()
        throw LookupNeverResolved()
    }
}

/// Waits for the tap to reach the resolver, lands `answer`, then waits for the
/// resulting state change. Throws instead of awaiting a task that never
/// started, so a timeout cannot hang the suite.
@MainActor
private func landAndWait(
    _ answer: LookupAnswer?,
    surface: String,
    after expected: Int = 1,
    task: Task<Void, Never>,
    resolver: GatedTapLookupResolver
) async throws {
    try await waitOrCancel(expected, in: resolver)
    await resolver.land(answer, surface: surface)
    await task.value
}

private func request(_ surface: String) -> TapLookupRequest {
    TapLookupRequest(
        segments: [LookupSegment(surface: surface)],
        tappedAt: 0,
        sentenceText: surface,
        surface: surface
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

/// A hand-built entry whose writing and reading differ, so a test can tie an
/// entry to the matched text through its reading alone.
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

/// One hand-built hit: one entry per headword, ranked as given.
private func result(_ headwords: [String]) -> LookupResult {
    LookupResult(
        matched: headwords[0],
        entries: headwords.enumerated().map { index, headword in
            entry(headword, seq: index + 1)
        }
    )
}

private func found(_ display: [String], also: [String] = []) -> LookupAnswer {
    .found(
        result: result(display),
        also: also.map { headword in result([headword]) },
        origin: .tappedSurface
    )
}

@MainActor
private func present(
    _ content: LookupAnswer,
    surface: String,
    anchor: LookupAnchor = .liveStrip,
    in harness: TapLookupSessionHarness
) async throws -> LookupPresentation {
    let task = harness.session.tap(request(surface), anchor: anchor, favorites: .empty)
    try await landAndWait(
        content,
        surface: surface,
        task: task,
        resolver: harness.resolver
    )
    return try #require(harness.session.presentation)
}

@MainActor
@Suite("TapLookupSession")
struct TapLookupSessionTests {

    // MARK: - Answer routing

    @Test("a pinnable answer writes the popover and pinned card from one presentation")
    func pinnableAnswerPresentsBothHosts() async throws {
        let harness = TapLookupSessionHarness()
        let content = found(["飴", "雨"])

        let task = harness.session.tap(request("あめ"), anchor: .liveStrip, favorites: .empty)

        try await landAndWait(
            content,
            surface: "あめ",
            task: task,
            resolver: harness.resolver
        )

        let presentation = try #require(harness.session.presentation)
        #expect(presentation.content == content)
        // The pager starts at the first entry — the popover and the pinned
        // card page together from there. The clamp an out-of-range request
        // would take is pinned by `LookupPresentationTests.initialClampsEntryIndex`.
        #expect(presentation.entryIndex == 0)
        #expect(presentation.anchor == .liveStrip)
        #expect(harness.session.popoverItem(for: .liveStrip) == presentation)
    }

    @Test("a warn posts exactly one warning and leaves the presentation unchanged")
    func warnLeavesPresentation() async throws {
        let harness = TapLookupSessionHarness()
        let content = found(["あめ"])
        let shown = try await present(content, surface: "あめ", in: harness)

        let task = harness.session.tap(request("xyz"), anchor: .liveStrip, favorites: .empty)

        try await landAndWait(
            .noHit(surface: "xyz"),
            surface: "xyz",
            task: task,
            resolver: harness.resolver
        )

        #expect(harness.spy.warnings == ["xyz"])
        #expect(harness.spy.faults.isEmpty)
        #expect(harness.session.presentation == shown)
    }

    @Test("a fault posts exactly one fault and leaves the presentation unchanged")
    func faultLeavesPresentation() async throws {
        let harness = TapLookupSessionHarness()
        let content = found(["あめ"])
        let shown = try await present(content, surface: "あめ", in: harness)

        let task = harness.session.tap(request("xyz"), anchor: .liveStrip, favorites: .empty)

        try await landAndWait(
            .failure(.databaseMissing),
            surface: "xyz",
            task: task,
            resolver: harness.resolver
        )

        #expect(harness.spy.warnings.isEmpty)
        #expect(harness.spy.faults == [.databaseMissing])
        #expect(harness.session.presentation == shown)
    }

    @Test("a dropped answer changes nothing")
    func droppedAnswerChangesNothing() async throws {
        let harness = TapLookupSessionHarness()
        let content = found(["あめ"])
        let shown = try await present(content, surface: "あめ", in: harness)

        let task = harness.session.tap(
            request("xyz"),
            anchor: .transcript(sentenceIndex: 3, tokenIndex: 0),
            favorites: .empty
        )

        try await landAndWait(
            nil,
            surface: "xyz",
            task: task,
            resolver: harness.resolver
        )

        #expect(harness.session.presentation == shown)
        #expect(harness.spy.warnings.isEmpty)
        #expect(harness.spy.faults.isEmpty)
    }

    @Test("a nil feedback sink drops a no-hit silently")
    func nilSinkDropsFeedback() async throws {
        let harness = TapLookupSessionHarness(attachFeedback: false)

        let task = harness.session.tap(request("xyz"), anchor: .liveStrip, favorites: .empty)

        try await landAndWait(
            .noHit(surface: "xyz"),
            surface: "xyz",
            task: task,
            resolver: harness.resolver
        )

        #expect(harness.session.presentation == nil)
        #expect(harness.session.feedback == nil)
    }

    // MARK: - Anchors

    @Test("a same-anchor retap swaps content and a different anchor moves the popover")
    func anchorSwap() async throws {
        let harness = TapLookupSessionHarness()
        let word = LookupAnchor.transcript(sentenceIndex: 0, tokenIndex: 0)
        let first = found(["お"])
        let second = found(["あめ"])
        let third = found(["雨"])

        let firstTask = harness.session.tap(request("お"), anchor: word, favorites: .empty)
        try await landAndWait(
            first,
            surface: "お",
            task: firstTask,
            resolver: harness.resolver
        )

        let secondTask = harness.session.tap(request("あめ"), anchor: word, favorites: .empty)
        try await landAndWait(
            second,
            surface: "あめ",
            task: secondTask,
            resolver: harness.resolver
        )

        #expect(harness.session.presentation?.content == second)
        #expect(harness.session.presentation?.anchor == word)

        let thirdTask = harness.session.tap(request("雨"), anchor: .liveStrip, favorites: .empty)
        try await landAndWait(
            third,
            surface: "雨",
            task: thirdTask,
            resolver: harness.resolver
        )

        #expect(harness.session.presentation?.content == third)
        #expect(harness.session.presentation?.anchor == .liveStrip)
        #expect(harness.session.popoverItem(for: word) == nil)
        #expect(harness.session.popoverItem(for: .liveStrip) == harness.session.presentation)
    }

    @Test("dismissal clears only the owning anchor and keeps content and entry")
    func dismissalOwnership() async throws {
        let harness = TapLookupSessionHarness()
        let content = found(["飴", "雨"])
        let word = LookupAnchor.transcript(sentenceIndex: 0, tokenIndex: 1)
        let other = LookupAnchor.transcript(sentenceIndex: 1, tokenIndex: 1)

        let task = harness.session.tap(request("あめ"), anchor: word, favorites: .empty)
        try await landAndWait(
            content,
            surface: "あめ",
            task: task,
            resolver: harness.resolver
        )
        harness.session.stepEntry(to: 1)

        harness.session.dismissPopover(from: other)

        #expect(harness.session.presentation?.anchor == word)
        #expect(harness.session.presentation?.entryIndex == 1)

        harness.session.dismissPopover(from: word)

        #expect(harness.session.presentation?.anchor == nil)
        #expect(harness.session.presentation?.content == content)
        #expect(harness.session.presentation?.entryIndex == 1)
        #expect(harness.session.popoverItem(for: word) == nil)
    }

    // MARK: - Fallback and pager

    @Test("a fallback selection keeps the anchor and resets the pager, dismissal included")
    func fallbackSelectionKeepsAnchor() async throws {
        let harness = TapLookupSessionHarness()
        let content = found(["お", "御"], also: ["お土産", "土産"])
        let firstFallback = try #require(content.fallbackResults.first)
        let secondFallback = try #require(content.fallbackResults.last)
        let word = LookupAnchor.transcript(sentenceIndex: 0, tokenIndex: 1)

        let task = harness.session.tap(request("お"), anchor: word, favorites: .empty)
        try await landAndWait(
            content,
            surface: "お",
            task: task,
            resolver: harness.resolver
        )
        harness.session.stepEntry(to: 1)

        harness.session.selectFallback(firstFallback, favorites: .empty)

        #expect(harness.session.presentation?.content.displayResult == firstFallback)
        #expect(harness.session.presentation?.entryIndex == 0)
        #expect(harness.session.presentation?.anchor == word)

        harness.session.dismissPopover(from: word)
        harness.session.selectFallback(secondFallback, favorites: .empty)

        #expect(harness.session.presentation?.content.displayResult == secondFallback)
        #expect(harness.session.presentation?.entryIndex == 0)
        #expect(harness.session.presentation?.anchor == nil)
    }

    @Test("a fallback without a presentation or a foreign result is a no-op")
    func fallbackSelectionNoOp() async throws {
        let harness = TapLookupSessionHarness()

        harness.session.selectFallback(result(["お"]), favorites: .empty)
        #expect(harness.session.presentation == nil)

        let shown = try await present(found(["あめ"]), surface: "あめ", in: harness)

        harness.session.selectFallback(result(["foreign"]), favorites: .empty)
        #expect(harness.session.presentation == shown)
    }

    @Test("stepEntry clamps into the display entries")
    func stepEntryClamps() async throws {
        let harness = TapLookupSessionHarness()
        let content = found(["飴", "雨"])

        _ = try await present(content, surface: "あめ", in: harness)

        harness.session.stepEntry(to: 99)
        #expect(harness.session.presentation?.entryIndex == 1)

        harness.session.stepEntry(to: -5)
        #expect(harness.session.presentation?.entryIndex == 0)
    }

    @Test("stepEntry is inert over not-found content")
    func stepEntryInertOnNotFound() async throws {
        let harness = TapLookupSessionHarness()
        let content = LookupAnswer.notFound(surface: "雨尾", related: [result(["雨"])])

        let task = harness.session.tap(request("雨尾"), anchor: .liveStrip, favorites: .empty)
        try await landAndWait(
            content,
            surface: "雨尾",
            task: task,
            resolver: harness.resolver
        )

        harness.session.stepEntry(to: 1)

        #expect(harness.session.presentation?.entryIndex == 0)
        #expect(harness.session.presentation?.content == content)
    }

    @Test("stepEntry before any lookup is a no-op")
    func stepEntryWithoutPresentation() {
        let harness = TapLookupSessionHarness()

        harness.session.stepEntry(to: 1)

        #expect(harness.session.presentation == nil)
    }

    @Test("a foreign fallback keeps the pinned content and pager")
    func foreignFallbackKeepsPager() async throws {
        let harness = TapLookupSessionHarness()
        let content = found(["お", "御"], also: ["お土産"])

        let task = harness.session.tap(request("お"), anchor: .liveStrip, favorites: .empty)
        try await landAndWait(
            content,
            surface: "お",
            task: task,
            resolver: harness.resolver
        )
        harness.session.stepEntry(to: 1)

        harness.session.selectFallback(result(["飴"]), favorites: .empty)

        #expect(harness.session.presentation?.content == content)
        #expect(harness.session.presentation?.entryIndex == 1)
        #expect(harness.session.presentation?.anchor == .liveStrip)
    }

    @Test("a fallback selection re-promotes favorites, resets the pager, and keeps the anchor")
    func fallbackRepromotesFavorites() async throws {
        let harness = TapLookupSessionHarness()
        let display = LookupResult(matched: "あめ", entries: [
            entry(keb: "飴", reb: "あめ", seq: 1),
            entry(keb: "雨", reb: "あめ", seq: 2)
        ])
        let fallback = LookupResult(matched: "あめ", entries: [
            entry(keb: "別", reb: "あめ", seq: 3),
            entry(keb: "雨", reb: "あめ", seq: 4)
        ])
        let content = LookupAnswer.found(
            result: display, also: [fallback], origin: .tappedSurface
        )
        let favorites = FavoriteIdentity(keys: [FavoriteIdentity.normalize("雨")])
        let word = LookupAnchor.transcript(sentenceIndex: 2, tokenIndex: 3)

        let task = harness.session.tap(request("あめ"), anchor: word, favorites: favorites)
        try await landAndWait(
            content,
            surface: "あめ",
            task: task,
            resolver: harness.resolver
        )
        harness.session.stepEntry(to: 1)

        harness.session.selectFallback(fallback, favorites: favorites)

        let promoted = try #require(harness.session.presentation?.content.displayResult)
        #expect(promoted.entries.map(\.entSeq) == [4, 3], "the favorite leads the new display")
        #expect(promoted.entries.first?.keb == "雨")
        #expect(harness.session.presentation?.entryIndex == 0, "the pager restarts")
        #expect(harness.session.presentation?.anchor == word, "the anchor is kept")
    }

    // MARK: - Clear and staleness

    @Test("clear empties the presentation")
    func clearEmptiesPresentation() async throws {
        let harness = TapLookupSessionHarness()

        _ = try await present(found(["あめ"]), surface: "あめ", in: harness)

        harness.session.clear()

        #expect(harness.session.presentation == nil)
        #expect(harness.session.popoverItem(for: .liveStrip) == nil)
    }

    @Test("a stale pinnable answer presents nothing")
    func staleAnswerDrops() async throws {
        let harness = TapLookupSessionHarness()
        let newer = found(["飴"])
        let stale = found(["雨"])

        let staleTask = harness.session.tap(request("雨"), anchor: .liveStrip, favorites: .empty)
        let newerTask = harness.session.tap(request("飴"), anchor: .liveStrip, favorites: .empty)
        try await waitOrCancel(2, in: harness.resolver)

        await harness.resolver.land(newer, surface: "飴")
        await newerTask.value
        await harness.resolver.land(stale, surface: "雨")
        await staleTask.value

        #expect(harness.session.presentation?.content == newer)
        #expect(harness.spy.warnings.isEmpty)
        #expect(harness.spy.faults.isEmpty)
    }

    @Test(
        "a stale warning or fault posts no feedback",
        arguments: [
            LookupAnswer.noHit(surface: "雨"),
            LookupAnswer.failure(.databaseMissing)
        ]
    )
    func staleFeedbackDrops(_ staleAnswer: LookupAnswer) async throws {
        let harness = TapLookupSessionHarness()
        let current = found(["飴"])

        let staleTask = harness.session.tap(request("雨"), anchor: .liveStrip, favorites: .empty)
        let newerTask = harness.session.tap(request("飴"), anchor: .liveStrip, favorites: .empty)
        try await waitOrCancel(2, in: harness.resolver)

        await harness.resolver.land(current, surface: "飴")
        await newerTask.value
        await harness.resolver.land(staleAnswer, surface: "雨")
        await staleTask.value

        #expect(harness.session.presentation?.content == current)
        #expect(harness.spy.warnings.isEmpty)
        #expect(harness.spy.faults.isEmpty)
    }

    @Test("clear during an in-flight pinnable answer drops the landing")
    func clearDropsInFlightAnswer() async throws {
        let harness = TapLookupSessionHarness()
        let content = found(["あめ"])

        let task = harness.session.tap(request("あめ"), anchor: .liveStrip, favorites: .empty)
        try await waitOrCancel(1, in: harness.resolver)

        harness.session.clear()
        await harness.resolver.land(content, surface: "あめ")
        await task.value

        #expect(harness.session.presentation == nil)
        #expect(harness.session.popoverItem(for: .liveStrip) == nil)
    }

    @Test(
        "clear during an in-flight warning or fault drops the feedback",
        arguments: [
            LookupAnswer.noHit(surface: "xyz"),
            LookupAnswer.failure(.databaseMissing)
        ]
    )
    func clearDropsInFlightFeedback(_ staleAnswer: LookupAnswer) async throws {
        let harness = TapLookupSessionHarness()

        let task = harness.session.tap(request("xyz"), anchor: .liveStrip, favorites: .empty)
        try await waitOrCancel(1, in: harness.resolver)

        harness.session.clear()
        await harness.resolver.land(staleAnswer, surface: "xyz")
        await task.value

        #expect(harness.spy.warnings.isEmpty)
        #expect(harness.spy.faults.isEmpty)
    }
}
