import Foundation
@testable import Mimidasu
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Builds a throwaway JMDict database from the committed fixture
/// (`Fixtures/jmdict-extended-sample.json`) for offline lookup tests. The
/// column mapping mirrors `scripts/build_dictionary.sh` exactly — JSON-encoded
/// `skeb`/`sreb` restriction lists (`*` → NULL), glosses joined with
/// `JMDictPin.glossJoiner`, `,`-joined POS, `", "`-joined misc — and the
/// schema mirrors the build's
/// WITHOUT ROWID tables (headwords keyed `(text, entry_id, kind)`, senses
/// keyed `(entry_id, ord)`), and its word headwords carry the same
/// enrichment `jmdict_build.py` applies before it writes — the JLPT
/// word-level fallback, the furigana-named pitch inheritance, and the
/// post-enrichment per-entry dedupe — while name-range entries stay
/// plain, so no row here is a shape the shipped database cannot hold in
/// either direction. The tests exercise the same data shapes and
/// row ordering the shipped database carries.
///
/// Nineteen synthetic entries are appended — seventeen in the word range and
/// two in the name range below — for coverage the real fixture lacks:
/// `9990010` 仮語/かご — uncommon entry whose senses exercise the
/// kanji-restriction rules (restricted to another writing, empty list =
/// matches none, unrestricted);
/// `9990020` 幽語/ゆうご — every sense restricted to a foreign kanji
/// writing, so its kanji candidate filters down to nothing;
/// `9990030` 雨/あめ — a homograph of the fixture's あめ (candy) with a
/// different commonness, pinning the common-first entry ranking;
/// `9990040` 尾/お — a hit for the bare honorific お, so the forward-
/// expansion suite can pin shorter-hit retention (compound お土産 displays,
/// the standalone お surface adds new entries as an "also:" result);
/// `9990050` 先/さき — carries 前 as an alternate kanji writing (the real
/// JMDict shape that makes 先 a homograph of 前), common;
/// `9990060` 前/まえ — uncommon, so the reading-match-first ranking can
/// pin itself above commonness on the shared 前 headword;
/// `9990070` 叉語/さご — a kanji-written homophone of the kana-only entry
/// below, common; both entries also carry the katakana shape サゴ the way
/// the build script stores both reading shapes;
/// `9990080` さご — kana-only, so the surface-match-first ranking can pin
/// the kana-written entry above the kanji homophone on the shared さご
/// headword;
/// `9990090` 呂敷/ろしき — a hit for the substring of 風呂敷 that crosses
/// the 風呂+敷 segment boundary, so the expansion suite can pin the
/// joined-text split fallback (tap 風呂: the join 風呂敷 displays, the
/// boundary-crossing 呂敷 split trails in "also");
/// `9990100` 雨村/あめむら — common, homograph of the JMnedict-shaped
/// entry `15668307` below, so the pager ranking can pin a common entry
/// leading while the name entry stays retained;
/// `9990110` カタ語/カタ語 — kanji and kana spellings coincide, each
/// carrying a different JLPT level and a different pitch (2/かた'ご on the
/// keb row vs 5 with a zo-only "LL" accent on the reb — no hatsuon or
/// accent pattern), so the entries join's kind predicate is pinned to the
/// keb row: exactly one row per entry ('keb' sorts before 'reb' under the
/// WITHOUT ROWID primary key, whatever the insertion order was), and the
/// winner is observable rather than a tie;
/// `9990120`–`9990140` 例子/れいし — a three-way homograph isolating the
/// commonness and ent_seq tiebreaks: the common `9990130` carries the
/// *highest* ent_seq, so common-first is observable only through the
/// commonness tier, and the two uncommon entries pin ent_seq-ascending
/// order within a tier (`9990120` < `9990140`);
/// `9990150` パイナップル — kana-only loanword whose stored row is
/// precomposed voiced/semi-voiced katakana, so the headword gate's
/// halfwidth probe (ﾊﾟｲﾅｯﾌﾟﾙ) can pin the composed fold onto it;
/// `9990160` ＴＫＧ/ティー・ケー・ジー — the raw-upstream fullwidth-Latin
/// initialism shape (ent_seq 2834407 in the shipped data). The fixture
/// normalizes every stored text at insert exactly as `jmdict_build.py`
/// does, so the writing lands as ASCII TKG and a fullwidth tap folds onto
/// it at the SQL boundary — the lookup path a search row's expand hands
/// the lookup engine;
/// `9990170` 4649/よろしく — a numeric kanji writing whose reading is kana,
/// the literal-spelling shape (the real 4649 is ent_seq 2846370). The digits
/// half is what the suite pins today: `DictionarySearchEngineSpellingTests`'s
/// `digitExact`/`digitPrefix` assert ent_seq 9_990_170. The kana reading makes
/// the entry reachable by romaji too, but no fixture-side test searches
/// `yoroshiku` yet — the shape carries both spellings, the suite only grades
/// one.
///
/// Two JMnedict-shaped name entries ride the offset ent_seq range the build
/// maps `int(id) + 10_000_000` into (JMnedict ids 5668306/5668307 →
/// 15668306/15668307): common=0, one flattened sense per entry, every name
/// type joined into `pos` —
/// `15668306` 木村/きむら — `place,surname` with the flattened gloss
/// "Kimura" (the real 木村 shape);
/// `15668307` 雨村/あめむら — `surname`, homograph of the common JMDict
/// entry `9990100` 雨村/あめむら, so the pager ranking can pin a common
/// entry leading while the name entry stays retained.
enum JMDictFixtureDatabase {
    /// The built database plus the directory it owns — `remove()` deletes
    /// both (test suites call it from `deinit`).
    struct Built {
        let url: URL

