import Foundation
@testable import Mimidasu
import Testing

/// What a search hands back: every row the stages it ran found, and the
/// window's say over which stages ran at all. Everything here runs offline over
/// the fixture database.
@Suite("DictionarySearch paging")
struct DictionarySearchPagingTests {
    /// A state over the ordinary fixture: a handful of rows, every one of which
    /// fits a single page, so the window is all these cases have to narrow.
    private func makeFixture() throws -> DictionarySearchFixture {
        try DictionarySearchFixture()
    }

    /// A fixture holding `count` rows under one reading prefix — more than any
    /// window in these cases reaches, so paging has something to page through.
    private func makePagedFixture(_ count: Int) throws -> DictionarySearchFixture {
        try DictionarySearchFixture(extraWords: JMDictFixtureDatabase.bulkWords(
            count: count, readingPrefix: "かん", startingAt: 9_991_000
        ))
    }

    /// 60 rows whose reading *is* `かんそう` and 200 that merely start with it:
    /// a window of 50 saturates on the exact tier and skips the prefix scan, so
    /// the fixture can reproduce the one shape that costs a re-search.
    private func makeSkippedStageFixture() throws -> DictionarySearchFixture {
        try DictionarySearchFixture(extraWords: JMDictFixtureDatabase.bulkWords(
            reading: "かんそう", exactCount: 60, prefixCount: 200, startingAt: 9_992_000
        ))
    }

    @Test("returns every row it found, not just the window")
    func returnsEveryFoundRow() throws {
        // 120 rows, so no stage is ever skipped for want of window space: the
        // engine found them all and all of them are in the payload. Paging
        // slices this, so a row below the window costs two lookups to build
        // rather than a scan to find.
        let fixture = try makePagedFixture(120)

        let outcome = try fixture.outcome("かん")

        #expect(outcome.hits.count == 120)
        #expect(outcome.matchedCount == 120)
        #expect(!outcome.saturated)
    }

    @Test("a window one tier deep still reports the stage it skipped")
    func saturationIsPublished() throws {
        let fixture = try makeFixture()

        // Two exact あめ rows fill a window of one and the prefix tier is
        // strictly worse, so the ladder skipped it — which is exactly the
        // condition that says there are rows no click has seen yet. It also
        // cost the payload nothing: the exact tier's rows are all in hand.
        let outcome = try fixture.outcome("あめ", limit: 1)

        #expect(outcome.hits.count == 2)
        #expect(outcome.matchedCount == 2)
        #expect(outcome.saturated)
        // The full run of the same query reaches the rows the narrow one
        // declared invisible.
        #expect(try fixture.outcome("あめ").matchedCount == 4)
    }

    @Test("two windows over the same stages return one result set")
    func windowsAgreeOnFoundRows() throws {
        let fixture = try makePagedFixture(120)

        let first = try fixture.outcome("かん", limit: 50)
        let second = try fixture.outcome("かん", limit: 100)

        // Neither window was deep enough to change what ran, so the two searches
        // are the same search — which is what makes a reveal between them free.
        #expect(first.hits == second.hits)
        #expect(first.matchedCount == 120)
        #expect(!first.saturated)
        #expect(!second.saturated)
    }

    @Test("a probe that un-skips a stage only appends below the rows in hand")
    func probingAppendsBelowFoundRows() throws {
        let fixture = try makeSkippedStageFixture()

        let narrow = try fixture.outcome("かんそう", limit: 50)
        let deep = try fixture.outcome("かんそう", limit: 100)

        // The narrow window holds every exact row and has never seen a prefix
        // row; the deeper one ran the stage that was skipped.
        #expect(narrow.hits.count == 60)
        #expect(narrow.saturated)
        #expect(deep.hits.count == 260)
        #expect(!deep.saturated)
        // The rows already on screen are untouched — the skipped stage's rows
        // rank below all of them by construction, so paging still appends.
        #expect(Array(deep.hits.prefix(narrow.hits.count)) == narrow.hits)
        #expect(deep.matchedCount > narrow.matchedCount)
    }

    @Test("a window past the ceiling returns no more than the ceiling")
    func windowClampsToCeiling() throws {
        let ceiling = DictionarySearchEngine.maxRows
        let fixture = try makePagedFixture(ceiling + 100)

        let outcome = try fixture.outcome("かん", limit: ceiling + 500)

        #expect(outcome.hits.count == ceiling)
        // The rows past the ceiling still exist, and are still counted.
        #expect(outcome.matchedCount == ceiling + 100)
    }
}
