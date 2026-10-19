import Foundation

/// One JMDict entry. `jlpt` and the pitch fields come from the headword row
/// the candidate matched (per-writing values); `common` is entry-level.
struct JMDictEntry: Equatable, Sendable {
    let entSeq: Int
    let keb: String?
    let reb: String?
    let common: Bool
    let jlpt: Int?
    /// Verbatim Wadoku hatsuon text. Render-time gating (marked-up forms
    /// containing `< > [ ] ･ ~` are omitted) belongs to the UI layer.
    let hatsuon: String?
    let accPatts: String?
    /// Verbatim H/L pattern string (alphabet `H L h l ,` — not assumed pure).
    let zoPatts: String?
    let senses: [JMDictSense]

    /// The written form a star keys on: the kanji writing when present,
    /// else the reading. An empty kanji writing or reading counts as
    /// absent, so both empty reads as nil. Every JMDict row carries at
    /// least one `reb`, so nil only arrives from a hand-built entry.
    var headword: String? {
        Self.headword(keb: keb, reb: reb)
    }

    /// The headword rule over raw spellings, for a hit that carries the
    /// columns rather than a whole entry.
    static func headword(keb: String?, reb: String?) -> String? {
        let cleanKeb = keb.flatMap { kebValue in kebValue.isEmpty ? nil : kebValue }
        let cleanReb = reb.flatMap { rebValue in rebValue.isEmpty ? nil : rebValue }
        return cleanKeb ?? cleanReb
    }

    /// True when the entry is a JMnedict name entry.
    var isName: Bool {
        JMDictNameEntries.isName(entSeq: entSeq)
    }
}
