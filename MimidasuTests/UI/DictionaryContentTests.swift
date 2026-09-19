@testable import Mimidasu
import Testing

/// Tests the shared dictionary content assembly (`DictionaryContent`) and
/// the cursor-mode card gating: JLPT and pitch mappings follow the probe
/// record, caps and truncation are enforced, and `.dictionary` swaps
/// ENGINES + AUDIO for the DICTIONARY card.
@MainActor
@Suite("Dictionary lookup content assembly")
struct DictionaryContentTests {

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

    private func result(_ matched: String) -> LookupResult {
        LookupResult(matched: matched, entries: [entry(keb: matched)])
    }

    // MARK: - Headword, badges, romaji, POS

    @Test("headword prefers the kanji writing and falls back to the reading")
    func headword() {
        #expect(DictionaryContent.headword(of: entry()) == "お土産")
        #expect(DictionaryContent.headword(of: entry(keb: nil)) == "おみやけ")
    }

    @Test("the JLPT badge uses the probe-fixed ≈N mapping and omits when null")
    func jlptBadge() {
        #expect(DictionaryContent.jlptBadge(nil) == nil)
        #expect(DictionaryContent.jlptBadge(5) == "≈N5")
        #expect(DictionaryContent.jlptBadge(3) == "≈N3")
        #expect(DictionaryContent.jlptBadge(1) == "≈N1")
    }

    @Test("romaji converts the kana reading; unmappable or missing readings omit the line")
    func romaji() {
        #expect(DictionaryContent.romaji(for: entry()) == "omiyake")
        #expect(DictionaryContent.romaji(for: entry(reb: nil)) == nil)
        // Kanji cannot convert — a kanji-string reading is not romaji-able.
        #expect(DictionaryContent.romaji(for: entry(reb: "漢字")) == nil)
    }

    @Test("the POS label is the first stored tag")
    func posLabel() {
        #expect(DictionaryContent.posLabel("n,vs") == "n")
        #expect(DictionaryContent.posLabel("n") == "n")
        #expect(DictionaryContent.posLabel(nil) == nil)
        #expect(DictionaryContent.posLabel("") == nil)
    }

    @Test("JMnedict name types render friendly badges")
    func posLabelNameTypes() {
        #expect(DictionaryContent.posLabel("surname") == "SURNAME")
        #expect(DictionaryContent.posLabel("given") == "GIVEN NAME")
        #expect(DictionaryContent.posLabel("fem") == "GIVEN NAME")
        #expect(DictionaryContent.posLabel("masc") == "GIVEN NAME")
        #expect(DictionaryContent.posLabel("person") == "NAME")
        #expect(DictionaryContent.posLabel("place") == "PLACE NAME")
        #expect(DictionaryContent.posLabel("organization") == "ORGANIZATION")
        #expect(DictionaryContent.posLabel("company") == "COMPANY NAME")
        #expect(DictionaryContent.posLabel("station") == "STATION")
        #expect(DictionaryContent.posLabel("product") == "PRODUCT")
        #expect(DictionaryContent.posLabel("work") == "WORK")
        #expect(DictionaryContent.posLabel("unclass") == "NAME")
    }

    @Test("multi-type name senses take the first token; unknown types pass through verbatim")
    func nameBadgeFirstTokenAndPassthrough() {
        #expect(DictionaryContent.posLabel("place,surname") == "PLACE NAME")
        #expect(DictionaryContent.posLabel("char,surname") == "char")
        // The rare upstream types and JMDict POS tags never map.
        #expect(DictionaryContent.posLabel("char") == "char")
        #expect(DictionaryContent.posLabel("relig") == "relig")
        #expect(DictionaryContent.posLabel("v1,vt") == "v1")
    }

    // MARK: - Name entries (JMnedict offset range)

    /// 木村 as JMnedict id 5668306 → ent_seq 15_668_306: types place +
    /// surname under one reading, stored gloss the romanization "Kimura".
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

    @Test("only the offset range counts as a name entry")
    func isName() {
        // Real data never touches this band (words stay well under the
        // offset; ingest lands names at 15M+) — the pair pins the >=
        // predicate itself.
        #expect(!DictionaryContent.isName(entry()))
        #expect(DictionaryContent.isName(nameEntry(entSeq: 10_000_000)))
        #expect(!DictionaryContent.isName(nameEntry(entSeq: 9_999_999)))
    }

