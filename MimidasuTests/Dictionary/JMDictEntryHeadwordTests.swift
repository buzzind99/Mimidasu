@testable import Mimidasu
import Testing

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

    /// (keb, reb) rows checked through the property and the static rule.
    private static let agreementCases: [(String?, String?)] = [
        ("お土産", "おみやけ"),
        ("", "みる"),
        ("", nil),
        (nil, ""),
        ("", ""),
        ("見る", ""),
        (nil, nil)
    ]

    // MARK: - The rule

    @Test("headword prefers the kanji writing and falls back to the reading")
    func headword() {
        #expect(entry().headword == "お土産")
        #expect(entry(keb: nil).headword == "おみやけ")
    }

    @Test("an empty kanji writing falls back to the reading")
    func emptyKebFallsBackToReading() {
        #expect(JMDictEntry.headword(keb: "", reb: "みる") == "みる")
    }

    @Test("an empty reading falls back to the kanji writing")
    func emptyRebFallsBackToKanji() {
        #expect(JMDictEntry.headword(keb: "見る", reb: "") == "見る")
    }

    @Test("no usable spelling reads as nil")
    func noUsableSpellingIsNil() {
        #expect(JMDictEntry.headword(keb: "", reb: nil) == nil)
        #expect(JMDictEntry.headword(keb: nil, reb: "") == nil)
        #expect(JMDictEntry.headword(keb: "", reb: "") == nil)
    }

    @Test("the entry property agrees with the static rule", arguments: agreementCases)
    func headwordAgreement(keb: String?, reb: String?) {
        let built = entry(keb: keb, reb: reb)

        #expect(built.headword == JMDictEntry.headword(keb: keb, reb: reb))
    }
}
