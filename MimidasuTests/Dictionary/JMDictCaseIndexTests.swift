import Foundation
@testable import Mimidasu
import SQLite3
import Testing

/// The derived index the engine's case-spelling load rides.
///
/// The index ships inside the bundled artifact, built by the ingestion
/// script; the app has no writer for it. Every test works on its own copy of
/// a throwaway fixture database and applies `createSQL` directly — the same
/// statement the ingestion build executes — which keeps the DDL honest: if
/// it ever stops producing an index the planner will serve the load from,
/// these tests are where that shows.
@Suite("JMDict case index")
final class JMDictCaseIndexTests {
    private let directory: URL
    private let source: DictionarySearchFixture

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mimidasu-case-index-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // `ActiveX` and the Greek capital `Α` are the two shapes the pinned
        // corpus carries that the ASCII predicate alone does not select.
        source = try DictionarySearchFixture(extraWords: [
            JMDictFixtureDatabase.FixtureWord(
                id: "9990200",
                kanji: [JMDictFixtureDatabase.FixtureKanji(
                    text: "ActiveX", common: false, jlptLevel: nil, pitchAccent: nil
                )],
                kana: nil,
                sense: [JMDictFixtureDatabase.FixtureSense(
                    partOfSpeech: ["n"], appliesToKanji: nil, appliesToKana: nil, misc: nil,
                    gloss: [JMDictFixtureDatabase.FixtureGloss(
                        lang: "eng", text: "a COM programming environment"
                    )]
                )]
            ),
            JMDictFixtureDatabase.FixtureWord(
                id: "9990210",
                kanji: [JMDictFixtureDatabase.FixtureKanji(
                    text: "Α", common: false, jlptLevel: nil, pitchAccent: nil
                )],
                kana: nil,
                sense: [JMDictFixtureDatabase.FixtureSense(
                    partOfSpeech: ["n"], appliesToKanji: nil, appliesToKana: nil, misc: nil,
                    gloss: [JMDictFixtureDatabase.FixtureGloss(
                        lang: "eng", text: "the Greek letter alpha"
                    )]
                )]
            )
        ])
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    /// A writable copy — the fixture's own file is the one the engine reads.
    private func stagedCopy() throws -> URL {
        let copy = directory.appendingPathComponent("staged.sqlite")
        try FileManager.default.copyItem(at: source.url, to: copy)
        return copy
    }

    /// Applies the ingestion build's DDL to a database, the way
    /// `scripts/jmdict_build.py` does before compressing the artifact.
    private func applyCaseIndexDDL(at url: URL) throws {
        let database = try SQLiteDatabase.writable(path: url.path)
        defer { database.close() }
        try database.execute(JMDictCaseIndex.createSQL)
    }

    /// Whether the database carries an index under the pinned name.
    private func carriesCaseIndex(at url: URL) throws -> Bool {
        let database = try SQLiteDatabase(path: url.path)
        defer { database.close() }
        let presence = try database.statement(
            "SELECT 1 FROM sqlite_master WHERE type = 'index'"
                + " AND name = '\(JMDictCaseIndex.indexName)'"
        )
        return try presence.step()
    }

    @Test("executing the DDL leaves the index on the database")
    func ddlMakesItPresent() throws {
        let url = try stagedCopy()

        try applyCaseIndexDDL(at: url)

        #expect(try carriesCaseIndex(at: url))
    }

    @Test("a database the DDL never ran on reports no index")
    func absentBeforeDDL() throws {
        #expect(try carriesCaseIndex(at: source.url) == false)
    }

    @Test("the load is answered by the index rather than by a walk of the table")
    func loadRidesTheIndex() throws {
        let url = try stagedCopy()
        try applyCaseIndexDDL(at: url)
        let database = try SQLiteDatabase(path: url.path)
        defer { database.close() }

        let plan = try database.statement("EXPLAIN QUERY PLAN \(JMDictCaseIndex.loadSQL)")
        #expect(try plan.step())
        let detail = try #require(plan.optionalText(3))

        #expect(detail.contains(JMDictCaseIndex.indexName))
    }

    @Test("the non-ASCII load reads the case blocks the ASCII predicate skips")
    func nonASCIILoadFindsTheGreekName() throws {
        let database = try SQLiteDatabase(path: source.url.path)
        defer { database.close() }
        let spellings = try CaseHeadwordSpellings(db: database)

        let greek = try #require(spellings.matches(openingFold: "α").first)

        #expect(greek.spelling == "Α")
        #expect(greek.isExact)
    }

    @Test("the loaded set reaches the ASCII case through the same door")
    func asciiLoadFindsTheMixedCaseName() throws {
        let database = try SQLiteDatabase(path: source.url.path)
        defer { database.close() }
        let spellings = try CaseHeadwordSpellings(db: database)

        let mixed = try #require(spellings.matches(openingFold: "activex").first)

        #expect(mixed.spelling == "ActiveX")
    }
}
