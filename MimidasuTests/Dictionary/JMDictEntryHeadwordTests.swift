@testable import Mimidasu
import Testing

private let headwordSpellings: [(String?, String?)] = [
    ("お土産", "おみやけ"),
    (nil, "おみやけ"),
    ("", "みる"),
    ("見る", ""),
    ("", nil),
    (nil, ""),
    ("", ""),
    (nil, nil)
]

private let headwordExpectations: [String?] = [
    "お土産", "おみやけ", "みる", "見る", nil, nil, nil, nil
]

/// The written form a star keys on: the kanji writing when present, the
/// reading otherwise, with an empty spelling counting as absent — pinned on
/// the entry property and on the static rule it delegates to.
@Suite("JMDict entry headword")
struct JMDictEntryHeadwordTests {

    // MARK: - Fixtures

    private func sense(
        pos: String? = "n", glosses: [String] = ["a gloss"], misc: String? = nil
    ) -> JMDictSense {
        JMDictSense(
            pos: pos, glosses: glosses, misc: misc, restrictedKanji: nil, restrictedKana: nil
        )
    }

    private func entry(
        keb: String? = "お土産", reb: String? = "おみやけ", common: Bool = true,
        jlpt: Int? = 5, hatsuon: String? = "おみ'やけ", accPatts: String? = "0",
        zoPatts: String? = "HLLL", senses: [JMDictSense]? = nil
    ) -> JMDictEntry {
        JMDictEntry(
            entSeq: 1, keb: keb, reb: reb, common: common, jlpt: jlpt,
            hatsuon: hatsuon, accPatts: accPatts, zoPatts: zoPatts,
            senses: senses ?? [sense()]
        )
    }

    // MARK: - The rule

    @Test(
        "headword prefers the kanji writing and falls back to the reading",
        arguments: zip(headwordSpellings, headwordExpectations)
    )
    func headword(spellings: (keb: String?, reb: String?), expected: String?) {
        #expect(entry(keb: spellings.keb, reb: spellings.reb).headword == expected)
        #expect(JMDictEntry.headword(keb: spellings.keb, reb: spellings.reb) == expected)
    }
}
