import Foundation
@testable import Mimidasu
import Testing

/// What a collapsed search row's badge line claims, and the engine plumbing
/// that feeds it.
///
/// Two of these cases exist because the badges used to disagree with themselves:
/// the collapsed header rendered `COMMON` and the match tier but dropped `≈N`
/// for a gloss-tier hit (the gloss scan never touches `headwords`, so the level
/// had nowhere to come from), and a name row read as a generic `NAME` chip
/// while its expanded block carried the real types. Now that the expanded block
/// renders no badges at all, the header is the only place either fact appears.
///
/// Split from the two main suites to keep them inside the type-body ceiling;
/// the fixture harness is the same one line for line.
@Suite("DictionarySearchEngine badge metadata")
final class DictionarySearchEngineBadgeTests {
    private let fixture: DictionarySearchFixture

    init() throws {
        fixture = try DictionarySearchFixture()
    }

    private func search(_ query: String) throws -> DictionarySearchOutcome {
        try fixture.outcome(query)
    }

    // MARK: JLPT level

    /// The badge a collapsed row shows and the one its expanded entry shows must
    /// be the same level. `candy` only ever reaches 飴 through its English gloss,
    /// and the gloss stage scans `senses` — which has no JLPT column — so the
    /// `entries` join is the only place its level can come from.
    @Test("a gloss-tier hit still reports the entry's JLPT level")
    func glossHitCarriesJLPT() throws {
        let hit = try #require(search("candy").hits.first)

        #expect(hit.matchKind == .glossWordBoundary || hit.matchKind == .glossPrefix)
        #expect(hit.jlpt == 5)
        #expect(DictionaryContent.jlptBadge(hit.jlpt) == "≈N5")
    }

    /// The join is a fallback, not an override: a headword-tier row matched a
    /// specific writing and keeps that writing's level, which is the more
    /// precise answer of the two.
    @Test("a headword-tier hit keeps the level of the writing it matched")
    func headwordHitKeepsRowJLPT() throws {
        let hit = try #require(search("食べる").hits.first)

        #expect(hit.matchKind == .exact)
        #expect(hit.jlpt == 5)
    }

    // MARK: Name types

    /// A name row's collapsed header is now the only place its types appear, so
    /// the tags have to survive the engine intact and reach the shared mapping.
    /// 木村 is stored `place,surname` under one flattened sense.
    @Test("a name hit carries the type tags its header renders")
    func nameHitCarriesTypeTags() throws {
        let hit = try #require(search("Kimura").hits.first)

        #expect(hit.namePosTokens == ["place,surname"])
        #expect(
            DictionaryContent.nameTypeBadges(posTokens: hit.namePosTokens)
                == ["PLACE NAME", "SURNAME"]
        )
    }

    /// A word entry contributes no type badges: its POS tags belong in the sense
    /// row, and an untagged entry renders nothing rather than a chip claiming a
    /// type it does not have.
    @Test("a word hit carries no name tags", arguments: ["食べる", "たべる"])
    func wordHitHasNoNameTags(query: String) throws {
        let hit = try #require(search(query).hits.first)

        #expect(!hit.isName)
        #expect(hit.namePosTokens.isEmpty)
        #expect(DictionaryContent.nameTypeBadges(posTokens: hit.namePosTokens).isEmpty)
    }

    // MARK: Assembly seams

    @Test("the row's own level wins, and the entry's is the fallback")
    func hitLevelPrefersTheMatchedRow() throws {
        let metadata = DictionarySearchEngine.EntryMetadata(
            entSeq: 5, keb: "検", reb: "けん", common: true, jlpt: 3
        )
        func level(_ rowLevel: Int?) throws -> Int? {
            try DictionarySearchEngine.hit(
                for: .init(
                    row: .init(
                        entryID: 5, matchedField: .gloss, matchKind: .glossWordBoundary,
                        jlpt: rowLevel, matchedLength: 9, highlightRange: 0 ..< 4,
                        matchedGloss: "inspection"
                    ),
                    metadata: metadata
                ),
                preview: ["inspection"], nameTypes: []
            ).jlpt
        }
        // A headword-stage row keeps the level of the exact writing it matched,
        // even where the entry's kanji writing disagrees.
        #expect(try level(5) == 5)
        // The gloss stage carries none, so it reads the entry's.
        #expect(try level(nil) == 3)
    }

    /// The entries join must read the level off the kanji writing through
    /// `headwords.text` — the leading column of that table's primary key.
    /// Anything else (a scan on `entry_id`, a join the planner cannot seek)
    /// would turn every keystroke's metadata fetch into a table walk.
    @Test("the entries join seeks headwords by its leading primary-key column")
    func entriesJoinIsASeek() {
        let sql = DictionarySearchEngine.entriesSQL(count: 2)

        #expect(sql.contains("LEFT JOIN headwords h ON h.text = e.keb"))
        #expect(sql.contains("h.entry_id = e.ent_seq"))
    }

    @Test("the name-type fetch is a chunked primary-key range scan")
    func namePosSQLShape() {
        let sql = DictionarySearchEngine.namePosSQL(count: 2)

        #expect(sql.contains("IN (?,?)"))
        // Sense order is what makes the badge list deterministic.
        #expect(sql.contains("ORDER BY entry_id, ord"))
    }
}