        func remove() {
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
    }

    enum FixtureError: Error {
        case sqlite(String)
        case badEntryID(String)
    }

    private final class BundleAnchor {}

    static func build(extraWords: [FixtureWord] = []) throws -> Built {
        let fixtureURL = try locateFixture()
        let data = try Data(contentsOf: fixtureURL)
        let fixture = try JSONDecoder().decode(FixtureEnvelope.self, from: data)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mimidasu-jmdict-fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("jmdict-fixture.sqlite")

        var db: OpaquePointer?
        guard sqlite3_open_v2(
            url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil
        ) == SQLITE_OK, let db else {
            let message = db.map { handle in String(cString: sqlite3_errmsg(handle)) } ?? "open failed"
            sqlite3_close_v2(db)
            throw FixtureError.sqlite(message)
        }
        defer { sqlite3_close_v2(db) }

        try exec(db, """
        CREATE TABLE entries(ent_seq INTEGER PRIMARY KEY, keb TEXT, reb TEXT, common INTEGER NOT NULL);
        CREATE TABLE senses(entry_id INTEGER NOT NULL REFERENCES entries(ent_seq),
          ord INTEGER NOT NULL, pos TEXT, gloss TEXT NOT NULL, misc TEXT, skeb TEXT, sreb TEXT,
          PRIMARY KEY(entry_id, ord)) WITHOUT ROWID;
        CREATE TABLE headwords(entry_id INTEGER NOT NULL REFERENCES entries(ent_seq),
          text TEXT NOT NULL, kind TEXT NOT NULL, jlpt INTEGER, hatsuon TEXT, acc TEXT, zo TEXT,
          PRIMARY KEY(text, entry_id, kind)) WITHOUT ROWID;
        CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT);
        """)
        // One explicit transaction around the whole build: without it every
        // row lands in its own implicit transaction, and an 8,001-row
        // headroom fixture spends ~8s in fsyncs alone. A throw mid-build
        // propagates with the transaction still open; closing the handle
        // (the `defer` above) rolls it back, so no explicit ROLLBACK is
        // needed on the error path.
        try exec(db, "BEGIN")
        for word in fixture.words + syntheticWords + extraWords {
            try insert(word, db)
        }
        // The gloss stage reads through the FTS5 index and has no `LIKE` fallback,
        // so a fixture without one silently loses every gloss hit — which no
        // assertion would catch, because the search would just return fewer
        // rows. Built from the production DDL rather than a paraphrase, so a
        // change to the index's shape or tokenizer options is exercised here
        // rather than only against the real database.
        try exec(db, JMDictFTSIndex.createSQL)
        try exec(db, JMDictFTSIndex.insertSQL)
        try exec(db, JMDictFTSIndex.optimizeSQL)
        try exec(db, "COMMIT")
        return Built(url: url)
    }

