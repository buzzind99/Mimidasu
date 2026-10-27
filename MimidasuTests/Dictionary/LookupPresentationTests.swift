import Foundation
@testable import Mimidasu
import Testing

/// Value tests for one lookup presentation: fallback promotion, origin and
/// identity preservation, pager clamping, and popover anchor matching. Pure
/// transforms — no engine, database, or app state — plus the one routing
/// rule a presentation depends on: only a pinnable answer ever becomes one.
@Suite("LookupPresentation")
struct LookupPresentationTests {

    // MARK: - Fixtures

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

    /// A hand-built entry whose writing and reading differ, so promotion can
    /// tie an entry to the matched text through its reading alone.
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

    private func twoEntryFound() -> LookupAnswer {
        .found(result: result(["飴", "雨"]), also: [], origin: .tappedSurface)
    }

    // MARK: - Promotion

    @Test("an also-pill promotion replaces the display and row and resets the pager")
    func promotesAlsoPill() throws {
        let display = result(["お", "御"])
        let firstFallback = result(["お土産"])
        let secondFallback = result(["土産"])
        let content = LookupAnswer.found(
            result: display, also: [firstFallback, secondFallback], origin: .tappedSurface
        )
        let presentation = LookupPresentation(content: content, entryIndex: 1, anchor: .liveStrip)

        let promoted = try #require(presentation.promoting(firstFallback, favorites: .empty))

        #expect(promoted.content.displayResult == firstFallback)
        #expect(promoted.content.fallbackResults == [display, secondFallback])
        #expect(promoted.entryIndex == 0)
        #expect(promoted.anchor == .liveStrip)
    }

    @Test("a related-pill promotion opens it as found and re-promotes its fallbacks")
    func promotesRelatedPill() throws {
        let tapped = LookupResult(matched: "あめ", entries: [
            entry(keb: "飴", reb: "あめ", seq: 1),
            entry(keb: "雨", reb: "あめ", seq: 2)
        ])
        let sibling = LookupResult(matched: "あめ", entries: [
            entry(keb: "別", reb: "あめ", seq: 3),
            entry(keb: "雨", reb: "あめ", seq: 4)
        ])
        let content = LookupAnswer.notFound(surface: "雨尾", related: [tapped, sibling])
        let favorites = FavoriteIdentity(keys: [FavoriteIdentity.normalize("雨")])
        let presentation = LookupPresentation(content: content, entryIndex: 0, anchor: .liveStrip)

        let promoted = try #require(presentation.promoting(tapped, favorites: favorites))

        guard case let .found(result, also, origin) = promoted.content else {
            Issue.record("expected found content")
            return
        }
        #expect(origin == .tappedSurface)
        #expect(result.entries.map(\.keb) == ["雨", "飴"])
        #expect(also.map(\.matched) == ["あめ"])
        #expect(also.first?.entries.map(\.keb) == ["雨", "別"])
        #expect(promoted.entryIndex == 0)
    }

