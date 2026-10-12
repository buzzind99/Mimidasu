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

    /// 120 rows under `かん`, a third of them common: the shape a `mak` search
    /// has. A window of 50 saturates on the prefix tier while the common filter
    /// holds the answer to a third of it, so `commonOnly` and the gloss tier
    /// pending behind it are the two things the window cannot measure.
    private func makeCommonFilteredFixture() throws -> DictionarySearchFixture {
        try DictionarySearchFixture(extraWords: JMDictFixtureDatabase.bulkWords(
            count: 120, readingPrefix: "かん", startingAt: 9_993_000
        ))
    }

    /// `headroom + 1` rows under one reading prefix: exactly one row past what
    /// the prefix stage's own `prefixFetchHeadroom` keeps, so the survivors
    /// behind that bound are the whole of what this fixture can prove. `かん`
    /// prefixes nothing in the base fixture, so the count is exact. The rows
    /// and the margin under `DictionaryContent.nameSeqOffset` are the shared
    /// `headroomBoundWords` factory's — see it for the straddle this replaced.
    private func makeHeadroomBoundFixture() throws -> DictionarySearchFixture {
        try DictionarySearchFixture(
            extraWords: JMDictFixtureDatabase.headroomBoundWords()
        )
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

    @Test("a headroom-bound scan publishes its total as a floor")
    func headroomBoundPublishesAFloor() throws {
        let headroom = DictionarySearchEngine.prefixFetchHeadroom
        let fixture = try makeHeadroomBoundFixture()

        let outcome = try fixture.outcome("かん")

        // The scan found one row more than the headroom keeps, so the row
        // behind it is in neither `hits` nor `matchedCount` — and the total says
        // so, rather than reading `8000` as the whole of `かん`. This is the
        // `ma` case: a 1-mora scan truncated at a constant, with nothing marking
        // the count as short of the answer.
        #expect(outcome.matchedCount == headroom)
        #expect(outcome.truncated)
        #expect(outcome.isFloor)
        // Nothing was skipped. `かん` is Japanese, so the gloss stage was never
        // a candidate and there was no tier for the window to saturate against.
        // The two facts are independent, and only one of them is a stage.
        #expect(outcome.saturated == false)
    }

    @Test("no window lifts a bound, so paging cannot un-truncate it")
    func pagingCannotUnTruncate() throws {
        let fixture = try makeHeadroomBoundFixture()

        let narrow = try fixture.outcome("かん", limit: DictionarySearchEngine.pageSize)
        let deep = try fixture.outcome("かん", limit: DictionarySearchEngine.maxRows)

        // Both bounds are constants rather than functions of the caller's
        // limit, so the deeper search runs the same scan, stops in the same
        // place, and reports the same floor. That is the whole difference from
        // saturation, and it is what keeps `loadMore` from re-paying full price
        // for an answer it already holds.
        #expect(deep.truncated)
        #expect(deep.saturated == false)
        #expect(deep.matchedCount == narrow.matchedCount)
    }

    @Test("a common-only search reports a total it can honour, with no floor")
    func commonOnlyIsNeverSaturated() throws {
        let fixture = try makeCommonFilteredFixture()

        // The window the ladder could measure here is 120 prefix rows and the
        // window the user sees is 40. Publishing a floor over the wrong one is
        // what made `mak` read `36 / 36+` and re-run the same search on every
        // click — the prefix stages ignore the window, so the measurement
        // could never come back any other way.
        let outcome = try fixture.outcome("kan", commonOnly: true)

        #expect(outcome.saturated == false)
    }

    @Test("a JLPT-filtered search is never saturated")
    func jlptFilteredIsNeverSaturated() throws {
        let fixture = try makeCommonFilteredFixture()

        // The bulk rows carry no JLPT level, so the filter drops every one —
        // saturation still stays refused, which is the point: the probe cannot
        // see the join the filter reads.
        let outcome = try fixture.outcome("kan", jlptLevels: [5])

        #expect(outcome.saturated == false)
    }

    @Test("a name-type-filtered search is never saturated")
    func nameTypeFilteredIsNeverSaturated() throws {
        let fixture = try makeCommonFilteredFixture()

        // The bulk rows are words, so the surname filter drops every one —
        // saturation still stays refused: the probe cannot see the badges the
        // filter reads.
        let outcome = try fixture.outcome("kan", nameTypes: ["SURNAME"])

        #expect(outcome.saturated == false)
    }

    @Test("a common-only search returns every row it found")
    func commonOnlyHoldsTheWholeAnswer() throws {
        let fixture = try makeCommonFilteredFixture()

        let outcome = try fixture.outcome("kan", commonOnly: true)

        // Nothing was skipped, so the payload is the whole answer — which is
        // what lets the window say `40 / 40` and offer nothing to load.
        #expect(outcome.hits.count == outcome.matchedCount)
    }

    @Test("a common-only search still runs the gloss tier")
    func commonOnlyKeepsTheGlossTier() throws {
        let fixture = try makeCommonFilteredFixture()

        // `kanji-written homophone` is common and no writing of it starts with
        // the query, so only the gloss scan reaches it. A window measured
        // without the common filter would have skipped that scan and stranded
        // the entry behind a `+` no click could resolve.
        let outcome = try fixture.outcome("kan", commonOnly: true)

        let hit = try #require(outcome.hits.first { candidate in
            candidate.glossPreview.first == "kanji-written homophone"
        })
        #expect(hit.common)
    }
}
