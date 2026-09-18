/// Pure content assembly shared by the dictionary popover and the sidebar
/// DICTIONARY card: derives display strings from a `JMDictEntry` under
/// optional caps (both hosts currently render long entries in full) and the
/// probe-fixed mappings (JLPT `≈N`, pitch pill
/// without an accent-type label, hatsuon omitted when it carries Wadoku
/// markup). Both hosts render through the same view so they can never
/// diverge.
enum DictionaryContent {
    static let maxGlossesPerSense = 3
    static let maxSenses = 5
    static let maxAlsoPills = 2

    /// Headword row: the kanji writing when present, else the reading.
    static func headword(of entry: JMDictEntry) -> String? {
        entry.keb ?? entry.reb
    }

    /// Probe-fixed JLPT display: `≈N{value}` (5 → ≈N5 … 1 → ≈N1); nil
    /// omits the badge.
    static func jlptBadge(_ jlpt: Int?) -> String? {
        guard let jlpt else { return nil }
        return "≈N\(jlpt)"
    }

    /// `hatsuon` renders verbatim only when free of the Wadoku markup
    /// markers (`< > [ ] ･ ~`); marked-up text omits the hatsuon part and
    /// the pill shows `zoPatts` alone.
    static func renderableHatsuon(_ hatsuon: String?) -> String? {
        guard let hatsuon, !hatsuon.isEmpty,
              !hatsuon.contains(where: { marker in "<>[]･~".contains(marker) })
        else { return nil }
        return hatsuon
    }

    /// Pitch pill v1: unmarked-up hatsuon (optional) + verbatim `zoPatts`
    /// (alphabet `H L h l ,` — never re-spaced). Nil when neither part
    /// exists, omitting the pill.
    struct PitchPill: Equatable {
        let hatsuon: String?
        let zoPatts: String?
    }

    static func pitchPill(for entry: JMDictEntry) -> PitchPill? {
        let hatsuon = renderableHatsuon(entry.hatsuon)
        let zo = entry.zoPatts.flatMap { patts in patts.isEmpty ? nil : patts }
        guard hatsuon != nil || zo != nil else { return nil }
        return PitchPill(hatsuon: hatsuon, zoPatts: zo)
    }

    /// Romaji line under the headword: kana→romaji over the reading; nil
    /// when the reading is missing or unmappable (no line).
    static func romaji(for entry: JMDictEntry) -> String? {
        entry.reb.flatMap { reb in KanaRomaji.romaji(fromKana: reb) }
    }

    /// First tag of the stored comma-joined POS string, rendered through the
    /// JMnedict name-type badges: name entries store their entity types
    /// (`surname`, `place`, …) in `pos` and show friendly uppercase labels;
    /// JMDict POS tags and unknown values render verbatim. Multi-type
    /// senses take the first token.
    static func posLabel(_ pos: String?) -> String? {
        guard let pos, !pos.isEmpty else { return nil }
        let tag = pos.components(separatedBy: ",").first?
            .trimmingCharacters(in: .whitespaces)
        guard let tag, !tag.isEmpty else { return nil }
        return nameTypeBadges[tag] ?? tag
    }

    /// JMnedict name type → badge label. The mapped rows cover the common
    /// upstream vocabulary; the rare types (`char`, `serv`, `fict`, …) fall
    /// through verbatim. JMDict POS tags never collide with these tokens.
    private static let nameTypeBadges = [
        "surname": "SURNAME",
        "given": "GIVEN NAME",
        "fem": "GIVEN NAME",
        "masc": "GIVEN NAME",
        "person": "NAME",
        "place": "PLACE NAME",
        "organization": "ORGANIZATION",
        "company": "COMPANY NAME",
        "station": "STATION",
        "product": "PRODUCT",
        "work": "WORK",
        "unclass": "NAME"
    ]

    /// Prefix of `items` capped at `limit` (nil = every item), with the
    /// hidden count for the "+ N more" footer. Shared by the sense and gloss
    /// caps; a negative limit counts as uncapped.
    static func truncated<Element>(
        _ items: [Element], limit: Int?
    ) -> (visible: ArraySlice<Element>, hidden: Int) {
        guard let limit, limit >= 0 else { return (items[...], 0) }
        let visible = items.prefix(limit)
        return (visible, items.count - visible.count)
    }

    /// "also:" fallback-hit pills (longest match first), capped at two.
    static func truncatedAlso(_ also: [LookupResult]) -> ArraySlice<LookupResult> {
        also.prefix(maxAlsoPills)
    }

    /// Pill label: what tapping shows — the result's lead entry headword
    /// (promotion resets the pager to entry 0), falling back to the matched
    /// string when the result carries no entries.
    static func pillLabel(for result: LookupResult) -> String {
        result.entries.first.flatMap { entry in headword(of: entry) } ?? result.matched
    }

    /// Badge naming a display result that came from a forward join — the
    /// tapped word itself has no entry, but the compound it joins into
    /// does. nil for the tapped word's own surface or lemma, and for any
    /// result the user promoted from a pill (an explicit choice never
    /// reads as a fallback lead).
    static func joinedMatchBadge(for origin: ExpansionOrigin) -> String? {
        origin == .join ? "JOINED MATCH" : nil
    }
}
