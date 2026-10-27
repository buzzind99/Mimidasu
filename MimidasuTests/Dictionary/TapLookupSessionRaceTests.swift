import Foundation
@testable import Mimidasu
import Testing

/// A resolver that parks every lookup on a checked continuation until the test
/// lands an answer. Parking makes the interleaving explicit: the suite decides
/// which tap resolves first, never the scheduler.
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

    /// Resumes the parked lookup for `surface` with `answer`. A surface with
    /// no parked call is ignored; the bounded wait, not this method, is what
    /// catches a tap that never reached the resolver.
    func land(_ answer: LookupAnswer?, surface: String) {
        guard let index = pending.firstIndex(where: { entry in
            entry.request.surface == surface
        }) else { return }
        pending.remove(at: index).continuation.resume(returning: answer)
    }

    /// Releases every parked call as a drop (nil) and makes later calls drop
    /// immediately. The timeout path uses this so a failed wait cannot leak a
    /// checked continuation or leave a tap task parked forever.
    func cancelAll() {
        let parked = pending
        pending.removeAll()
        isCancelled = true
        for entry in parked {
            entry.continuation.resume(returning: nil)
        }
    }
}

/// Records every feedback call, so a test can prove a stale or cleared landing
/// posts neither a warning nor a fault.
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
private final class TapLookupRaceHarness {
    let resolver = GatedTapLookupResolver()
    let feedback = TapLookupFeedbackSpy()
    let session: TapLookupSession

    init() {
        session = TapLookupSession(resolver: resolver)
        session.feedback = feedback
    }
}

/// Thrown when the resolver gate never opens within the bounded wait.
private struct RaceWaitTimedOut: Error {}

/// Bounded poll for the resolver to park `expected` calls. Yielding between
/// polls lets the tap tasks reach the resolver before the next check.
@MainActor
private func waitForParked(
    _ expected: Int,
    in resolver: GatedTapLookupResolver,
    timeout: Duration = .seconds(2)
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await resolver.pendingCount >= expected {
            return true
        }
        await Task.yield()
    }
    return await resolver.pendingCount >= expected
}

/// Waits for `expected` parked calls, or cancels every parked call and fails
/// the test. Cancellation matters: a timed-out wait must not leave a
/// continuation dangling or a tap task parked on it.
@MainActor
private func waitOrCancel(
    _ expected: Int, in resolver: GatedTapLookupResolver
) async throws {
    guard await waitForParked(expected, in: resolver) else {
        await resolver.cancelAll()
        throw RaceWaitTimedOut()
    }
}

