import Foundation
@testable import Mimidasu
import Testing

/// Seam tests for the Lookup Display module: tap-to-verdict cases (found,
/// join-lead, lemma-lead, split-only demotion, favorites on not-found, bare
/// miss, no hit), drift fail-closed, pill re-promotion purity, pager
/// clamping, and the fault map. Every test asserts observable outcomes
/// through the module interface — pinned Display, Also/Related ordering,
/// warning surface, fault — over the fixture database, without constructing
/// app state. Three suites share this harness — this file holds the core
/// tap-to-verdict one (the out-of-bounds and duplicate-surface tap
/// resolutions live in the pills/pager file); the fault map and the
/// pills/pager live in their own files — so no suite body or file trips
/// the length gates.
struct ResolutionMismatch: Error {}

final class LookupDisplayHarness {
    let fixture: JMDictFixtureDatabase.Built

    init() throws {
        fixture = try JMDictFixtureDatabase.build()
    }

    deinit {
        fixture.remove()
    }

    func makeDisplay(resolveDatabase: (@Sendable () -> URL?)? = nil) -> LookupDisplay {
        let url = fixture.url
        let engine = JMDictLookup(resolveDatabase: resolveDatabase ?? { [url] in url })
        return LookupDisplay(lookup: engine)
    }

    /// お in お土産: the tapped surface お leads, then the forward join
    /// お土産 — both hit in the fixture.
    func requestO() -> TapLookupRequest {
        TapLookupRequest(
            segments: [
                LookupSegment(surface: "お"),
                LookupSegment(surface: "土産", lemma: "土産")
            ],
            tappedAt: 0,
            sentenceText: "お土産",
            surface: "お"
        )
    }

    /// A single kana segment resolving to the あめ homograph pair.
    func requestAme() -> TapLookupRequest {
        TapLookupRequest(segments: [LookupSegment(surface: "あめ")], tappedAt: 0, sentenceText: "あめ", surface: "あめ")
    }

    func shownContent(
        for request: TapLookupRequest, favorites: FavoriteIdentity = .empty
    ) async throws -> LookupContent {
        let effect = await makeDisplay().resolve(request, favorites: favorites)
        guard case let .show(content, _) = effect else {
            throw ResolutionMismatch()
        }
        return content
    }

