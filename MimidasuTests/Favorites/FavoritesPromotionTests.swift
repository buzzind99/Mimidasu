import Foundation
@testable import Mimidasu
import Testing

struct PromotionEntrySpec: Sendable {
    let keb: String?
    let reb: String?
    let seq: Int
}

/// One promotion-table row: the resolved result, the starred headwords, and
/// the order the promotion must produce.
struct PromotionCase: Sendable {
    let matched: String
    let entries: [PromotionEntrySpec]
    let favorites: [String]
    let expectedEntSeqs: [Int]
    let expectedKebs: [String]
    let expectedLeadKeb: String
}

private let promotePromotionCases: [PromotionCase] = [
    PromotionCase(
        matched: "ほう",
        entries: [
            PromotionEntrySpec(keb: "方", reb: "ほう", seq: 1),
            PromotionEntrySpec(keb: "報", reb: "ほう", seq: 2)
        ],
        favorites: ["報"],
        expectedEntSeqs: [2, 1],
        expectedKebs: ["報", "方"],
        expectedLeadKeb: "報"
    ),
    PromotionCase(
        matched: "ほう",
        entries: [
            PromotionEntrySpec(keb: "方", reb: "ほう", seq: 1),
            PromotionEntrySpec(keb: "報", reb: "ほう", seq: 2),
            PromotionEntrySpec(keb: "法", reb: "ほう", seq: 3)
        ],
        favorites: ["報"],
        expectedEntSeqs: [2, 1, 3],
        expectedKebs: ["報", "方", "法"],
        expectedLeadKeb: "報"
    )
]

private let noOpPromotionCases: [PromotionCase] = [
    PromotionCase(
        matched: "方",
        entries: [
            PromotionEntrySpec(keb: "方", reb: "ほう", seq: 1),
            PromotionEntrySpec(keb: "辺", reb: "へ", seq: 2)
        ],
        favorites: ["辺"],
        expectedEntSeqs: [1, 2],
        expectedKebs: ["方", "辺"],
        expectedLeadKeb: "方"
    ),
    PromotionCase(
        matched: "方",
        entries: [
            PromotionEntrySpec(keb: "方", reb: "ほう", seq: 1),
            PromotionEntrySpec(keb: "方", reb: "かた", seq: 2)
        ],
        favorites: ["方"],
        expectedEntSeqs: [1, 2],
        expectedKebs: ["方", "方"],
        expectedLeadKeb: "方"
    ),
    PromotionCase(
        matched: "使う",
        entries: [PromotionEntrySpec(keb: "使う", reb: "つかう", seq: 1)],
        favorites: ["使う"],
        expectedEntSeqs: [1],
        expectedKebs: ["使う"],
        expectedLeadKeb: "使う"
    ),
    PromotionCase(
        matched: "ほう",
        entries: [
            PromotionEntrySpec(keb: "方", reb: "ほう", seq: 1),
            PromotionEntrySpec(keb: "報", reb: "ほう", seq: 2)
        ],
        favorites: ["見る"],
        expectedEntSeqs: [1, 2],
        expectedKebs: ["方", "報"],
        expectedLeadKeb: "方"
    ),
    PromotionCase(
        matched: "ほう",
        entries: [
            PromotionEntrySpec(keb: "報", reb: "ほう", seq: 1),
            PromotionEntrySpec(keb: "方", reb: "ほう", seq: 2)
        ],
        favorites: ["報"],
        expectedEntSeqs: [1, 2],
        expectedKebs: ["報", "方"],
        expectedLeadKeb: "報"
    )
]

/// The rule that makes a favorited entry lead the dictionary pager: pure
/// reordering of an already-resolved lookup, with no store and no database.
/// Promotion admits only entries that carry the matched text as a writing or
/// a reading — a starred kana-shared reading leads, a starred sibling
/// spelling the engine matched through some other writing never does — and
/// everything else — the display result's identity, the fallback set itself,
/// the origin label, and the not-found state — must come through unchanged,
/// or the popover starts answering a question nobody asked.
@Suite("FavoritesPromotion")
struct FavoritesPromotionTests {