    /// Minimal three-table database: one headwords row whose entry_id has no
    /// matching entries row. Serves the orphan-shape paths the full fixture
    /// is unnecessary for.
    static func orphanHeadword() throws -> Built {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mimidasu-jmdict-orphan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("jmdict-orphan.sqlite")

        var db: OpaquePointer?
        guard sqlite3_open_v2(
            url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil
        ) == SQLITE_OK, let db else {
            let message = db.map { handle in String(cString: sqlite3_errmsg(handle)) } ?? "open failed"
            sqlite3_close_v2(db)
            throw FixtureError.sqlite(message)
        }
        defer { sqlite3_close_v2(db) }
        // The schema deliberately drops the build's WITHOUT ROWID primary
        // keys and REFERENCES clauses: the engine's queries depend only on
        // column names and order, which match the build's exactly.
        try exec(db, """
        CREATE TABLE entries(ent_seq INTEGER PRIMARY KEY, keb TEXT, reb TEXT, common INTEGER NOT NULL);
        CREATE TABLE senses(entry_id INTEGER NOT NULL, ord INTEGER NOT NULL, pos TEXT,
          gloss TEXT NOT NULL, misc TEXT, skeb TEXT, sreb TEXT);
        CREATE TABLE headwords(entry_id INTEGER NOT NULL, text TEXT NOT NULL, kind TEXT NOT NULL,
          jlpt INTEGER, hatsuon TEXT, acc TEXT, zo TEXT);
        INSERT INTO headwords VALUES (777, '孤語', 'keb', NULL, NULL, NULL, NULL);
        """)
        return Built(url: url)
    }

    private static func locateFixture() throws -> URL {
        let bundle = Bundle(for: BundleAnchor.self)
        guard let url = bundle.url(
            forResource: "jmdict-extended-sample", withExtension: "json"
        ) else {
            throw FixtureError.sqlite("fixture jmdict-extended-sample.json not in test bundle")
        }
        return url
    }

    // MARK: - Fixture decoding

    private struct FixtureEnvelope: Decodable {
        let words: [FixtureWord]
    }

    struct FixtureWord: Decodable {
        let id: String
        let kanji: [FixtureKanji]?
        let kana: [FixtureKana]?
        let sense: [FixtureSense]?
    }

    struct FixtureKanji: Decodable {
        let text: String
        let common: Bool
        let jlptLevel: Int?
        let pitchAccent: FixturePitch?
        /// Upstream's per-piece furigana. The builder rejoins it into the
        /// reading a kanji writing names (see `reading(for:)`); a synthetic
        /// entry carries none, which is the same as a writing upstream was
        /// given none.
        let furigana: [FixtureFurigana]?

        init(
            text: String, common: Bool, jlptLevel: Int?,
            pitchAccent: FixturePitch?, furigana: [FixtureFurigana]?
        ) {
            self.text = text
            self.common = common
            self.jlptLevel = jlptLevel
            self.pitchAccent = pitchAccent
            self.furigana = furigana
        }

        /// The shape every synthetic entry writes: a real upstream writing that
        /// upstream gave no furigana.
        init(text: String, common: Bool, jlptLevel: Int?, pitchAccent: FixturePitch?) {
            self.init(
                text: text, common: common, jlptLevel: jlptLevel,
                pitchAccent: pitchAccent, furigana: nil
            )
        }
    }

    struct FixtureFurigana: Decodable {
        /// The kanji (or okurigana) this piece covers.
        let ruby: String
        /// Its reading — omitted upstream when the reading *is* the ruby.
        let rt: String?
        /// What the piece contributes to the reading: the `rt` when there is
        /// a non-empty one, the ruby otherwise — the okurigana fallback, and
        /// the builder's `rt or ruby` also treats an empty `rt` as absent.
        var text: String {
            guard let rt, !rt.isEmpty else { return ruby }
            return rt
        }
    }

    struct FixtureKana: Decodable {
        let text: String
        let common: Bool
        let appliesToKanji: [String]?
        let jlptLevel: Int?
        let pitchAccent: FixturePitch?
    }

    struct FixtureSense: Decodable {
        let partOfSpeech: [String]?
        let appliesToKanji: [String]?
        let appliesToKana: [String]?
        let misc: [String]?
        let gloss: [FixtureGloss]?
    }

    struct FixtureGloss: Decodable {
        let lang: String?
        let text: String
    }

    /// Upstream writes the pitch accent as either a `{hatsuon, accPatts,
    /// zoPatts}` object or an empty list (never a non-empty one).
    struct FixturePitch: Decodable {
        let hatsuon: String?
        let accPatts: String?
        let zoPatts: String?

        init(hatsuon: String?, accPatts: String?, zoPatts: String?) {
            self.hatsuon = hatsuon
            self.accPatts = accPatts
            self.zoPatts = zoPatts
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let object = try? container.decode([String: String].self) {
                hatsuon = object["hatsuon"]
                accPatts = object["accPatts"]
                zoPatts = object["zoPatts"]
            } else {
                _ = try container.decode([String].self)
                hatsuon = nil
                accPatts = nil
                zoPatts = nil
            }
        }
    }

