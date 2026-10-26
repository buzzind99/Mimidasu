@testable import Mimidasu
import Testing

private let headwordSpellings: [(keb: String?, reb: String?)] = [
    ("見る", "みる"),
    (nil, "みる"),
    (nil, nil),
    ("", "みる"),
    ("", nil),
    (nil, ""),
    ("", ""),
    ("見る", "")
]

private let headwordExpectations: [String?] = [
    "見る", "みる", nil, "みる", nil, nil, nil, "見る"
]

/// The Favorite identity round-trip: one starred headword lights its
/// Highlight and leads the Display. Star, Highlight, and Promotion read one
/// value — this suite pins that value's three arms together, so a fix in one
/// cannot silently unplug the others.
@Suite("FavoriteIdentity")
struct FavoriteIdentityTests {
    private func segment(
        _ surface: String, lemma: String? = nil, isBound: Bool = false
    ) -> ReadingSegment {
        ReadingSegment(surface: surface, romaji: surface, lemma: lemma, isBound: isBound)
    }

    private func entry(keb: String?, reb: String?, seq: Int = 1) -> JMDictEntry {
        JMDictEntry(
            entSeq: seq, keb: keb, reb: reb, common: false, jlpt: nil,
            hatsuon: nil, accPatts: nil, zoPatts: nil,
            senses: [JMDictSense(
                pos: nil, glosses: ["gloss"], misc: nil,
                restrictedKanji: nil, restrictedKana: nil
            )]
        )
    }

    @Test(
        "the headword is the kanji writing when present, else the reading",
        arguments: zip(headwordSpellings, headwordExpectations)
    )
    func headwordPrefersKeb(spellings: (keb: String?, reb: String?), expected: String?) {
        #expect(FavoriteIdentity.headword(keb: spellings.keb, reb: spellings.reb) == expected)
    }

    @Test("an identity built from empty headwords holds no keys")
    func initSkipsEmptyHeadwords() {
        let identity = FavoriteIdentity(words: [
            FavoriteWord.starred(headword: "", reading: "みる")
        ])

        #expect(identity.keys.isEmpty)
    }

    @Test("inserting an empty headword changes nothing")
    func insertSkipsEmptyHeadword() {
        var identity = FavoriteIdentity(words: [
            FavoriteWord.starred(headword: "見る", reading: "みる")
        ])

        identity.insert(FavoriteWord.starred(headword: "", reading: "みる"))

        #expect(identity.keys == [FavoriteIdentity.normalize("見る")])
    }

    @Test("an entry with distinct writings stars on its kanji form")
    func entryPrefersKebOverReb() {
        let kanjiStarred = FavoriteIdentity(words: [
            FavoriteWord.starred(headword: "見る", reading: "みる")
        ])
        #expect(kanjiStarred.isFavorite(entry(keb: "見る", reb: "みる")))
        let kanaStarred = FavoriteIdentity(words: [
            FavoriteWord.starred(headword: "みる", reading: "みる")
        ])
        #expect(!kanaStarred.isFavorite(entry(keb: "見る", reb: "みる")))
    }

    @Test("a kana-only entry keys on its reading")
    func kanaOnlyEntryKeysOnReading() {
        let kanaEntry = entry(keb: nil, reb: "みる")
        #expect(FavoriteIdentity.headword(of: kanaEntry) == "みる")
        let identity = FavoriteIdentity(words: [
            FavoriteWord.starred(headword: "みる", reading: "みる")
        ])
        #expect(identity.isFavorite(kanaEntry))
    }

    @Test("an empty headword never names a favorite")
    func emptyHeadwordNeverMatches() {
        let identity = FavoriteIdentity(keys: [FavoriteIdentity.normalize("見る")])
        #expect(!identity.isFavorite(headword: ""))
    }

    @Test("an empty surface with a valid lemma stays dark")
    func emptySurfaceWithLemmaStaysDark() {
        let identity = FavoriteIdentity(words: [
            FavoriteWord.starred(headword: "見る", reading: "みる")
        ])
        #expect(!identity.matches(segment("", lemma: "見る")))
    }

    @Test("membership folds halfwidth katakana onto its fullwidth form")
    func membershipFoldsHalfwidthKana() {
        let identity = FavoriteIdentity(keys: [FavoriteIdentity.normalize("コーヒー")])
        #expect(identity.isFavorite(headword: "ｺｰﾋｰ"))
        #expect(!identity.isFavorite(headword: nil))
    }

    @Test("the pill-lead probe reads only the first entry")
    func leadReadsFirstEntryOnly() {
        let identity = FavoriteIdentity(keys: [FavoriteIdentity.normalize("報")])
        #expect(identity.leads(LookupResult(matched: "ほう", entries: [
            entry(keb: "報", reb: "ほう", seq: 1),
            entry(keb: "方", reb: "ほう", seq: 2)
        ])))
        #expect(!identity.leads(LookupResult(matched: "ほう", entries: [
            entry(keb: "方", reb: "ほう", seq: 1),
            entry(keb: "報", reb: "ほう", seq: 2)
        ])))
    }

    @Test("star to highlight to lead display is one round trip")
    func starToHighlightToLeadDisplay() {
        let starred = FavoriteWord.starred(headword: "見る", reading: "みる")
        let identity = FavoriteIdentity(words: [starred])
        #expect(identity.isFavorite(headword: starred.headword))
        #expect(identity.matches(segment("見ました", lemma: "見る")))
        // A kana tap on the starred word's reading: the entry the star is
        // written on carries the match through its reading and leads.
        let promoted = FavoritesPromotion.promotingFavorites(
            in: LookupResult(matched: "みる", entries: [
                entry(keb: "診る", reb: "みる", seq: 1),
                entry(keb: "見る", reb: "みる", seq: 2)
            ]),
            identity: identity
        )
        #expect(promoted.entries.map(\.keb) == ["見る", "診る"])
        #expect(identity.leads(promoted))
    }
}