    private func entry(keb: String?, reb: String?, seq: Int = 1) -> JMDictEntry {
        JMDictEntry(
            entSeq: seq,
            keb: keb,
            reb: reb,
            common: false,
            jlpt: nil,
            hatsuon: nil,
            accPatts: nil,
            zoPatts: nil,
            senses: [JMDictSense(pos: nil, glosses: ["gloss"], misc: nil,
                                 restrictedKanji: nil, restrictedKana: nil)]
        )
    }

    private func identity(_ headwords: String...) -> FavoriteIdentity {
        FavoriteIdentity(keys: Set(headwords.map(FavoriteIdentity.normalize)))
    }

    private func result(for testCase: PromotionCase) -> LookupResult {
        LookupResult(
            matched: testCase.matched,
            entries: testCase.entries.map { spec in
                entry(keb: spec.keb, reb: spec.reb, seq: spec.seq)
            }
        )
    }

    private func favoriteIdentity(_ headwords: [String]) -> FavoriteIdentity {
        FavoriteIdentity(keys: Set(headwords.map(FavoriteIdentity.normalize)))
    }

    @Test(
        "a favorite leads while the surrounding order and matched text survive",
        arguments: promotePromotionCases
    )
    func promotesFavoriteEntry(testCase: PromotionCase) {
        let promoted = FavoritesPromotion.promotingFavorites(
            in: result(for: testCase), identity: favoriteIdentity(testCase.favorites)
        )

        #expect(promoted.entries.map(\.entSeq) == testCase.expectedEntSeqs)
        #expect(promoted.entries.map(\.keb) == testCase.expectedKebs)
        #expect(promoted.entries.first?.keb == testCase.expectedLeadKeb)
        #expect(promoted.matched == testCase.matched)
    }

    @Test("a halfwidth-katakana matched text folds onto the favorite's reading")
    func foldsHalfwidthMatchedText() {
        let promoted = FavoritesPromotion.promotingFavorites(
            in: LookupResult(matched: "ﾎｳ", entries: [
                entry(keb: "方", reb: "ほう", seq: 1),
                entry(keb: "報", reb: "ほう", seq: 2)
            ]),
            identity: identity("報")
        )

        #expect(promoted.entries.map(\.entSeq) == [2, 1])
    }

    @Test(
        "a result with no eligible favorite comes back untouched",
        arguments: noOpPromotionCases
    )
    func leavesUnfavoritedOrLeadingResultAlone(testCase: PromotionCase) {
        let original = result(for: testCase)

        let promoted = FavoritesPromotion.promotingFavorites(
            in: original, identity: favoriteIdentity(testCase.favorites)
        )

        #expect(promoted == original)
        #expect(promoted.entries.map(\.entSeq) == testCase.expectedEntSeqs)
        #expect(promoted.entries.map(\.keb) == testCase.expectedKebs)
        #expect(promoted.entries.first?.keb == testCase.expectedLeadKeb)
    }

    @Test("the first eligible favorite wins the front")
    func firstEligibleFavoriteWins() {
        let promoted = FavoritesPromotion.promotingFavorites(
            in: LookupResult(matched: "あめ", entries: [
                entry(keb: "飴", reb: "あめ", seq: 1),
                entry(keb: "雨", reb: "あめ", seq: 2),
                entry(keb: "別", reb: "あめ", seq: 3)
            ]),
            identity: identity("雨", "別")
        )

        #expect(promoted.entries.map(\.entSeq) == [2, 1, 3])
    }

    @Test("a favorite inside a demoted also: hit leads that pill's pager")
    func promotesFavoriteInsideAlsoHits() throws {
        let display = LookupResult(matched: "あめ", entries: [
            entry(keb: "飴", reb: "あめ", seq: 1),
            entry(keb: "雨", reb: "あめ", seq: 2)
        ])
        let favoritePill = LookupResult(matched: "ほう", entries: [
            entry(keb: "方", reb: "ほう", seq: 3),
            entry(keb: "報", reb: "ほう", seq: 4)
        ])
        let siblingPill = LookupResult(matched: "方", entries: [
            entry(keb: "方", reb: "ほう", seq: 5),
            entry(keb: "辺", reb: "へ", seq: 6)
        ])
        let plainPill = LookupResult(matched: "ほ", entries: [
            entry(keb: "穂", reb: "ほ", seq: 7)
        ])
        let content = LookupContent.found(
            result: display, also: [favoritePill, siblingPill, plainPill],
            origin: .tappedSurface
        )

        let promoted = FavoritesPromotion.promotingFavorites(
            in: content, identity: identity("報", "辺")
        )

        guard case let .found(displayResult, also, _) = promoted else {
            Issue.record("a found content stopped being found")
            return
        }
        #expect(displayResult == display, "the display result is untouched")
        #expect(also.map(\.matched) == ["ほう", "方", "ほ"], "matched text survives")
        // The favorite leads its own pill's pager — its own entry moves, not
        // a copy; a sibling-spelling pill stays engine-ranked, and the
        // favorite-free pill keeps its ranking.
        let promotedPill = try #require(also.first)
        let siblingResult = try #require(also.dropFirst().first)
        let plainResult = try #require(also.dropFirst(2).first)
        #expect(promotedPill.entries.map(\.entSeq) == [4, 3])
        #expect(siblingResult.entries.map(\.entSeq) == [5, 6])
        #expect(plainResult.entries.map(\.entSeq) == [7])
    }