    private static var syntheticWords: [FixtureWord] {
        SyntheticWords.all
    }
}

// MARK: - Insertion (build-script mapping)

private extension JMDictFixtureDatabase {
    /// One headword row, already resolved against the builder's two rules.
    private struct Headword {
        let kind: String
        let text: String?
        let jlpt: Int?
        /// A pitch as the three columns it lands in.
        let accent: Accent
    }

    /// A pitch, or the all-null `noAccent` a writing with none carries — which
    /// is also the only shape a kanji row is allowed to inherit *over*.
    private struct Accent {
        let hatsuon: String?
        let acc: String?
        let zo: String?
    }

    /// The builder's dedupe key: one row per spelling-and-kind per entry.
    private struct RowKey: Hashable {
        let text: String?
        let kind: String
    }

    private static let noAccent = Accent(hatsuon: nil, acc: nil, zo: nil)

    private static func insert(_ word: FixtureWord, _ db: OpaquePointer) throws {
        guard let entSeq = Int(word.id) else {
            throw FixtureError.badEntryID(word.id)
        }
        let kanji = word.kanji ?? []
        let kana = word.kana ?? []
        let common = kanji.contains(where: \.common) || kana.contains(where: \.common)
        try insertRow(db, "INSERT INTO entries VALUES (?,?,?,?)", [
            .int(entSeq),
            .text(nfkc(kanji.first?.text)),
            .text(nfkc(kana.first?.text)),
            .int(common ? 1 : 0)
        ])
        // The builder dedupes per entry after enrichment: the NFKC fold can
        // land two of one entry's own same-kind writings on one PK, and the
        // first in source order wins.
        var seen = Set<RowKey>()
        let rows = headwordRows(entSeq: entSeq, kanji: kanji, kana: kana)
        for row in rows where seen.insert(RowKey(text: row.text, kind: row.kind)).inserted {
            try insertHeadword(db, entSeq: entSeq, row: row)
        }
        for (ord, sense) in (word.sense ?? []).enumerated() {
            let glosses = (sense.gloss ?? [])
                .filter { gloss in gloss.lang == "eng" }
                .map { gloss in nfkc(gloss.text) ?? "" }
                .joined(separator: String(JMDictPin.glossJoiner))
            try insertRow(db, "INSERT INTO senses VALUES (?,?,?,?,?,?,?)", [
                .int(entSeq),
                .int(ord),
                .text(joined(sense.partOfSpeech, separator: ",").map(ReadingAlignment.compatibilityComposed)),
                .text(glosses),
                .text(joined(sense.misc, separator: ", ").map(ReadingAlignment.compatibilityComposed)),
                .text(normalizedRestriction(sense.appliesToKanji)),
                .text(normalizedRestriction(sense.appliesToKana))
            ])
        }
    }

    /// The entry's headword rows in source order, as the builder writes them.
    ///
    /// `jmdict_build.py`'s `normalized_headword_rows` enriches every word
    /// headword row before it writes it, and the fixture mirrors it rule
    /// for rule. JLPT rides individual kanji writings upstream but reads
    /// as word-level in the card, so a writing with no level of its own
    /// takes the word's first non-null level in source order (kanji
    /// writings, then kana), whatever level that is — a writing carrying
    /// its own keeps it, which is why 彼処's kanji row keeps 1 while あそこ
    /// keeps its own 5. Pitch is per-reading and crosses one way only:
    /// a kanji row with no accent inherits the row its furigana names
    /// (お土産 → おみやげ), and a kana row never borrows. Name-range entries
    /// never reach any of this — the builder's names path writes plain
    /// rows — so they skip the enrichment here too. Breaking any of these
    /// stores rows no shipped artifact carries, and every assertion made
    /// against one pins the fixture rather than the app.
    private static func headwordRows(
        entSeq: Int, kanji: [FixtureKanji], kana: [FixtureKana]
    ) -> [Headword] {
        if entSeq >= JMDictNameEntries.ingestOffset {
            return kanji.map { object in
                Headword(kind: "keb", text: nfkc(object.text), jlpt: nil, accent: noAccent)
            } + kana.map { object in
                Headword(kind: "reb", text: nfkc(object.text), jlpt: nil, accent: noAccent)
            }
        }
        let fallbackLevel = jlptFallback(kanji: kanji, kana: kana)
        let kanaAccents = Dictionary(
            kana.map { object in (nfkc(object.text) ?? "", accent(of: object.pitchAccent) ?? noAccent) },
            uniquingKeysWith: { _, latest in latest }
        )
        return kanji.map { object in
            Headword(
                kind: "keb",
                text: nfkc(object.text),
                jlpt: object.jlptLevel ?? fallbackLevel,
                accent: accent(of: object.pitchAccent)
                    ?? reading(for: object).flatMap { reading in kanaAccents[reading] }
                    ?? noAccent
            )
        } + kana.map { object in
            Headword(
                kind: "reb",
                text: nfkc(object.text),
                jlpt: object.jlptLevel ?? fallbackLevel,
                accent: accent(of: object.pitchAccent) ?? noAccent
            )
        }
    }

