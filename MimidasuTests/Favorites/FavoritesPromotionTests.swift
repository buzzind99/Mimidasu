import Foundation
@testable import Mimidasu
import Testing

/// The rule that makes a favorited entry lead the dictionary pager: pure
/// reordering of an already-resolved lookup, with no store and no database.
/// Both the display result and every demoted `also:` hit lead on their first
/// favorite; everything else — the display result's identity, the fallback
/// set itself, the origin label, and the not-found state — must come through
/// unchanged, or the popover starts answering a question nobody asked.
@Suite("FavoritesPromotion")
struct FavoritesPromotionTests {

    private func entry(_ headword: String, reading: String? = nil, seq: Int = 1) -> JMDictEntry {
        JMDictEntry(
            entSeq: seq,
            keb: headword,
            reb: reading ?? headword,
            common: false,
            jlpt: nil,
            hatsuon: nil,
            accPatts: nil,
            zoPatts: nil,
            senses: [JMDictSense(pos: nil, glosses: ["gloss"], misc: nil,
                                 restrictedKanji: nil, restrictedKana: nil)]
        )
    }

    private func result(_ headwords: [String]) -> LookupResult {
        LookupResult(
            matched: headwords[0],
            entries: headwords.enumerated().map { index, headword in
                entry(headword, seq: index + 1)
            }
        )
    }

    private var keys: Set<String> {
        [FavoriteWord.normalize("見る")]
    }

    @Test("a favorite later in the list leads the pager")
    func promotesFavoriteEntry() {
        let promoted = FavoritesPromotion.promotingFavorites(
            in: result(["箸", "匙", "見る"]), keys: keys
        )

        #expect(promoted.entries.map { entry in entry.keb } == ["見る", "箸", "匙"])
    }

    @Test("the other entries keep the order the dictionary ranked them in")
    func promotionKeepsSurroundingOrder() {
        let promoted = FavoritesPromotion.promotingFavorites(
            in: result(["箸", "見る", "匙"]), keys: keys
        )

        #expect(promoted.entries.map(\.entSeq) == [2, 1, 3])
    }

    @Test("a result with no favorite comes back untouched")
    func leavesUnfavoritedResultAlone() {
        let original = result(["箸", "匙"])

        let promoted = FavoritesPromotion.promotingFavorites(in: original, keys: keys)

        #expect(promoted == original)
    }

    @Test("a favorite already leading is not moved")
    func leavesLeadingFavoriteAlone() {
        let original = result(["見る", "箸"])

        let promoted = FavoritesPromotion.promotingFavorites(in: original, keys: keys)

        #expect(promoted == original)
    }

    @Test("the matched text the tap resolved survives the promotion")
    func keepsMatchedText() {
        let promoted = FavoritesPromotion.promotingFavorites(
            in: result(["箸", "見る"]), keys: keys
        )

        #expect(promoted.matched == "箸")
    }

    @Test("a favorite inside a demoted also: hit leads that pill's pager")
    func promotesFavoriteInsideAlsoHits() {
        let content = LookupContent.found(
            result: result(["箸", "匙"]),
            also: [result(["匙", "見る"]), result(["箸"])],
            origin: .tappedSurface
        )

        let promoted = FavoritesPromotion.promotingFavorites(in: content, keys: keys)

        guard case let .found(display, also, _) = promoted else {
            Issue.record("a found content stopped being found")
            return
        }
        #expect(display == result(["箸", "匙"]), "the display result is untouched")
        #expect(also.map(\.matched) == ["匙", "箸"], "matched text survives")
        // The favorite leads its own pill's pager; the favorite-free pill
        // keeps the dictionary's ranking.
        #expect(also[0].entries.map { entry in entry.keb } == ["見る", "匙"])
        #expect(also[1].entries.map { entry in entry.keb } == ["箸"])
    }

    @Test("also: hits without a favorite come through unchanged")
    func leavesUnfavoritedAlsoHitsAlone() {
        let content = LookupContent.found(
            result: result(["箸", "匙"]),
            also: [result(["匙"]), result(["箸"])],
            origin: .tappedSurface
        )

        let promoted = FavoritesPromotion.promotingFavorites(in: content, keys: keys)

        #expect(promoted == content)
    }

    @Test("the origin the display result came from is carried through")
    func keepsDisplayOrigin() {
        let content = LookupContent.found(
            result: result(["箸", "見る"]), also: [], origin: .join
        )

        let promoted = FavoritesPromotion.promotingFavorites(in: content, keys: keys)

        guard case let .found(_, _, origin) = promoted else {
            Issue.record("a found content stopped being found")
            return
        }
        #expect(origin == .join)
    }

    @Test("a not-found pin keeps its related splits as suggestions")
    func leavesNotFoundAlone() {
        let content = LookupContent.notFound(
            surface: "雨尾", related: [result(["雨", "見る"])]
        )

        let promoted = FavoritesPromotion.promotingFavorites(in: content, keys: keys)

        #expect(promoted == content)
    }
}
