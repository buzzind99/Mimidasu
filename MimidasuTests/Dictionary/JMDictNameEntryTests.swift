import Foundation
@testable import Mimidasu
import Testing

/// JMnedict name entries riding the same `entries`/`headwords`/`senses`
/// tables as JMDict under the offset ent_seq range (`int(id) + 10_000_000`):
/// the lookup, pager ranking, and reading fallback must resolve them with
/// zero JMnedict-specific query paths, and the WITHOUT ROWID primary key
/// must keep the coincident-spelling metadata pickup keb-first.
@Suite("JMDictLookup JMnedict name entries")
final class JMDictNameEntryTests {
    private let databaseURL: URL
    private let engine: JMDictLookup

    init() throws {
        let built = try JMDictFixtureDatabase.build()
        databaseURL = built.url
        engine = JMDictLookup(resolveDatabase: { [url = built.url] in url })
    }

    deinit {
        // Close before unlinking — SQLite warns loudly about vnodes removed
        // underneath an open handle.
        engine.close()
        JMDictFixtureDatabase.Built(url: databaseURL).remove()
    }

    @Test("resolves a JMnedict name entry through its offset-range ent_seq")
    func nameEntryHit() throws {
        let result = try #require(try engine.lookup(LookupCandidate(text: "木村")))

        #expect(result.matched == "木村")
        let entry = try #require(result.entries.first)
        #expect(entry.entSeq == 15_668_306)
        #expect(entry.keb == "木村")
        #expect(entry.reb == "きむら")
        #expect(!entry.common, "JMnedict rows carry no common marking")
        #expect(entry.jlpt == nil)
        #expect(entry.hatsuon == nil)
        #expect(entry.senses.count == 1)
        #expect(entry.senses[0].pos == "place,surname", "kept names record every type in pos")
        #expect(entry.senses[0].glosses == ["Kimura"])
    }

    @Test("a common JMDict entry leads the pager over a same-text name entry")
    func commonLeadsNameRetained() throws {
        let result = try #require(try engine.lookup(LookupCandidate(text: "雨村")))

        #expect(result.entries.map(\.entSeq) == [9_990_100, 15_668_307])
        #expect(result.entries.map(\.common) == [true, false])
        #expect(result.entries[1].senses[0].pos == "surname")
    }

    @Test("reading fallback answers a name keb row from the JMnedict offset range")
    func nameReadingFallback() throws {
        let reading = try #require(try engine.reading(forWriting: "木村"))

        #expect(reading == "きむら")
    }

    @Test("coincident keb==reb spelling picks the keb row's metadata")
    func coincidentSpellingKebFirst() throws {
        let result = try #require(try engine.lookup(LookupCandidate(text: "カタ語")))

        let entry = try #require(result.entries.first)
        #expect(entry.entSeq == 9_990_110)
        #expect(entry.jlpt == 2, "the keb row wins ('keb' sorts before 'reb' under the PK)")
        #expect(entry.hatsuon == "かた'ご")
        #expect(entry.zoPatts == "HH")
    }
}