    @Test("also: hits without an eligible favorite come through unchanged")
    func leavesUnfavoritedAlsoHitsAlone() {
        let content = LookupContent.found(
            result: LookupResult(matched: "あめ", entries: [
                entry(keb: "飴", reb: "あめ", seq: 1),
                entry(keb: "雨", reb: "あめ", seq: 2)
            ]),
            also: [
                LookupResult(matched: "ほう", entries: [
                    entry(keb: "方", reb: "ほう", seq: 3),
                    entry(keb: "報", reb: "ほう", seq: 4)
                ]),
                LookupResult(matched: "方", entries: [
                    entry(keb: "方", reb: "ほう", seq: 5),
                    entry(keb: "辺", reb: "へ", seq: 6)
                ])
            ],
            origin: .tappedSurface
        )

        // The starred 辺 is present in the sibling pill but matched through
        // its own spelling (keb 辺, reb へ, matched 方), so it must stay put;
        // no other entry carries a favorite.
        let promoted = FavoritesPromotion.promotingFavorites(
            in: content, identity: identity("辺")
        )

        #expect(promoted == content, "the ineligible sibling favorite stays engine-ranked")
    }

    @Test("the origin the display result came from is carried through")
    func keepsDisplayOrigin() {
        let content = LookupContent.found(
            result: LookupResult(matched: "ほう", entries: [
                entry(keb: "方", reb: "ほう", seq: 1),
                entry(keb: "報", reb: "ほう", seq: 2)
            ]),
            also: [], origin: .join
        )

        let promoted = FavoritesPromotion.promotingFavorites(
            in: content, identity: identity("報")
        )

        guard case let .found(display, _, origin) = promoted else {
            Issue.record("a found content stopped being found")
            return
        }
        #expect(origin == .join)
        #expect(display.entries.map(\.entSeq) == [2, 1])
    }

    @Test("a not-found pin stays not-found while its related pills promote")
    func promotesRelatedPillsWhilePinStaysNotFound() {
        let content = LookupContent.notFound(
            surface: "雨尾",
            related: [LookupResult(matched: "ほう", entries: [
                entry(keb: "方", reb: "ほう", seq: 1),
                entry(keb: "報", reb: "ほう", seq: 2)
            ])]
        )

        let promoted = FavoritesPromotion.promotingFavorites(
            in: content, identity: identity("報")
        )

        guard case let .notFound(surface, related) = promoted else {
            Issue.record("a not-found pin stopped being not-found")
            return
        }
        #expect(surface == "雨尾")
        #expect(related.map(\.matched) == ["ほう"])
        #expect(related.map { row in row.entries.map(\.entSeq) } == [[2, 1]])
    }

    @Test("a kana-only entry promotes on its reading")
    func promotesKanaOnlyEntryOnReading() {
        let kana = entry(keb: nil, reb: "みる", seq: 2)
        let original = LookupResult(matched: "みる", entries: [
            entry(keb: "見る", reb: "みる", seq: 1), kana
        ])
        let identity = FavoriteIdentity(words: [
            FavoriteWord.starred(headword: "みる", reading: "みる")
        ])

        let promoted = FavoritesPromotion.promotingFavorites(in: original, identity: identity)

        #expect(promoted.entries.map(\.entSeq) == [2, 1])
        #expect(promoted.entries.first?.reb == "みる")
    }
}