    @Test("name type badges map every stored token, deduped in order")
    func nameTypeBadgeList() {
        #expect(DictionaryContent.nameTypeBadges(for: nameEntry()) == ["PLACE NAME", "SURNAME"])
        #expect(
            DictionaryContent.nameTypeBadges(for: nameEntry(pos: "surname,place"))
                == ["SURNAME", "PLACE NAME"]
        )
        #expect(DictionaryContent.nameTypeBadges(for: nameEntry(pos: "fem,given")) == ["GIVEN NAME"])
        #expect(DictionaryContent.nameTypeBadges(for: nameEntry(pos: "char,surname")) == ["char", "SURNAME"])
        #expect(DictionaryContent.nameTypeBadges(for: nameEntry(pos: nil)) == [])
        // Word entries contribute nothing — their POS tags stay in the sense row.
        #expect(DictionaryContent.nameTypeBadges(for: entry()) == [])
        // Dedupe also spans senses (ingest flattens names to one sense
        // today; the mapper still guards the multi-sense shape).
        #expect(
            DictionaryContent.nameTypeBadges(for: nameEntry(senses: [
                sense(pos: "surname", glosses: ["Kimura"]),
                sense(pos: "fem,surname", glosses: ["Kimura"])
            ])) == ["SURNAME", "GIVEN NAME"]
        )
    }

    @Test("name glosses drop the romaji echo and keep real content")
    func nameGlosses() {
        // きむら → "kimura"; the stored gloss "Kimura" is the echo and drops.
        #expect(DictionaryContent.nameGlosses(for: nameEntry()) == [])
        // The echo drops case-insensitively; other glosses stay.
        #expect(
            DictionaryContent.nameGlosses(for: nameEntry(glosses: ["KIMURA", "town in Hokkaido"]))
                == ["town in Hokkaido"]
        )
        // A reading whose romaji differs from the gloss keeps it.
        #expect(
            DictionaryContent.nameGlosses(
                for: nameEntry(reb: "せんとちひろのかみかくし", glosses: ["Spirited Away"])
            ) == ["Spirited Away"]
        )
        // An unmappable reading keeps every gloss.
        #expect(DictionaryContent.nameGlosses(for: nameEntry(reb: "漢字")) == ["Kimura"])
        // Blank glosses drop in both branches — with and without a romaji.
        #expect(DictionaryContent.nameGlosses(for: nameEntry(glosses: ["Kimura", "  "])) == [])
        #expect(
            DictionaryContent.nameGlosses(for: nameEntry(reb: "漢字", glosses: ["Kimura", ""]))
                == ["Kimura"]
        )
    }

    // MARK: - Pitch pill

    @Test("clean hatsuon renders verbatim alongside the verbatim zoPatts")
    func cleanPitch() {
        let pill = DictionaryContent.pitchPill(for: entry(hatsuon: "おみ'やけ", zoPatts: "HLLL"))

        #expect(pill == DictionaryContent.PitchPill(hatsuon: "おみ'やけ", zoPatts: "HLLL"))
    }

    @Test("marked-up hatsuon text is omitted and only zoPatts shows")
    func markedUpHatsuon() {
        for marked in ["<あい'さつ>", "[あい]さつ", "あい･さつ", "あい~さつ"] {
            let pill = DictionaryContent.pitchPill(for: entry(hatsuon: marked, zoPatts: "HLL"))

            #expect(pill == DictionaryContent.PitchPill(hatsuon: nil, zoPatts: "HLL"))
        }
    }

    @Test("a pitch-less entry omits the pill")
    func pitchlessOmitted() {
        #expect(DictionaryContent.pitchPill(for: entry(hatsuon: nil, zoPatts: nil)) == nil)
        #expect(DictionaryContent.pitchPill(for: entry(hatsuon: "", zoPatts: "")) == nil)
    }

    @Test("no accent-type label exists anywhere in v1")
    func noAccentLabel() {
        // accPatts semantics are unvalidated (probe record); the assembly
        // never derives a label from them.
        let pill = DictionaryContent.pitchPill(for: entry(accPatts: "1,1—0"))

        #expect(pill?.hatsuon == "おみ'やけ", "accPatts never leaks into the pill")
    }

    // MARK: - Caps and truncation

    @Test("senses cap at five with a hidden-count footer")
    func senseCap() {
        let senses = (0 ..< 7).map { index in sense(glosses: ["gloss \(index)"]) }

        let truncated = DictionaryContent.truncated(senses, limit: DictionaryContent.maxSenses)

        #expect(truncated.visible.count == 5)
        #expect(truncated.hidden == 2)
    }

    @Test("the card's tighter sense limit is parameterized")
    func cardSenseLimit() {
        let senses = (0 ..< 7).map { _ in sense() }

        let truncated = DictionaryContent.truncated(senses, limit: 2)

        #expect(truncated.visible.count == 2)
        #expect(truncated.hidden == 5)
    }

    @Test("glosses cap at three per sense")
    func glossCap() {
        let truncated = DictionaryContent.truncated(
            ["a", "b", "c", "d", "e"], limit: DictionaryContent.maxGlossesPerSense
        )

        #expect(Array(truncated.visible) == ["a", "b", "c"])
        #expect(truncated.hidden == 2)
    }

    @Test("also pills cap at two")
    func alsoCap() {
        let also = (0 ..< 3).map { index in result("word\(index)") }

        #expect(Array(DictionaryContent.truncatedAlso(also)).map(\.matched) == ["word0", "word1"])
        #expect(DictionaryContent.truncatedAlso([]).isEmpty)
    }

    // MARK: - Pill labels

    @Test("a pill shows the lead entry's headword — what tapping will display")
    func pillLabel() {
        // A split-guess fragment (起) whose lead entry's writing differs.
        let okiru = LookupResult(matched: "起", entries: [entry(keb: "起こり")])
        #expect(DictionaryContent.pillLabel(for: okiru) == "起こり")

        // Kana-only entries label with their reading.
        let kanaOnly = LookupResult(matched: "おこり", entries: [entry(keb: nil, reb: "おこり")])
        #expect(DictionaryContent.pillLabel(for: kanaOnly) == "おこり")

        // Entry-less results (never produced by the engine) keep the fallback.
        let empty = LookupResult(matched: "起", entries: [])
        #expect(DictionaryContent.pillLabel(for: empty) == "起")
    }

    // MARK: - Sidebar mode gating

    @Test("dictionary mode shows DICTIONARY + SESSION only; other modes show ENGINES + AUDIO")
    func sidebarGating() {
        #expect(SidebarView.showsCards(for: .dictionary) == .dictionaryMode)

        for mode in [CursorMode.none, .copy] {
            #expect(SidebarView.showsCards(for: mode) == .enginePair)
        }
    }

    // MARK: - Popover anchor exclusivity

    @Test("popoverItem scopes the selection to its owning surface")
    func popoverScoping() {
        let selected = SelectedLookup(
            content: .found(result: result("お土産"), also: [], origin: .tappedSurface),
            source: .transcript(sentenceIndex: 2, tokenIndex: 1),
            entryIndex: 0
        )

        #expect(
            selected.popoverItem(for: .transcript(sentenceIndex: 2, tokenIndex: 1)) == selected
        )
        #expect(
            selected.popoverItem(for: .transcript(sentenceIndex: 2, tokenIndex: 3)) == nil
        )
        #expect(
            selected.popoverItem(for: .transcript(sentenceIndex: 3, tokenIndex: 1)) == nil
        )
        #expect(selected.popoverItem(for: .liveStrip) == nil)
    }

    // MARK: - Pinned content states

    @Test("the joined-match badge names only join leads")
    func joinedBadge() {
        #expect(DictionaryContent.joinedMatchBadge(for: .join) == "JOINED MATCH")
        #expect(DictionaryContent.joinedMatchBadge(for: .tappedSurface) == nil)
        #expect(DictionaryContent.joinedMatchBadge(for: .tappedLemma) == nil)
        #expect(DictionaryContent.joinedMatchBadge(for: .split) == nil)
    }

    @Test("content accessors expose the display result and the fallback pills per state")
    func contentAccessors() {
        let found = LookupContent.found(
            result: result("お"), also: [result("お土産")], origin: .tappedSurface
        )
        #expect(found.displayResult?.matched == "お")
        #expect(found.fallbackResults.map(\.matched) == ["お土産"])

        let notFound = LookupContent.notFound(surface: "雨尾", related: [result("雨")])
        #expect(notFound.displayResult == nil)
        #expect(notFound.fallbackResults.map(\.matched) == ["雨"])
    }

    @Test("the selection identity follows the matched headword and the not-found surface")
    func identityToken() {
        let found = SelectedLookup(
            content: .found(result: result("お"), also: [], origin: .tappedSurface),
            source: .liveStrip,
            entryIndex: 0
        )
        let promoted = SelectedLookup(
            content: .found(result: result("お土産"), also: [], origin: .tappedSurface),
            source: .liveStrip,
            entryIndex: 0
        )
        let notFound = SelectedLookup(
            content: .notFound(surface: "雨尾", related: []),
            source: .liveStrip,
            entryIndex: 0
        )

        #expect(found.id.hasSuffix("-お"))
        #expect(found.id != promoted.id, "a pill promotion swaps the content identity")
        #expect(notFound.id.contains("not-found:雨尾"))
    }
}
