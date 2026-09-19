import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Builds a throwaway JMDict database from the committed fixture
/// (`Fixtures/jmdict-extended-sample.json`) for offline lookup tests. The
/// column mapping mirrors `scripts/build_dictionary.sh` exactly — JSON-encoded
/// `skeb`/`sreb` restriction lists (`*` → NULL), `"; "`-joined glosses,
/// `,`-joined POS, `", "`-joined misc — and the schema mirrors the build's
/// WITHOUT ROWID tables (headwords keyed `(text, entry_id, kind)`, senses
/// keyed `(entry_id, ord)`), so the tests exercise the same data shapes and
/// row ordering the shipped database carries.
///
/// Fourteen synthetic entries are appended for coverage the real fixture lacks:
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
/// carrying different JLPT/pitch metadata, so the first-row-wins metadata
/// pickup is pinned to the keb row ('keb' sorts before 'reb' under the
/// WITHOUT ROWID primary key, whatever the insertion order was);
/// `9990120`–`9990140` 例子/れいし — a three-way homograph isolating the
/// commonness and ent_seq tiebreaks: the common `9990130` carries the
/// *highest* ent_seq, so common-first is observable only through the
/// commonness tier, and the two uncommon entries pin ent_seq-ascending
/// order within a tier (`9990120` < `9990140`).
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

    static func build() throws -> Built {
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
        for word in fixture.words + syntheticWords {
            try insert(word, db)
        }
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

    private struct FixtureWord: Decodable {
        let id: String
        let kanji: [FixtureKanji]?
        let kana: [FixtureKana]?
        let sense: [FixtureSense]?
    }

    private struct FixtureKanji: Decodable {
        let text: String
        let common: Bool
        let jlptLevel: Int?
        let pitchAccent: FixturePitch?
    }

    private struct FixtureKana: Decodable {
        let text: String
        let common: Bool
        let appliesToKanji: [String]?
        let jlptLevel: Int?
        let pitchAccent: FixturePitch?
    }

    private struct FixtureSense: Decodable {
        let partOfSpeech: [String]?
        let appliesToKanji: [String]?
        let appliesToKana: [String]?
        let misc: [String]?
        let gloss: [FixtureGloss]?
    }

    private struct FixtureGloss: Decodable {
        let lang: String?
        let text: String
    }

    /// Upstream writes the pitch accent as either a `{hatsuon, accPatts,
    /// zoPatts}` object or an empty list (never a non-empty one).
    private struct FixturePitch: Decodable {
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

// MARK: - Synthetic entries

/// The synthetic entries themselves, split out of the database builder's
/// type body. See `JMDictFixtureDatabase`'s doc comment for what each pins.
private extension JMDictFixtureDatabase {
    private enum SyntheticWords {
        fileprivate static let all: [FixtureWord] = [
            FixtureWord(
                id: "9990010",
                kanji: [FixtureKanji(text: "仮語", common: false, jlptLevel: nil, pitchAccent: nil)],
                kana: [FixtureKana(
                    text: "かご", common: false, appliesToKanji: ["*"], jlptLevel: nil,
                    pitchAccent: nil
                )],
                sense: [
                    FixtureSense(
                        partOfSpeech: ["n"], appliesToKanji: ["他語"], appliesToKana: nil,
                        misc: nil,
                        gloss: [FixtureGloss(lang: "eng", text: "restricted to another writing")]
                    ),
                    FixtureSense(
                        partOfSpeech: ["n"], appliesToKanji: [], appliesToKana: nil, misc: nil,
                        gloss: [FixtureGloss(lang: "eng", text: "matches no writing")]
                    ),
                    FixtureSense(
                        partOfSpeech: ["n"], appliesToKanji: nil, appliesToKana: nil, misc: nil,
                        gloss: [FixtureGloss(lang: "eng", text: "applies to every writing")]
                    )
                ]
            ),
            FixtureWord(
                id: "9990020",
                kanji: [FixtureKanji(text: "幽語", common: false, jlptLevel: nil, pitchAccent: nil)],
                kana: [FixtureKana(
                    text: "ゆうご", common: false, appliesToKanji: ["*"], jlptLevel: nil,
                    pitchAccent: nil
                )],
                sense: [
                    FixtureSense(
                        partOfSpeech: ["n"], appliesToKanji: ["別語"], appliesToKana: nil,
                        misc: nil,
                        gloss: [FixtureGloss(lang: "eng", text: "foreign restriction")]
                    )
                ]
            ),
            FixtureWord(
                id: "9990030",
                kanji: [FixtureKanji(text: "雨", common: false, jlptLevel: 5, pitchAccent: nil)],
                kana: [FixtureKana(
                    text: "あめ", common: false, appliesToKanji: ["*"], jlptLevel: nil,
                    pitchAccent: nil
                )],
                sense: [
                    FixtureSense(
                        partOfSpeech: ["n"], appliesToKanji: nil, appliesToKana: nil, misc: nil,
                        gloss: [FixtureGloss(lang: "eng", text: "rain")]
                    )
                ]
            ),
            FixtureWord(
                id: "9990040",
                kanji: [FixtureKanji(text: "尾", common: false, jlptLevel: nil, pitchAccent: nil)],
                kana: [FixtureKana(
                    text: "お", common: false, appliesToKanji: ["*"], jlptLevel: nil,
                    pitchAccent: nil
                )],
                sense: [
                    FixtureSense(
                        partOfSpeech: ["n"], appliesToKanji: nil, appliesToKana: nil, misc: nil,
                        gloss: [FixtureGloss(lang: "eng", text: "tail")]
                    )
                ]
            ),
            FixtureWord(
                id: "9990050",
                kanji: [
                    FixtureKanji(text: "先", common: true, jlptLevel: nil, pitchAccent: nil),
                    FixtureKanji(text: "前", common: true, jlptLevel: nil, pitchAccent: nil)
                ],
                kana: [FixtureKana(
                    text: "さき", common: true, appliesToKanji: ["*"], jlptLevel: nil,
                    pitchAccent: nil
                )],
                sense: [
                    FixtureSense(
                        partOfSpeech: ["n"], appliesToKanji: nil, appliesToKana: nil, misc: nil,
                        gloss: [FixtureGloss(lang: "eng", text: "point; tip; end")]
                    )
                ]
            ),
            FixtureWord(
                id: "9990060",
                kanji: [FixtureKanji(text: "前", common: false, jlptLevel: 5, pitchAccent: nil)],
                kana: [FixtureKana(
                    text: "まえ", common: false, appliesToKanji: ["*"], jlptLevel: nil,
                    pitchAccent: nil
                )],
                sense: [
                    FixtureSense(
                        partOfSpeech: ["n"], appliesToKanji: nil, appliesToKana: nil, misc: nil,
                        gloss: [FixtureGloss(lang: "eng", text: "front; before")]
                    )
                ]
            ),
            FixtureWord(
                id: "9990070",
                kanji: [FixtureKanji(text: "叉語", common: true, jlptLevel: nil, pitchAccent: nil)],
                kana: [
                    FixtureKana(text: "さご", common: true, appliesToKanji: ["*"], jlptLevel: nil, pitchAccent: nil),
                    FixtureKana(text: "サゴ", common: true, appliesToKanji: nil, jlptLevel: nil, pitchAccent: nil)
                ],
                sense: [
                    FixtureSense(
                        partOfSpeech: ["n"], appliesToKanji: nil, appliesToKana: nil, misc: nil,
                        gloss: [FixtureGloss(lang: "eng", text: "kanji-written homophone")]
                    )
                ]
            ),
            FixtureWord(
                id: "9990080",
                kanji: nil,
                kana: [
                    FixtureKana(text: "さご", common: true, appliesToKanji: nil, jlptLevel: nil, pitchAccent: nil),
                    FixtureKana(text: "サゴ", common: true, appliesToKanji: nil, jlptLevel: nil, pitchAccent: nil)
                ],
                sense: [
                    FixtureSense(
                        partOfSpeech: ["n"], appliesToKanji: nil, appliesToKana: nil, misc: nil,
                        gloss: [FixtureGloss(lang: "eng", text: "kana-written homophone")]
                    )
                ]
            ),
            FixtureWord(
                id: "9990090",
                kanji: [FixtureKanji(text: "呂敷", common: false, jlptLevel: nil, pitchAccent: nil)],
                kana: [FixtureKana(
                    text: "ろしき", common: false, appliesToKanji: ["*"], jlptLevel: nil,
                    pitchAccent: nil
                )],
                sense: [
                    FixtureSense(
                        partOfSpeech: ["n"], appliesToKanji: nil, appliesToKana: nil, misc: nil,
                        gloss: [FixtureGloss(lang: "eng", text: "boundary-crossing split hit")]
                    )
                ]
            ),
            FixtureWord(
                id: "9990100",
                kanji: [FixtureKanji(text: "雨村", common: true, jlptLevel: nil, pitchAccent: nil)],
                kana: [FixtureKana(
                    text: "あめむら", common: true, appliesToKanji: ["*"], jlptLevel: nil,
                    pitchAccent: nil
                )],
                sense: [
                    FixtureSense(
                        partOfSpeech: ["n"], appliesToKanji: nil, appliesToKana: nil, misc: nil,
                        gloss: [FixtureGloss(lang: "eng", text: "village rain")]
                    )
                ]
            ),
            FixtureWord(
                id: "9990110",
                kanji: [FixtureKanji(
                    text: "カタ語", common: false, jlptLevel: 2,
                    pitchAccent: FixturePitch(hatsuon: "かた'ご", accPatts: "2", zoPatts: "HH")
                )],
                kana: [FixtureKana(
                    text: "カタ語", common: false, appliesToKanji: ["*"], jlptLevel: nil,
                    pitchAccent: FixturePitch(hatsuon: nil, accPatts: nil, zoPatts: "LL")
                )],
                sense: [
                    FixtureSense(
                        partOfSpeech: ["n"], appliesToKanji: nil, appliesToKana: nil, misc: nil,
                        gloss: [FixtureGloss(lang: "eng", text: "coincident spelling")]
                    )
                ]
            ),
            FixtureWord(
                id: "9990120",
                kanji: [FixtureKanji(text: "例子", common: false, jlptLevel: nil, pitchAccent: nil)],
                kana: [FixtureKana(
                    text: "れいし", common: false, appliesToKanji: ["*"], jlptLevel: nil,
                    pitchAccent: nil
                )],
                sense: [
                    FixtureSense(
                        partOfSpeech: ["n"], appliesToKanji: nil, appliesToKana: nil, misc: nil,
                        gloss: [FixtureGloss(lang: "eng", text: "uncommon homograph, lower seq")]
                    )
                ]
            ),
            FixtureWord(
                id: "9990130",
                kanji: [FixtureKanji(text: "例子", common: true, jlptLevel: nil, pitchAccent: nil)],
                kana: [FixtureKana(
                    text: "れいし", common: true, appliesToKanji: ["*"], jlptLevel: nil,
                    pitchAccent: nil
                )],
                sense: [
                    FixtureSense(
                        partOfSpeech: ["n"], appliesToKanji: nil, appliesToKana: nil, misc: nil,
                        gloss: [FixtureGloss(lang: "eng", text: "common homograph, higher seq")]
                    )
                ]
            ),
            FixtureWord(
                id: "9990140",
                kanji: [FixtureKanji(text: "例子", common: false, jlptLevel: nil, pitchAccent: nil)],
                kana: [FixtureKana(
                    text: "れいし", common: false, appliesToKanji: ["*"], jlptLevel: nil,
                    pitchAccent: nil
                )],
                sense: [
                    FixtureSense(
                        partOfSpeech: ["n"], appliesToKanji: nil, appliesToKana: nil, misc: nil,
                        gloss: [FixtureGloss(lang: "eng", text: "uncommon homograph, higher seq")]
                    )
                ]
            ),
            FixtureWord(
                id: "15668306",
                kanji: [FixtureKanji(text: "木村", common: false, jlptLevel: nil, pitchAccent: nil)],
                kana: [FixtureKana(
                    text: "きむら", common: false, appliesToKanji: ["*"], jlptLevel: nil,
                    pitchAccent: nil
                )],
                sense: [
                    FixtureSense(
                        partOfSpeech: ["place", "surname"], appliesToKanji: nil, appliesToKana: nil,
                        misc: nil,
                        gloss: [FixtureGloss(lang: "eng", text: "Kimura")]
                    )
                ]
            ),
            FixtureWord(
                id: "15668307",
                kanji: [FixtureKanji(text: "雨村", common: false, jlptLevel: nil, pitchAccent: nil)],
                kana: [FixtureKana(
                    text: "あめむら", common: false, appliesToKanji: ["*"], jlptLevel: nil,
                    pitchAccent: nil
                )],
                sense: [
                    FixtureSense(
                        partOfSpeech: ["surname"], appliesToKanji: nil, appliesToKana: nil,
                        misc: nil,
                        gloss: [FixtureGloss(lang: "eng", text: "Amemura (surname)")]
                    )
                ]
            )
        ]
    }
}

// MARK: - Insertion (build-script mapping)

private extension JMDictFixtureDatabase {
    private static func insert(_ word: FixtureWord, _ db: OpaquePointer) throws {
        guard let entSeq = Int(word.id) else {
            throw FixtureError.badEntryID(word.id)
        }
        let kanji = word.kanji ?? []
        let kana = word.kana ?? []
        let common = kanji.contains(where: \.common) || kana.contains(where: \.common)
        try insertRow(db, "INSERT INTO entries VALUES (?,?,?,?)", [
            .int(entSeq),
            .text(kanji.first?.text),
            .text(kana.first?.text),
            .int(common ? 1 : 0)
        ])
        for object in kanji {
            try insertHeadword(db, entSeq: entSeq, kind: "keb", object: object)
        }
        for object in kana {
            try insertHeadword(db, entSeq: entSeq, kind: "reb", object: object)
        }
        for (ord, sense) in (word.sense ?? []).enumerated() {
            let glosses = (sense.gloss ?? [])
                .filter { gloss in gloss.lang == "eng" }
                .map(\.text)
                .joined(separator: "; ")
            try insertRow(db, "INSERT INTO senses VALUES (?,?,?,?,?,?,?)", [
                .int(entSeq),
                .int(ord),
                .text(joined(sense.partOfSpeech, separator: ",")),
                .text(glosses),
                .text(joined(sense.misc, separator: ", ")),
                .text(normalizedRestriction(sense.appliesToKanji)),
                .text(normalizedRestriction(sense.appliesToKana))
            ])
        }
    }

    private static func insertHeadword(
        _ db: OpaquePointer, entSeq: Int, kind: String, object: FixtureKanji
    ) throws {
        try insertRow(db, "INSERT INTO headwords VALUES (?,?,?,?,?,?,?)", [
            .int(entSeq),
            .text(object.text),
            .text(kind),
            .int(object.jlptLevel),
            .text(object.pitchAccent?.hatsuon),
            .text(object.pitchAccent?.accPatts),
            .text(object.pitchAccent?.zoPatts)
        ])
    }

    private static func insertHeadword(
        _ db: OpaquePointer, entSeq: Int, kind: String, object: FixtureKana
    ) throws {
        try insertRow(db, "INSERT INTO headwords VALUES (?,?,?,?,?,?,?)", [
            .int(entSeq),
            .text(object.text),
            .text(kind),
            .int(object.jlptLevel),
            .text(object.pitchAccent?.hatsuon),
            .text(object.pitchAccent?.accPatts),
            .text(object.pitchAccent?.zoPatts)
        ])
    }

    /// `*` (and absence) = applies to every writing → NULL; otherwise the
    /// JSON array as stored, an empty list included (matches none).
    private static func normalizedRestriction(_ list: [String]?) -> String? {
        guard let list, list != ["*"] else { return nil }
        guard let data = try? JSONSerialization.data(withJSONObject: list),
              let json = String(data: data, encoding: .utf8)
        else { return nil }
        return json
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