/// Lands `answer` on `surface` and waits for the tap task to finish, so the
/// next interleaving starts from a settled session.
@MainActor
private func landAndWait(
    _ answer: LookupAnswer?,
    surface: String,
    on task: Task<Void, Never>,
    resolver: GatedTapLookupResolver
) async {
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

/// One hand-built hit: one entry per headword, ranked as given.
private func found(_ headwords: [String]) -> LookupAnswer {
    let entries = headwords.enumerated().map { index, headword in
        entry(headword, seq: index + 1)
    }
    return .found(
        result: LookupResult(matched: headwords[0], entries: entries),
        also: [],
        origin: .tappedSurface
    )
}

/// Interleaving coverage for the tap session: a landing whose generation moved
/// on is dropped whole, and a clear at a session boundary invalidates whatever
/// is in flight. Every lookup is parked on a test-controlled continuation so
/// ordering is deterministic; ordinary answer routing stays in
/// `TapLookupSessionTests`.
@MainActor
@Suite("TapLookupSession races")
struct TapLookupSessionRaceTests {

    // MARK: - Landing order

    @Test("a stale pinnable answer loses to the newer landing that resolved first")
    func staleAnswerDrops() async throws {
        let harness = TapLookupRaceHarness()
        let staleContent = found(["雨"])
        let currentContent = found(["飴"])
        let staleAnchor = LookupAnchor.transcript(sentenceIndex: 0, tokenIndex: 0)
        let currentAnchor = LookupAnchor.transcript(sentenceIndex: 1, tokenIndex: 2)

        let staleTask = harness.session.tap(
            request("雨"), anchor: staleAnchor, favorites: .empty
        )
        let currentTask = harness.session.tap(
            request("飴"), anchor: currentAnchor, favorites: .empty
        )
        try await waitOrCancel(2, in: harness.resolver)

        await landAndWait(
            currentContent,
            surface: "飴",
            on: currentTask,
            resolver: harness.resolver
        )
        #expect(harness.session.presentation?.content == currentContent)
        #expect(harness.session.presentation?.anchor == currentAnchor)

        await landAndWait(
            staleContent,
            surface: "雨",
            on: staleTask,
            resolver: harness.resolver
        )

        #expect(harness.session.presentation?.content == currentContent)
        #expect(harness.session.presentation?.anchor == currentAnchor)
        #expect(harness.session.popoverItem(for: staleAnchor) == nil)
        #expect(harness.feedback.warnings.isEmpty)
        #expect(harness.feedback.faults.isEmpty)
    }

    @Test(
        "a stale warning or fault posts no feedback",
        arguments: [
            LookupAnswer.noHit(surface: "雨"),
            LookupAnswer.failure(.databaseMissing)
        ]
    )
    func staleFeedbackDrops(_ staleAnswer: LookupAnswer) async throws {
        let harness = TapLookupRaceHarness()
        let currentContent = found(["飴"])
        let currentAnchor = LookupAnchor.transcript(sentenceIndex: 0, tokenIndex: 1)

        let staleTask = harness.session.tap(
            request("雨"), anchor: .liveStrip, favorites: .empty
        )
        let currentTask = harness.session.tap(
            request("飴"), anchor: currentAnchor, favorites: .empty
        )
        try await waitOrCancel(2, in: harness.resolver)

        await landAndWait(
            currentContent,
            surface: "飴",
            on: currentTask,
            resolver: harness.resolver
        )
        await landAndWait(
            staleAnswer,
            surface: "雨",
            on: staleTask,
            resolver: harness.resolver
        )

        #expect(harness.session.presentation?.content == currentContent)
        #expect(harness.session.presentation?.anchor == currentAnchor)
        #expect(harness.feedback.warnings.isEmpty)
        #expect(harness.feedback.faults.isEmpty)
    }

    @Test("a same-anchor rapid retap keeps the newest content and the anchor")
    func sameAnchorRetapKeepsNewestContent() async throws {
        let harness = TapLookupRaceHarness()
        let anchor = LookupAnchor.transcript(sentenceIndex: 2, tokenIndex: 1)
        let firstContent = found(["雨"])
        let secondContent = found(["飴"])

        let firstTask = harness.session.tap(
            request("雨"), anchor: anchor, favorites: .empty
        )
        let secondTask = harness.session.tap(
            request("飴"), anchor: anchor, favorites: .empty
        )
        try await waitOrCancel(2, in: harness.resolver)

        await landAndWait(
            secondContent,
            surface: "飴",
            on: secondTask,
            resolver: harness.resolver
        )
        await landAndWait(
            firstContent,
            surface: "雨",
            on: firstTask,
            resolver: harness.resolver
        )

        let presentation = try #require(harness.session.presentation)
        #expect(presentation.content == secondContent)
        #expect(presentation.anchor == anchor)
        #expect(harness.session.popoverItem(for: anchor) == presentation)
        #expect(harness.feedback.warnings.isEmpty)
        #expect(harness.feedback.faults.isEmpty)
    }

    // MARK: - Session boundaries

    @Test("clear while a pinnable answer is in flight drops the landing")
    func clearDropsInFlightAnswer() async throws {
        let harness = TapLookupRaceHarness()
        let content = found(["あめ"])
        let anchor = LookupAnchor.liveStrip

        let task = harness.session.tap(
            request("あめ"), anchor: anchor, favorites: .empty
        )
        try await waitOrCancel(1, in: harness.resolver)

        harness.session.clear()
        await landAndWait(
            content,
            surface: "あめ",
            on: task,
            resolver: harness.resolver
        )

        #expect(harness.session.presentation == nil)
        #expect(harness.session.popoverItem(for: anchor) == nil)
        #expect(harness.feedback.warnings.isEmpty)
        #expect(harness.feedback.faults.isEmpty)
    }

    @Test("clear while a warning is in flight posts no feedback")
    func clearDropsInFlightWarning() async throws {
        let harness = TapLookupRaceHarness()

        let task = harness.session.tap(
            request("xyz"), anchor: .liveStrip, favorites: .empty
        )
        try await waitOrCancel(1, in: harness.resolver)

        harness.session.clear()
        await landAndWait(
            .noHit(surface: "xyz"),
            surface: "xyz",
            on: task,
            resolver: harness.resolver
        )

        #expect(harness.session.presentation == nil)
        #expect(harness.feedback.warnings.isEmpty)
        #expect(harness.feedback.faults.isEmpty)
    }
}
