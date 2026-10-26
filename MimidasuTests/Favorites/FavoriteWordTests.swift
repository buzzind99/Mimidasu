import Foundation
@testable import Mimidasu
import Testing

/// One matching-table row: the identity a store would build for a starred
/// word, the rendered segment, and whether the segment counts as a favorite.
struct FavoriteMatchCase: Sendable {
    let keys: Set<String>
    let storedReadings: [String?]
    let surface: String
    let lemma: String?
    let furigana: String?
    let isBound: Bool
    let expected: Bool

    init(
        keys: Set<String> = [], storedReadings: [String?] = [], surface: String,
        lemma: String? = nil, furigana: String? = nil, isBound: Bool = false,
        expected: Bool
    ) {
        self.keys = keys
        self.storedReadings = storedReadings
        self.surface = surface
        self.lemma = lemma
        self.furigana = furigana
        self.isBound = isBound
        self.expected = expected
    }
}

private let readingBridgeCases: [FavoriteMatchCase] = [
    FavoriteMatchCase(
        keys: [FavoriteIdentity.normalize("貰う")], storedReadings: ["もらう"],
        surface: "もらって", lemma: "もらう", expected: true
    ),
    FavoriteMatchCase(
        keys: [FavoriteIdentity.normalize("貰う")], storedReadings: ["もらう"],
        surface: "モラッテ", lemma: "モラウ", expected: true
    ),
    FavoriteMatchCase(
        keys: [FavoriteIdentity.normalize("貰う")], storedReadings: ["もらう"],
        surface: "もらえる", lemma: "もらえる", expected: true
    ),
    FavoriteMatchCase(
        keys: [FavoriteIdentity.normalize("貰う")], storedReadings: ["もらう"],
        surface: "貰って", lemma: "もらう", expected: true
    ),
    FavoriteMatchCase(storedReadings: ["ありがとう"], surface: "ありがとう", expected: true),
    FavoriteMatchCase(storedReadings: ["こーひー"], surface: "コーヒー", expected: true),
    FavoriteMatchCase(storedReadings: ["こーひー"], surface: "ｺｰﾋｰ", expected: true),
    FavoriteMatchCase(storedReadings: ["は"], surface: "は", expected: true),
    FavoriteMatchCase(
        keys: [FavoriteIdentity.normalize("コーヒー")], surface: "ｺｰﾋｰ", expected: true
    )
]

private let noReadingBridgeCases: [FavoriteMatchCase] = [
    FavoriteMatchCase(
        keys: [FavoriteIdentity.normalize("貰う")], storedReadings: ["もらう"],
        surface: "もらって", lemma: "もらう", isBound: true, expected: false
    ),
    FavoriteMatchCase(
        storedReadings: ["もらう"], surface: "きいて", lemma: "きく", expected: false
    ),
    FavoriteMatchCase(storedReadings: ["貰う"], surface: "貰って", lemma: "貰う", expected: false),
    FavoriteMatchCase(
        storedReadings: ["おい"], surface: "置く", lemma: "置く", furigana: "おく",
        expected: false
    ),
    FavoriteMatchCase(storedReadings: ["ありがとう"], surface: "あると", expected: false),
    FavoriteMatchCase(
        storedReadings: ["にちようび"], surface: "日曜日", lemma: "日曜日", expected: false
    )
]

private let potentialCases: [FavoriteMatchCase] = [
    FavoriteMatchCase(
        keys: [FavoriteIdentity.normalize("勝つ")], surface: "勝て", lemma: "勝てる",
        expected: true
    ),
    FavoriteMatchCase(
        keys: [FavoriteIdentity.normalize("勝つ")], surface: "勝て", lemma: "勝てる",
        isBound: true, expected: false
    ),
    FavoriteMatchCase(
        keys: [FavoriteIdentity.normalize("負ける")], surface: "勝て", lemma: "勝てる",
        expected: false
    )
]

private let readingKeyCases: [(reading: String?, expected: String?)] = [
    ("50%", nil),
    ("コーヒー", "こーひー"),
    (nil, nil)
]

/// Pure matching rules for a stored headword: which rendered segments count
/// as favorites. No store and no database — the rules live on `FavoriteIdentity`
/// precisely so they can be pinned on their own.
@Suite("FavoriteWord")
struct FavoriteWordTests {

