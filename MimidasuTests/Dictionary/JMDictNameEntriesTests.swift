@testable import Mimidasu
import Testing

/// The JMnedict half's frozen facts: the ingest offset that separates words
/// from names, the name predicate the entry property agrees with, and the
/// name-type vocabulary the badge rows and the filter read.
@Suite("JMDict name entries")
struct JMDictNameEntriesTests {

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

    private func nameEntry(
        entSeq: Int = 15_668_306, reb: String? = "きむら",
        pos: String? = "place,surname", glosses: [String] = ["Kimura"],
        senses: [JMDictSense]? = nil
    ) -> JMDictEntry {
        JMDictEntry(
            entSeq: entSeq, keb: "木村", reb: reb, common: false, jlpt: nil,
            hatsuon: nil, accPatts: nil, zoPatts: nil,
            senses: senses ?? [sense(pos: pos, glosses: glosses)]
        )
    }

    // MARK: - Offset and predicate

    @Test("the JMnedict ingest offset is ten million")
    func ingestOffsetValue() {
        let boundary = JMDictNameEntries.ingestOffset

        #expect(boundary == 10_000_000)
    }

    @Test("classifies an ent_seq at and around the ingest offset", arguments: [
        (9_999_999, false),
        (10_000_000, true),
        (1, false),
        (15_668_306, true)
    ])
    func boundary(entSeq: Int, expected: Bool) {
        let classified = JMDictNameEntries.isName(entSeq: entSeq)

        #expect(classified == expected)
    }

    @Test("only the offset range counts as a name entry")
    func isName() {
        // Real data never touches this band (words stay well under the
        // offset; ingest lands names at 15M+) — the pair pins the >=
        // predicate itself.
        #expect(!JMDictNameEntries.isName(entry()))
        #expect(JMDictNameEntries.isName(nameEntry(entSeq: 10_000_000)))
        #expect(!JMDictNameEntries.isName(nameEntry(entSeq: 9_999_999)))
    }

    @Test("the entry property agrees with the static predicate", arguments: [
        1, 9_999_999, 10_000_000, 15_668_306
    ])
    func isNameAgreement(entSeq: Int) {
        let built = nameEntry(entSeq: entSeq)

        #expect(built.isName == JMDictNameEntries.isName(entSeq: entSeq))
    }

    // MARK: - Badge mapping

    /// The raw-`pos` entry point the search row calls. It must produce exactly
    /// what the entry overload produces for the same stored tags — that
    /// equality is the whole reason it exists: a collapsed search row and an
    /// expanded entry cannot label one name two different ways.
    @Test("raw pos columns map to the same badges the entry overload does")
    func nameTypeBadgesFromPosTokens() {
        let columns: [String?] = ["place,surname"]
        #expect(
            JMDictNameEntries.nameTypeBadges(posTokens: columns)
                == JMDictNameEntries.nameTypeBadges(for: nameEntry())
        )
        // Dedupe spans columns and a null column is skipped.
        #expect(
            JMDictNameEntries.nameTypeBadges(posTokens: ["surname", nil, "surname", "serv"])
                == ["SURNAME", "SERVICE"]
        )
        #expect(JMDictNameEntries.nameTypeBadges(posTokens: []) == [])
        #expect(JMDictNameEntries.nameTypeBadges(posTokens: [nil]) == [])
    }

    @Test("name type badges map every stored token, deduped in order")
    func nameTypeBadgeList() {
        #expect(JMDictNameEntries.nameTypeBadges(for: nameEntry()) == ["PLACE NAME", "SURNAME"])
        #expect(
            JMDictNameEntries.nameTypeBadges(for: nameEntry(pos: "surname,place"))
                == ["SURNAME", "PLACE NAME"]
        )
        #expect(JMDictNameEntries.nameTypeBadges(for: nameEntry(pos: "fem,given")) == ["GIVEN NAME"])
        #expect(JMDictNameEntries.nameTypeBadges(for: nameEntry(pos: "char,surname")) == ["CHARACTER", "SURNAME"])
        #expect(JMDictNameEntries.nameTypeBadges(for: nameEntry(pos: nil)) == [])
        // Word entries contribute nothing — their POS tags stay in the sense row.
        #expect(JMDictNameEntries.nameTypeBadges(for: entry()) == [])
        // A tag the map lacks passes through verbatim rather than dropping.
        #expect(JMDictNameEntries.nameTypeBadges(for: nameEntry(pos: "plant")) == ["plant"])
        // Dedupe also spans senses (ingest flattens names to one sense
        // today; the mapper still guards the multi-sense shape).
        #expect(
            JMDictNameEntries.nameTypeBadges(for: nameEntry(senses: [
                sense(pos: "surname", glosses: ["Kimura"]),
                sense(pos: "fem,surname", glosses: ["Kimura"])
            ])) == ["SURNAME", "GIVEN NAME"]
        )
    }

    // MARK: - Vocabulary

    @Test("allBadges carries every label alphabetically")
    func allBadgesVocabulary() {
        #expect(
            JMDictNameEntries.allBadges == [
                "CHARACTER", "COMPANY NAME", "CREATURE", "DEITY", "DOCUMENT", "EVENT",
                "FICTION", "GIVEN NAME", "GROUP", "LEGEND", "MYTHOLOGY", "NAME",
                "OBJECT", "ORGANIZATION", "PLACE NAME", "PRODUCT", "RELIGION", "SERVICE",
                "SHIP", "STATION", "SURNAME", "WORK"
            ]
        )
    }

    @Test("allBadges is deduped and sorted")
    func allBadgesSortedSet() {
        #expect(JMDictNameEntries.allBadges == Set(JMDictNameEntries.allBadges).sorted())
    }

    @Test("maps every stored name type to its badge label", arguments: [
        ("surname", "SURNAME"),
        ("given", "GIVEN NAME"),
        ("fem", "GIVEN NAME"),
        ("masc", "GIVEN NAME"),
        ("person", "NAME"),
        ("place", "PLACE NAME"),
        ("organization", "ORGANIZATION"),
        ("company", "COMPANY NAME"),
        ("station", "STATION"),
        ("product", "PRODUCT"),
        ("work", "WORK"),
        ("unclass", "NAME"),
        ("serv", "SERVICE"),
        ("char", "CHARACTER"),
        ("fict", "FICTION"),
        ("ev", "EVENT"),
        ("group", "GROUP"),
        ("dei", "DEITY"),
        ("obj", "OBJECT"),
        ("myth", "MYTHOLOGY"),
        ("doc", "DOCUMENT"),
        ("creat", "CREATURE"),
        ("ship", "SHIP"),
        ("leg", "LEGEND"),
        ("relig", "RELIGION")
    ])
    func typeLabelMapped(tag: String, label: String) {
        #expect(JMDictNameEntries.typeLabel(for: tag) == label)
    }

    @Test("leaves a tag the map lacks unlabelled", arguments: ["n", "v1", "plant"])
    func typeLabelUnmapped(tag: String) {
        #expect(JMDictNameEntries.typeLabel(for: tag) == nil)
    }
}
