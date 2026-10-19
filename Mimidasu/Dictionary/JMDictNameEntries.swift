import Foundation

/// The JMnedict half of the prepared database. Name entries ride the same
/// `entries`/`headwords`/`senses` tables as JMDict under an ingest offset —
/// an `ent_seq` at or above `ingestOffset` is a name — and their entity
/// types are stored as raw `pos` tags. This module owns the boundary, the
/// predicate, and the type-tag vocabulary; the engine and the UI read them
/// from here.
enum JMDictNameEntries {
    /// JMnedict ingest offset: name entries ride `ent_seq + 10M`, above
    /// every JMDict row. Mirrors `NAME_SEQ_OFFSET` in jmdict_build.py.
    static let ingestOffset = 10_000_000

    /// True when `entSeq` is a JMnedict name entry (at or above the offset).
    static func isName(entSeq: Int) -> Bool {
        entSeq >= ingestOffset
    }

    /// True when the entry is a JMnedict name (person, place, company, …).
    static func isName(_ entry: JMDictEntry) -> Bool {
        isName(entSeq: entry.entSeq)
    }

    /// The badge label for a stored name-type tag, or nil when the tag is
    /// not a name type (a JMDict POS tag, a retired upstream type).
    static func typeLabel(for tag: String) -> String? {
        typeLabels[tag]
    }

    /// Badge-row labels for a name entry: every comma-split pos token
    /// mapped through the friendly labels, deduped in order (`fem`/`given`
    /// both land on GIVEN NAME); rare unmapped types pass through verbatim.
    /// Word entries contribute nothing — their POS tags stay in the sense
    /// row.
    static func nameTypeBadges(for entry: JMDictEntry) -> [String] {
        guard isName(entry) else { return [] }
        return nameTypeBadges(posTokens: entry.senses.map(\.pos))
    }

    /// The same mapping over raw stored `pos` columns, for a host that has
    /// the tags rather than a whole entry — the search row and the
    /// name-type filter. Sharing this entry point is what keeps a collapsed
    /// search row and an expanded entry from labelling the same name
    /// differently.
    static func nameTypeBadges(posTokens: [String?]) -> [String] {
        var badges: [String] = []
        for column in posTokens {
            for token in column?.components(separatedBy: ",") ?? [] {
                let tag = token.trimmingCharacters(in: .whitespaces)
                guard !tag.isEmpty else { continue }
                let badge = typeLabels[tag] ?? tag
                if !badges.contains(badge) {
                    badges.append(badge)
                }
            }
        }
        return badges
    }

    /// The filter row's vocabulary: every type label, alphabetical.
    static let allBadges: [String] = Set(typeLabels.values).sorted()

    /// JMnedict name type → badge label. The rows cover the pinned corpus's
    /// full upstream vocabulary (its `tags` table, uppercased minus a
    /// redundant "name" suffix); a tag the map lacks — a future or retired
    /// upstream type, or a JMDict POS tag — falls through verbatim.
    private static let typeLabels = [
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
        "unclass": "NAME",
        "serv": "SERVICE",
        "char": "CHARACTER",
        "fict": "FICTION",
        "ev": "EVENT",
        "group": "GROUP",
        "dei": "DEITY",
        "obj": "OBJECT",
        "myth": "MYTHOLOGY",
        "doc": "DOCUMENT",
        "creat": "CREATURE",
        "ship": "SHIP",
        "leg": "LEGEND",
        "relig": "RELIGION"
    ]
}