    private func segment(
        _ surface: String, lemma: String? = nil, furigana: String? = nil,
        isBound: Bool = false
    ) -> ReadingSegment {
        ReadingSegment(
            surface: surface, romaji: surface, furigana: furigana, lemma: lemma,
            isBound: isBound
        )
    }

    private var keys: Set<String> {
        [FavoriteIdentity.normalize("見る")]
    }

    private var naiKeys: Set<String> {
        [FavoriteIdentity.normalize("ない")]
    }

    /// The identity a store would build for the row, probed with the rendered
    /// segment: stored readings go through the same kana-key rule the store
    /// uses, so a reading without kana never arrives.
    private func matches(_ testCase: FavoriteMatchCase) -> Bool {
        let stored = Set(testCase.storedReadings.compactMap { candidate in
            FavoriteIdentity.readingKey(candidate)
        })
        return FavoriteIdentity(keys: testCase.keys, readings: stored).matches(
            segment(
                testCase.surface, lemma: testCase.lemma,
                furigana: testCase.furigana, isBound: testCase.isBound
            )
        )
    }

    @Test(
        "normalize folds halfwidth katakana and leaves composed text untouched",
        arguments: [("ｶﾞ", "ガ"), ("見る", "見る")]
    )
    func normalizeFoldsHalfwidthKana(text: String, expected: String) {
        #expect(FavoriteIdentity.normalize(text) == expected)
    }

    @Test("a segment matches on an exact surface hit")
    func matchesSurface() {
        #expect(FavoriteIdentity(keys: keys).matches(segment("見る")))
    }

    @Test("a conjugated surface matches through its lemma")
    func matchesLemma() {
        #expect(FavoriteIdentity(keys: keys).matches(segment("見た", lemma: "見る")))
    }

    @Test(
        "a potential lemma unwraps to the starred dictionary form, unless bound or different",
        arguments: potentialCases
    )
    func matchesUnwrappedPotentialLemma(testCase: FavoriteMatchCase) {
        #expect(matches(testCase) == testCase.expected)
    }

    @Test(
        "a kana-written conjugate matches through the stored reading in every script pairing",
        arguments: readingBridgeCases
    )
    func matchesKanaLemmaOfKanjiFavorite(testCase: FavoriteMatchCase) {
        #expect(matches(testCase) == testCase.expected)
    }

    @Test(
        "a bound, unrelated, or non-kana bridge keeps the segment dark",
        arguments: noReadingBridgeCases
    )
    func ignoresBoundKanaLemma(testCase: FavoriteMatchCase) {
        #expect(matches(testCase) == testCase.expected)
    }

    @Test("an empty surface and an empty lemma never match, so a malformed empty key stays inert")
    func ignoresEmptyText() {
        let empty = Set([""])

        #expect(!FavoriteIdentity(keys: empty).matches(segment("")))
        #expect(!FavoriteIdentity(keys: empty).matches(segment("見た", lemma: "")))
    }

    @Test("a bound token's lemma never matches, so a ない favorite leaves ねえ and なきゃ dark")
    func ignoresBoundLemma() {
        #expect(!FavoriteIdentity(keys: naiKeys).matches(
            segment("ねえ", lemma: "ない", isBound: true)
        ))
        #expect(!FavoriteIdentity(keys: naiKeys).matches(
            segment("なきゃ", lemma: "ない", isBound: true)
        ))
    }

    @Test("a bound token still matches on its exact surface, so spoken ない lights")
    func boundSurfaceStillMatches() {
        #expect(FavoriteIdentity(keys: naiKeys).matches(
            segment("ない", lemma: "ない", isBound: true)
        ))
    }

    @Test(
        "a stored reading keeps a folded key only when it carries kana",
        arguments: readingKeyCases
    )
    func readingKeyRejectsNonKana(reading: String?, expected: String?) {
        #expect(FavoriteIdentity.readingKey(reading) == expected)
    }

    @Test("an unrelated segment does not match")
    func ignoresUnrelatedSegment() {
        #expect(!FavoriteIdentity(keys: keys).matches(segment("食べる", lemma: "食べる")))
    }

    @Test("identity is the headword, so the list is keyed by word")
    func identityIsHeadword() {
        let word = FavoriteWord(
            headword: "見る", reading: "みる", romaji: "miru", addedAt: 0
        )

        #expect(word.id == "見る")
    }
}
