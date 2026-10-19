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

    @Test("POS labels are every stored tag, in stored order")
    func posLabels() {
        #expect(DictionaryContent.posLabels("n,vs") == ["n", "vs"])
        // The ポンチ entry's last sense, the investigation's live case.
        #expect(DictionaryContent.posLabels("n,adj-na") == ["n", "adj-na"])
        #expect(DictionaryContent.posLabels("n") == ["n"])
        #expect(DictionaryContent.posLabels(nil) == [])
        #expect(DictionaryContent.posLabels("") == [])
        // Later tokens are trimmed, a blank one is skipped rather than
        // fatal, and an identical repeat collapses to one badge.
        #expect(DictionaryContent.posLabels("n, vs") == ["n", "vs"])
        #expect(DictionaryContent.posLabels("n ,vs") == ["n", "vs"])
        #expect(DictionaryContent.posLabels(",n") == ["n"])
        #expect(DictionaryContent.posLabels("n,n") == ["n"])
    }

    @Test("JMnedict name types render friendly badges")
    func posLabelsNameTypes() {
        #expect(DictionaryContent.posLabels("surname") == ["SURNAME"])
        #expect(DictionaryContent.posLabels("given") == ["GIVEN NAME"])
        #expect(DictionaryContent.posLabels("fem") == ["GIVEN NAME"])
        #expect(DictionaryContent.posLabels("masc") == ["GIVEN NAME"])
        #expect(DictionaryContent.posLabels("person") == ["NAME"])
        #expect(DictionaryContent.posLabels("place") == ["PLACE NAME"])
        #expect(DictionaryContent.posLabels("organization") == ["ORGANIZATION"])
        #expect(DictionaryContent.posLabels("company") == ["COMPANY NAME"])
        #expect(DictionaryContent.posLabels("station") == ["STATION"])
        #expect(DictionaryContent.posLabels("product") == ["PRODUCT"])
        #expect(DictionaryContent.posLabels("work") == ["WORK"])
        #expect(DictionaryContent.posLabels("unclass") == ["NAME"])
        // The rare types the pinned corpus carries (三田線 is a `serv`).
        #expect(DictionaryContent.posLabels("serv") == ["SERVICE"])
        #expect(DictionaryContent.posLabels("char") == ["CHARACTER"])
        #expect(DictionaryContent.posLabels("fict") == ["FICTION"])
        #expect(DictionaryContent.posLabels("ev") == ["EVENT"])
        #expect(DictionaryContent.posLabels("group") == ["GROUP"])
        #expect(DictionaryContent.posLabels("dei") == ["DEITY"])
        #expect(DictionaryContent.posLabels("obj") == ["OBJECT"])
        #expect(DictionaryContent.posLabels("myth") == ["MYTHOLOGY"])
        #expect(DictionaryContent.posLabels("doc") == ["DOCUMENT"])
        #expect(DictionaryContent.posLabels("creat") == ["CREATURE"])
        #expect(DictionaryContent.posLabels("ship") == ["SHIP"])
        #expect(DictionaryContent.posLabels("leg") == ["LEGEND"])
        #expect(DictionaryContent.posLabels("relig") == ["RELIGION"])
    }

    @Test("multi-type name senses render every token; unknown types pass through verbatim")
    func nameBadgeAllTokensAndPassthrough() {
        #expect(DictionaryContent.posLabels("place,surname") == ["PLACE NAME", "SURNAME"])
        #expect(DictionaryContent.posLabels("serv,station") == ["SERVICE", "STATION"])
        // Two tags rendering to the same label collapse to a single badge.
        #expect(DictionaryContent.posLabels("fem,masc") == ["GIVEN NAME"])
        // A tag the map lacks (a retired upstream type here) and JMDict POS
        // tags never map.
        #expect(DictionaryContent.posLabels("plant") == ["plant"])
        #expect(DictionaryContent.posLabels("v1,vt") == ["v1", "vt"])
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
        for marked in ["<あい'さつ>", "[あい]さつ", "あい･さつ", "あい・さつ", "あい~さつ"] {
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

    @Test("also pills cap at nine — the resolution ceiling, truncating neither row")
    func alsoCap() {
        let candidates = (0 ..< 10).map { index in result("word\(index)") }

        // A found tap's also: row holds at most eight (the display result
        // takes one); a split-only related: row has no display result and
        // can hold all nine candidates — none of them truncates. Ten
        // candidates cannot occur; that case pins the cap itself.
        #expect(
            Array(DictionaryContent.truncatedAlso(Array(candidates.prefix(9)))).map(\.matched)
                == (0 ..< 9).map { index in "word\(index)" }
        )
        let capped = DictionaryContent.truncatedAlso(candidates)
        #expect(Array(capped).map(\.matched) == (0 ..< 9).map { index in "word\(index)" })
        #expect(candidates.count - capped.count == 1)
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