    @Test("a same-display re-promotion preserves its origin")
    func sameDisplayPreservesOrigin() throws {
        let joined = LookupResult(matched: "あめ", entries: [
            entry(keb: "飴", reb: "あめ", seq: 1),
            entry(keb: "雨", reb: "あめ", seq: 2)
        ])
        let content = LookupAnswer.found(result: joined, also: [], origin: .join)
        let favorites = FavoriteIdentity(keys: [FavoriteIdentity.normalize("雨")])
        let presentation = LookupPresentation(content: content, entryIndex: 1, anchor: .liveStrip)

        let promoted = try #require(presentation.promoting(joined, favorites: favorites))

        guard case let .found(result, _, origin) = promoted.content else {
            Issue.record("expected found content")
            return
        }
        #expect(origin == .join)
        #expect(result.entries.map(\.entSeq) == [2, 1])
        #expect(promoted.entryIndex == 0)
        #expect(
            presentation.promoting(joined, favorites: .empty) == nil,
            "a promotion that changes nothing is a no-op"
        )
    }

    @Test("a cross-pill round trip drops the join origin")
    func crossPillRoundTripDropsJoinOrigin() throws {
        let joined = result(["お土産"])
        let single = result(["お"])
        let content = LookupAnswer.found(result: joined, also: [single], origin: .join)
        let presentation = LookupPresentation(content: content, entryIndex: 0, anchor: .liveStrip)

        let moved = try #require(presentation.promoting(single, favorites: .empty))
        let back = try #require(moved.promoting(joined, favorites: .empty))

        #expect(moved.content == .found(
            result: single, also: [joined], origin: .tappedSurface
        ))
        #expect(back.content == .found(
            result: joined, also: [single], origin: .tappedSurface
        ))
    }

    @Test("a foreign fallback result fails closed")
    func foreignResultFailsClosed() {
        let presentation = LookupPresentation(
            content: .found(
                result: result(["お"]), also: [result(["お土産"])], origin: .tappedSurface
            ),
            entryIndex: 0,
            anchor: .liveStrip
        )

        let promoted = presentation.promoting(result(["foreign"]), favorites: .empty)

        #expect(promoted == nil)
    }

    // MARK: - Pager

    @Test(
        "the pager steps and clamps at both ends",
        arguments: [(target: 1, expected: 1), (target: 99, expected: 1), (target: -5, expected: 0)]
    )
    func pagerStepsAndClamps(target: Int, expected: Int) {
        var presentation = LookupPresentation(
            content: twoEntryFound(), entryIndex: 0, anchor: .liveStrip
        )

        presentation.stepEntry(to: target)

        #expect(presentation.entryIndex == expected)
    }

    @Test("the pager is inert without display entries")
    func pagerInertWithoutEntries() {
        var notFound = LookupPresentation(
            content: .notFound(surface: "雨尾", related: [result(["雨"])]),
            entryIndex: 0,
            anchor: .liveStrip
        )
        var empty = LookupPresentation(
            content: .found(
                result: LookupResult(matched: "無", entries: []),
                also: [], origin: .tappedSurface
            ),
            entryIndex: 0,
            anchor: .liveStrip
        )

        notFound.stepEntry(to: 42)
        empty.stepEntry(to: 42)

        #expect(notFound.entryIndex == 0)
        #expect(empty.entryIndex == 0)
    }

    // MARK: - Identity and anchor

    @Test("the presentation identity survives paging and tracks the matched content")
    func identitySurvivesPaging() {
        let anchor = LookupAnchor.transcript(sentenceIndex: 1, tokenIndex: 2)
        var presentation = LookupPresentation(
            content: twoEntryFound(), entryIndex: 0, anchor: anchor
        )
        let id = presentation.id

        presentation.stepEntry(to: 1)

        #expect(id.hasPrefix("transcript(sentenceIndex: 1, tokenIndex: 2)-"))
        #expect(id.hasSuffix("-飴"))
        #expect(presentation.id == id)

        // Identity is keyed on the matched token: a different match changes it.
        let replacement = LookupPresentation.initial(
            content: .found(result: result(["あめ"]), also: [], origin: .tappedSurface),
            entryIndex: 0,
            anchor: anchor
        )
        #expect(replacement.id != id)

        let notFound = LookupPresentation(
            content: .notFound(surface: "雨尾", related: [result(["雨"])]),
            entryIndex: 0,
            anchor: .liveStrip
        )
        #expect(notFound.id.hasSuffix("-not-found:雨尾"))
    }

    @Test("the popover item matches only its own anchor")
    func popoverItemMatchesOnlyItsAnchor() {
        let word = LookupAnchor.transcript(sentenceIndex: 2, tokenIndex: 1)
        let transcript = LookupPresentation(
            content: twoEntryFound(), entryIndex: 0, anchor: word
        )

        #expect(transcript.popoverItem(for: word) == transcript)
        #expect(transcript.popoverItem(for: .transcript(sentenceIndex: 1, tokenIndex: 1)) == nil)
        #expect(transcript.popoverItem(for: .transcript(sentenceIndex: 2, tokenIndex: 0)) == nil)
        #expect(transcript.popoverItem(for: .liveStrip) == nil)

        let live = LookupPresentation(content: twoEntryFound(), entryIndex: 0, anchor: .liveStrip)

        #expect(live.popoverItem(for: .liveStrip) == live)
        #expect(live.popoverItem(for: word) == nil)

        let dismissed = LookupPresentation(content: twoEntryFound(), entryIndex: 1, anchor: nil)

        #expect(dismissed.popoverItem(for: .liveStrip) == nil)
        #expect(dismissed.popoverItem(for: word) == nil)
    }

    // MARK: - Initial and dismissal

    @Test(
        "initial clamps the entry index into the display entries",
        arguments: [(requested: 1, expected: 1), (requested: 99, expected: 1), (requested: -4, expected: 0)]
    )
    func initialClampsEntryIndex(requested: Int, expected: Int) {
        let presentation = LookupPresentation.initial(
            content: twoEntryFound(), entryIndex: requested, anchor: .liveStrip
        )

        #expect(presentation.entryIndex == expected)
    }

    @Test("initial opens at zero without display entries")
    func initialWithoutDisplayEntries() {
        let notFound = LookupPresentation.initial(
            content: .notFound(surface: "雨尾", related: [result(["雨"])]),
            entryIndex: 9,
            anchor: .liveStrip
        )
        let empty = LookupPresentation.initial(
            content: .found(
                result: LookupResult(matched: "無", entries: []),
                also: [], origin: .tappedSurface
            ),
            entryIndex: 4,
            anchor: .liveStrip
        )

        #expect(notFound.entryIndex == 0)
        #expect(empty.entryIndex == 0)
    }

    @Test("a dismissed presentation keeps its content and entry, and promotion keeps it dismissed")
    func dismissedPresentationKeepsContentAndEntry() throws {
        let content = LookupAnswer.found(
            result: result(["お", "御"]), also: [result(["お土産"])], origin: .tappedSurface
        )
        let presentation = LookupPresentation(content: content, entryIndex: 1, anchor: nil)

        let promoted = try #require(presentation.promoting(result(["お土産"]), favorites: .empty))

        #expect(presentation.id.hasPrefix("pinned-"))
        #expect(presentation.content == content)
        #expect(presentation.entryIndex == 1)
        #expect(promoted.content.displayResult?.matched == "お土産")
        #expect(promoted.entryIndex == 0)
        #expect(promoted.anchor == nil)
    }

    // MARK: - What may be stored

    /// Hands out one answer per landing, in order, so a test can pin first and
    /// then throw verdicts at the session.
    private actor SequenceResolver: TapLookupResolving {
        private var answers: [LookupAnswer?]

        init(_ answers: [LookupAnswer?]) {
            self.answers = answers
        }

        func resolve(
            _ request: TapLookupRequest, favorites: FavoriteIdentity
        ) async -> LookupAnswer? {
            guard !answers.isEmpty else { return nil }
            return answers.removeFirst()
        }
    }

    private func tapRequest(_ surface: String) -> TapLookupRequest {
        TapLookupRequest(
            segments: [LookupSegment(surface: surface)],
            tappedAt: 0,
            sentenceText: surface,
            surface: surface
        )
    }

    @Test("a bare miss, a failure, or a dropped answer never sets a presentation")
    @MainActor
    func unpinnableAnswersNeverSetPresentation() async {
        let verdicts: [LookupAnswer?] = [
            LookupAnswer.noHit(surface: "xyz"),
            LookupAnswer.failure(.databaseMissing),
            nil
        ]

        for verdict in verdicts {
            let session = TapLookupSession(resolver: SequenceResolver([verdict]))
            let task = session.tap(
                tapRequest("xyz"), anchor: .liveStrip, favorites: .empty
            )
            await task.value

            #expect(session.presentation == nil)
        }
    }

    @Test("a bare miss, a failure, or a dropped answer leaves a pin unchanged")
    @MainActor
    func unpinnableAnswersLeaveAPinUnchanged() async throws {
        let pinned = LookupAnswer.found(
            result: result(["飴", "雨"]), also: [], origin: .tappedSurface
        )
        let firstLanding: LookupAnswer? = pinned
        let verdicts: [LookupAnswer?] = [
            LookupAnswer.noHit(surface: "xyz"),
            LookupAnswer.failure(.databaseMissing),
            nil
        ]
        let session = TapLookupSession(resolver: SequenceResolver([firstLanding] + verdicts))

        let pinning = session.tap(
            tapRequest("あめ"), anchor: .liveStrip, favorites: .empty
        )
        await pinning.value
        let shown = try #require(session.presentation)

        for _ in verdicts {
            let task = session.tap(
                tapRequest("xyz"), anchor: .transcript(sentenceIndex: 3, tokenIndex: 0),
                favorites: .empty
            )
            await task.value
        }

        #expect(session.presentation == shown)
        #expect(session.presentation?.content == pinned)
        #expect(session.presentation?.entryIndex == 0)
    }
}
