import Foundation
@testable import Mimidasu
import Testing

/// Tests the star's *outcomes* — which notice pill or toast each toggle
/// result earns, and how membership is derived from the displayed entry.
/// The store's own matching, ordering, and cap live in `FavoritesStoreTests`.
@MainActor
@Suite("AppModel favorites")
struct AppModelFavoritesTests {

    // MARK: - Fixtures

    private func makeSUT(favorites: FavoritesStore) async -> AppModel {
        let model = AppModel(
            translationSettings: isolatedTranslationSettings(suite: "test.AppModelFavorites"),
            asrModelSettings: isolatedASRModelSettings(suite: "test.AppModelFavorites"),
            favorites: favorites,
            highFidelityProbe: { _ in false },
            initialModelResolve: { _ in nil }
        )
        await model.initialModelCheck?.value
        return model
    }

    private func entry(
        entSeq: Int = 1, keb: String? = "見る", reb: String? = "みる"
    ) -> JMDictEntry {
        JMDictEntry(
            entSeq: entSeq, keb: keb, reb: reb, common: true, jlpt: nil,
            hatsuon: nil, accPatts: nil, zoPatts: nil, senses: []
        )
    }

    /// A store whose file cannot be opened: the location's parent is a regular
    /// file, so creating the directory fails and every operation degrades.
    private func degradedStore() -> FavoritesStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mimidasu-favorites-degraded-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: root.path, contents: Data())
        return FavoritesStore(location: root.appendingPathComponent("favorites.sqlite"))
    }

    private func segment(
        _ surface: String, lemma: String? = nil
    ) -> ReadingSegment {
        ReadingSegment(surface: surface, romaji: surface, lemma: lemma)
    }

    // MARK: - Outcomes

    @Test("starring an entry adds its headword and posts the confirm pill")
    func starAddsAndConfirms() async {
        let model = await makeSUT(favorites: isolatedFavorites())

        let outcome = model.toggleFavorite(entry())

        #expect(outcome == .added && model.notices.message == "Added to favorites")
    }

    @Test("un-starring asks first, naming the headword, and changes nothing")
    func unstarAsksFirst() async {
        let model = await makeSUT(favorites: isolatedFavorites())
        model.toggleFavorite(entry())

        let outcome = model.toggleFavorite(entry())

        #expect(outcome == .pendingRemoval(headword: "見る") && model.isFavorite(entry()))
    }

    @Test("a question left unanswered leaves the list untouched")
    func unansweredQuestionKeepsWord() async {
        let model = await makeSUT(favorites: isolatedFavorites())
        model.toggleFavorite(entry())
        model.toggleFavorite(entry())

        #expect(model.favorites.count == 1)
    }

    @Test("confirming removes the word and stays silent — the alert already said so")
    func confirmingRemovesSilently() async {
        let model = await makeSUT(favorites: isolatedFavorites())
        model.toggleFavorite(entry())
        model.notices.dismiss()

        model.confirmFavoriteRemoval(headword: "見る")

        #expect(!model.isFavorite(entry()) && model.notices.message == nil)
    }

    @Test("confirming a word that is not a favorite is a no-op")
    func confirmingAbsentWordIsNoOp() async {
        let model = await makeSUT(favorites: isolatedFavorites())
        model.toggleFavorite(entry())

        model.confirmFavoriteRemoval(headword: "食べる")

        #expect(model.favorites.count == 1)
    }

    @Test("nothing is stashed on the model while a question is open")
    func pendingQuestionIsNotModelState() async {
        let model = await makeSUT(favorites: isolatedFavorites())
        model.toggleFavorite(entry())

        model.toggleFavorite(entry())

        // The host owns the pending headword; a model-level flag would be
        // observed by every mounted host and raise an alert in each.
        #expect(model.favorites.words.map(\.headword) == ["見る"])
    }

    @Test("a store that cannot be opened posts the persistent favorites toast")
    func degradedStoreToasts() async {
        let model = await makeSUT(favorites: degradedStore())

        let outcome = model.toggleFavorite(entry())

        #expect(outcome == .failed && model.toasts.toasts.first?.key == ToastKey.favorites)
    }

    @Test("a full list is refused with the warning pill, never by evicting")
    func fullListWarns() async {
        let store = isolatedFavorites()
        for index in 0 ..< FavoritesStore.limit {
            store.toggle(FavoriteWord(
                headword: "語\(index)", reading: nil, romaji: nil, addedAt: index
            ))
        }
        let model = await makeSUT(favorites: store)

        let outcome = model.toggleFavorite(entry())

        #expect(outcome == .limitReached && model.notices.tone == .warning)
    }

    // MARK: - Membership

    @Test("membership follows the entry's headword, kanji spelling included")
    func membershipFollowsHeadword() async {
        let model = await makeSUT(favorites: isolatedFavorites())
        model.toggleFavorite(entry())

        #expect(model.isFavorite(entry()))
    }

    @Test("a homograph with the same kanji spelling shows the same filled star")
    func homographsShareOneStar() async {
        let model = await makeSUT(favorites: isolatedFavorites())
        model.toggleFavorite(entry(entSeq: 1))

        #expect(model.isFavorite(entry(entSeq: 2)))
    }

    @Test("a sibling homograph's star asks about the one shared row, and confirming clears it")
    func homographToggleAsksAboutSharedRow() async {
        let model = await makeSUT(favorites: isolatedFavorites())
        model.toggleFavorite(entry(entSeq: 1))
        model.toggleFavorite(entry(entSeq: 2))

        model.confirmFavoriteRemoval(headword: "見る")

        #expect(!model.isFavorite(entry(entSeq: 1)))
    }

    @Test("a kana-only entry is keyed on its reading")
    func kanaOnlyEntryUsesReading() async {
        let model = await makeSUT(favorites: isolatedFavorites())

        let outcome = model.toggleFavorite(entry(keb: nil, reb: "コーヒー"))

        #expect(outcome == .added && model.favorites.words.map(\.headword) == ["コーヒー"])
    }

    @Test("the render matcher lights up an inflected form of a starred word")
    func matcherCoversInflections() async {
        let model = await makeSUT(favorites: isolatedFavorites())
        model.toggleFavorite(entry())

        #expect(model.favoriteSegmentMatcher(segment("見ました", lemma: "見る")))
    }

    @Test("the render matcher leaves an unrelated word alone")
    func matcherIgnoresUnrelated() async {
        let model = await makeSUT(favorites: isolatedFavorites())
        model.toggleFavorite(entry())

        #expect(!model.favoriteSegmentMatcher(segment("食べる", lemma: "食べる")))
    }
}