    /// The word's first non-null level in source order — kanji writings, then
    /// kana — which is the builder's `jlpt_fallback`.
    private static func jlptFallback(kanji: [FixtureKanji], kana: [FixtureKana]) -> Int? {
        kanji.compactMap(\.jlptLevel).first ?? kana.compactMap(\.jlptLevel).first
    }

    /// A writing's own accent, or nil when it carries none of the three
    /// columns — the builder's "has no accent" test, and the only case that
    /// inherits one.
    private static func accent(of pitch: FixturePitch?) -> Accent? {
        guard let pitch, pitch.hatsuon != nil || pitch.accPatts != nil || pitch.zoPatts != nil
        else { return nil }
        return Accent(hatsuon: pitch.hatsuon, acc: pitch.accPatts, zo: pitch.zoPatts)
    }

    /// The reading a kanji writing's furigana names — the builder's
    /// `reading_for_keb`. Normalized onto the spelling the kana rows are keyed
    /// by, so a halfwidth reading still finds its row.
    private static func reading(for kanji: FixtureKanji) -> String? {
        let text = (kanji.furigana ?? []).map(\.text).joined()
        guard !text.isEmpty else { return nil }
        return nfkc(text)
    }

    private static func insertHeadword(
        _ db: OpaquePointer, entSeq: Int, row: Headword
    ) throws {
        try insertRow(db, "INSERT INTO headwords VALUES (?,?,?,?,?,?,?)", [
            .int(entSeq),
            .text(row.text),
            .text(row.kind),
            .int(row.jlpt),
            .text(row.accent.hatsuon),
            .text(row.accent.acc),
            .text(row.accent.zo)
        ])
    }

    /// `*` (and absence) = applies to every writing → NULL; otherwise the
    /// JSON array as stored, an empty list included (matches none). The
    /// stored writings fold onto the same canonical spellings the headwords
    /// carry — the lookup compares an NFKC-folded tap against them.
    private static func normalizedRestriction(_ list: [String]?) -> String? {
        guard let list, list != ["*"] else { return nil }
        let folded = list.map { writing in nfkc(writing) ?? writing }
        guard let data = try? JSONSerialization.data(withJSONObject: folded),
              let json = String(data: data, encoding: .utf8)
        else { return nil }
        return json
    }

    /// The build's one canonical form (`jmdict_build.py`'s `nfkc`): the
    /// app's query sides fold their probes with the same mapping, so the
    /// fixture's stored spellings must already carry it — a fullwidth-Latin
    /// writing lands as its ASCII form, exactly what the shipped database
    /// holds.
    private static func nfkc(_ text: String?) -> String? {
        text.map(ReadingAlignment.compatibilityComposed)
    }

    private static func joined(_ list: [String]?, separator: String) -> String? {
        guard let list, !list.isEmpty else { return nil }
        return list.joined(separator: separator)
    }

    // MARK: - SQLite plumbing

    private enum Value {
        case text(String?)
        case int(Int?)
    }

    private static func exec(_ db: OpaquePointer, _ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { pointer in String(cString: pointer) } ?? "unknown error"
            sqlite3_free(error)
            throw FixtureError.sqlite(message)
        }
    }

    private static func insertRow(
        _ db: OpaquePointer, _ sql: String, _ values: [Value]
    ) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw FixtureError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case let .text(string):
                if let string {
                    sqlite3_bind_text(statement, index, string, -1, sqliteTransient)
                } else {
                    sqlite3_bind_null(statement, index)
                }
            case let .int(integer):
                if let integer {
                    sqlite3_bind_int64(statement, index, Int64(integer))
                } else {
                    sqlite3_bind_null(statement, index)
                }
            }
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw FixtureError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
    }
}