    func entry(_ headword: String, seq: Int) -> JMDictEntry {
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

    /// A kana-shared entry: a kanji writing paired with its reading, for
    /// the pill suite's hand-built homograph results that exercise the
    /// written-or-read promotion rule.
    func entry(keb: String, reb: String, seq: Int) -> JMDictEntry {
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

    /// A hand-built fallback hit: one entry per headword, dictionary-ranked
    /// as given (the fixture's multi-entry hits never relabel a fallback
    /// pill — they are display results or same-headword homographs).
    func result(_ headwords: [String]) -> LookupResult {
        LookupResult(
            matched: headwords[0],
            entries: headwords.enumerated().map { index, headword in
                entry(headword, seq: index + 1)
            }
        )
    }
}

@Suite("LookupDisplay")
final class LookupDisplayTests {
    private let harness: LookupDisplayHarness

    init() throws {
        harness = try LookupDisplayHarness()
    }

    @Test("a found tap shows the display with its also hits from the first entry")
    func foundTapShowsDisplayWithAlso() async {
        let display = harness.makeDisplay()

        let effect = await display.resolve(harness.requestO(), favorites: .empty)

        guard case let .show(content, entryIndex) = effect else {
            Issue.record("expected show, got \(effect)")
            return
        }
        #expect(entryIndex == 0)
        #expect(content.displayResult?.matched == "お")
        #expect(content.fallbackResults.map(\.matched) == ["お土産"])
        guard case let .found(_, _, origin) = content else {
            Issue.record("expected found content")
            return
        }
        #expect(origin == .tappedSurface)
    }

    @Test("a join lead shows the compound as found with the join origin")
    func joinLeadShowsJoinedMatch() async {
        let display = harness.makeDisplay()
        let request = TapLookupRequest(
            segments: [
                LookupSegment(surface: "お土"),
                LookupSegment(surface: "産", lemma: "産")
            ],
            tappedAt: 0,
            sentenceText: "お土産",
            surface: "お土"
        )

        let effect = await display.resolve(request, favorites: .empty)

        guard case let .show(content, entryIndex) = effect else {
            Issue.record("expected show, got \(effect)")
            return
        }
        #expect(entryIndex == 0)
        #expect(content.displayResult?.matched == "お土産")
        guard case let .found(_, _, origin) = content else {
            Issue.record("expected found content")
            return
        }
        #expect(origin == .join)
    }

    @Test("a lemma hit resolves with the tapped-lemma origin")
    func tappedLemmaResolvesWithLemmaOrigin() async {
        let display = harness.makeDisplay()
        let request = TapLookupRequest(
            segments: [LookupSegment(surface: "食べた", lemma: "食べる")],
            tappedAt: 0,
            sentenceText: "食べた",
            surface: "食べた"
        )

        let effect = await display.resolve(request, favorites: .empty)

        guard case let .show(content, entryIndex) = effect else {
            Issue.record("expected show, got \(effect)")
            return
        }
        #expect(entryIndex == 0)
        #expect(content.displayResult?.matched == "食べる")
        guard case let .found(_, _, origin) = content else {
            Issue.record("expected found content")
            return
        }
        #expect(origin == .tappedLemma)
    }

    @Test("a lemma tap leads on the starred dictionary form")
    func lemmaTapPromotesStarredDictionaryForm() async {
        let display = harness.makeDisplay()
        let request = TapLookupRequest(
            segments: [LookupSegment(surface: "食べた", lemma: "食べる")],
            tappedAt: 0,
            sentenceText: "食べた",
            surface: "食べた"
        )
        let favorites = FavoriteIdentity(keys: [FavoriteIdentity.normalize("食べる")])

        let effect = await display.resolve(request, favorites: favorites)

        guard case let .show(content, entryIndex) = effect,
              case let .found(result, _, origin) = content
        else {
            Issue.record("expected found show, got \(effect)")
            return
        }
        #expect(entryIndex == 0)
        #expect(origin == .tappedLemma)
        #expect(result.matched == "食べる")
        #expect(result.entries.first?.keb == "食べる")
        #expect(favorites.leads(result))
    }

    @Test("a split-only tap shows not-found with the splits demoted to related")
    func splitOnlyDemotesToRelated() async {
        let display = harness.makeDisplay()
        let request = TapLookupRequest(
            segments: [LookupSegment(surface: "雨尾")],
            tappedAt: 0,
            sentenceText: "雨尾",
            surface: "雨尾"
        )

        let effect = await display.resolve(request, favorites: .empty)

        guard case let .show(content, entryIndex) = effect else {
            Issue.record("expected show, got \(effect)")
            return
        }
        #expect(entryIndex == 0)
        guard case let .notFound(surface, related) = content else {
            Issue.record("expected not-found content, got \(content)")
            return
        }
        #expect(surface == "雨尾")
        #expect(related.map(\.matched) == ["雨", "尾"])
    }

    @Test("favorites leave a not-found resolution unpromoted")
    func favoritesLeaveNotFoundUnpromoted() async {
        let display = harness.makeDisplay()
        let request = TapLookupRequest(
            segments: [LookupSegment(surface: "雨尾")],
            tappedAt: 0,
            sentenceText: "雨尾",
            surface: "雨尾"
        )

        let plain = await display.resolve(request, favorites: .empty)
        let favorited = await display.resolve(
            request, favorites: FavoriteIdentity(keys: [FavoriteIdentity.normalize("雨")])
        )

        guard case let .show(plainContent, _) = plain,
              case let .show(favoritedContent, _) = favorited
        else {
            Issue.record("expected show, got \(plain) / \(favorited)")
            return
        }
        guard case let .notFound(_, plainRelated) = plainContent,
              case let .notFound(surface, related) = favoritedContent
        else {
            Issue.record("expected not-found content")
            return
        }
        #expect(surface == "雨尾")
        #expect(related.map(\.matched) == ["雨", "尾"])
        #expect(related == plainRelated)
    }

    @Test("a related pill does not hoist a favorite matched through an alternate writing")
    func notFoundRelatedDoesNotHoistAlternateWritingFavorite() async {
        // 前无 misses, so its 前 split is demoted to related. The favorite 先
        // entry 9990050 reaches that result only through its alternate
        // writing 前 — not through the writing it is starred by — so
        // promotion leaves the surface match 9990060 (前/まえ) leading and
        // the starred entry present behind it. Related results are always
        // kanji-split results, so this negative arm is the whole resolve-
        // level story: every eligible favorite there already leads (uniform
        // keys), and every buried favorite is ineligible by this rule.
        let request = TapLookupRequest(
            segments: [LookupSegment(surface: "前无")],
            tappedAt: 0,
            sentenceText: "前无",
            surface: "前无"
        )
        let favorites = FavoriteIdentity(keys: [FavoriteIdentity.normalize("先")])
        let effect = await harness.makeDisplay().resolve(request, favorites: favorites)
        guard case let .show(content, _) = effect,
              case let .notFound(surface, related) = content
        else {
            Issue.record("expected not-found show, got \(effect)")
            return
        }
        #expect(surface == "前无")
        #expect(related.first?.matched == "前")
        #expect(related.first?.entries.first?.keb == "前")
        #expect(related.first?.entries.map(\.entSeq) == [9_990_060, 9_990_050])
        #expect(content.displayResult == nil)
    }

    @Test("a word nothing resolves warns with the tapped surface")
    func unknownWordWarns() async {
        let display = harness.makeDisplay()
        let request = TapLookupRequest(
            segments: [LookupSegment(surface: "xyz")],
            tappedAt: 0,
            sentenceText: "xyz",
            surface: "xyz"
        )

        let effect = await display.resolve(request, favorites: .empty)

        #expect(effect == .warnNoHit(surface: "xyz"))
    }

    @Test("a drifted tap fails closed to the warning pill")
    func driftedTapFailsClosed() async {
        let display = harness.makeDisplay()
        let request = TapLookupRequest(
            segments: [
                LookupSegment(surface: "お"),
                LookupSegment(surface: "土産", lemma: "土産")
            ],
            tappedAt: 0,
            sentenceText: "お土産",
            surface: "xyz"
        )

        let effect = await display.resolve(request, favorites: .empty)

        #expect(effect == .warnNoHit(surface: "xyz"))
    }

    @Test("a sentence-drifted tap suppresses joins but keeps singles")
    func sentenceDriftSuppressesJoins() async {
        let display = harness.makeDisplay()
        let request = TapLookupRequest(
            segments: [
                LookupSegment(surface: "お"),
                LookupSegment(surface: "土産", lemma: "土産")
            ],
            tappedAt: 0,
            sentenceText: "お 茶 土産",
            surface: "お"
        )

        let effect = await display.resolve(request, favorites: .empty)

        guard case let .show(content, _) = effect else {
            Issue.record("expected show, got \(effect)")
            return
        }
        #expect(content.displayResult?.matched == "お")
        #expect(content.fallbackResults.isEmpty)
    }

    @Test("a favorited entry leads the pager, so あめ opens 雨 rather than 飴")
    func favoriteLeadsPager() async {
        let display = harness.makeDisplay()
        let request = harness.requestAme()

        let effect = await display.resolve(
            request, favorites: FavoriteIdentity(keys: [FavoriteIdentity.normalize("雨")])
        )

        guard case let .show(content, entryIndex) = effect else {
            Issue.record("expected show, got \(effect)")
            return
        }
        #expect(entryIndex == 0)
        #expect(content.displayResult?.entries.first?.keb == "雨")
    }
}
