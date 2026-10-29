import Foundation
@testable import Mimidasu
import Testing

/// Pins the pure projection from a search outcome and a window to the values
/// the list renders: the visible slice, the count, the footer action, and the
/// empty message. Every outcome here is synthetic, so no database is involved.
@Suite("Dictionary search page")
struct DictionarySearchPageTests {
    private func makeHits(_ count: Int) -> [DictionarySearchHit] {
        (0 ..< count).map { index in
            DictionarySearchHit(
                entSeq: index,
                keb: "語\(index)",
                reb: "ご\(index)",
                common: false,
                jlpt: nil,
                isName: false,
                namePosTokens: [],
                matchKind: .exact,
                matchedField: .keb,
                highlightRange: 0 ..< 1,
                glossPreview: []
            )
        }
    }

    private func makeOutcome(
        hits count: Int,
        matchedCount: Int? = nil,
        saturated: Bool = false,
        truncated: Bool = false
    ) -> DictionarySearchOutcome {
        DictionarySearchOutcome(
            hits: makeHits(count),
            matchedCount: matchedCount ?? count,
            saturated: saturated,
            truncated: truncated
        )
    }

    @Test("a window clamps to the engine's range and advances one page at a time")
    func windowClampsAndAdvances() {
        #expect(DictionarySearchWindow(limit: -100).limit == 0)
        #expect(DictionarySearchWindow(limit: 0).limit == 0)
        #expect(DictionarySearchWindow(limit: DictionarySearchEngine.pageSize).limit == 50)
        #expect(DictionarySearchWindow(limit: DictionarySearchEngine.maxRows).limit == 1000)
        #expect(
            DictionarySearchWindow(limit: DictionarySearchEngine.maxRows + 100).limit
                == DictionarySearchEngine.maxRows
        )

        #expect(DictionarySearchWindow.initial.limit == DictionarySearchEngine.pageSize)
        #expect(DictionarySearchWindow.initial.advanced.limit == 100)
        let nearCeiling = DictionarySearchWindow(limit: DictionarySearchEngine.maxRows - 10)
        #expect(nearCeiling.advanced.limit == DictionarySearchEngine.maxRows)
        #expect(
            DictionarySearchWindow(limit: DictionarySearchEngine.maxRows).advanced.limit
                == DictionarySearchEngine.maxRows
        )

        #expect(!DictionarySearchWindow.initial.isAtMaximum)
        #expect(DictionarySearchWindow(limit: DictionarySearchEngine.maxRows).isAtMaximum)
    }

    @Test("count text reads the visible slice over the total and marks a floor")
    func countTextMarksTheFloor() {
        let complete = DictionarySearchPage(
            outcome: makeOutcome(hits: 120),
            window: DictionarySearchWindow(limit: 50)
        )
        #expect(complete.countText == "50 / 120")

        let saturated = DictionarySearchPage(
            outcome: makeOutcome(hits: 60, saturated: true),
            window: .initial
        )
        #expect(saturated.countText == "50 / 60+")

        let emptyFloor = DictionarySearchPage(
            outcome: makeOutcome(hits: 0, truncated: true),
            window: .initial
        )
        #expect(emptyFloor.countText == "0 / 0+")
    }

    @Test("a complete answer that fits the window offers no footer")
    func completeAnswerThatFitsHasNoFooter() {
        let page = DictionarySearchPage(outcome: makeOutcome(hits: 20), window: .initial)

        #expect(page.footer == .none)
        #expect(page.emptyState == nil)
        #expect(!page.isFloor)
    }

    @Test("held rows beyond the window offer a free reveal")
    func heldRowsBeyondTheWindowOfferAReveal() {
        let page = DictionarySearchPage(outcome: makeOutcome(hits: 120), window: .initial)

        #expect(page.footer == .loadMore(.reveal))
        #expect(!page.isFloor)
    }

    @Test("saturation rescans only when the next window outgrows the held rows")
    func saturationChoosesRescanOrRevealByTheNextWindow() {
        let skippedStage = DictionarySearchPage(
            outcome: makeOutcome(hits: 50, saturated: true),
            window: .initial
        )
        #expect(skippedStage.footer == .loadMore(.rescan))

        let heldRows = DictionarySearchPage(
            outcome: makeOutcome(hits: 120, saturated: true),
            window: .initial
        )
        #expect(heldRows.footer == .loadMore(.reveal))
    }

    @Test("rows behind the window at the ceiling offer refinement")
    func rowsBehindTheWindowAtTheCeilingOfferRefinement() {
        let page = DictionarySearchPage(
            outcome: makeOutcome(
                hits: DictionarySearchEngine.maxRows,
                matchedCount: DictionarySearchEngine.maxRows + 250
            ),
            window: DictionarySearchWindow(limit: DictionarySearchEngine.maxRows)
        )

        #expect(page.window.isAtMaximum)
        #expect(page.footer == .ceiling)
    }

    @Test("a truncated answer below the ceiling still offers refinement")
    func truncatedAnswerBelowTheCeilingOffersRefinement() {
        let page = DictionarySearchPage(
            outcome: makeOutcome(hits: 20, matchedCount: 20, truncated: true),
            window: .initial
        )

        #expect(page.isFloor)
        #expect(page.footer == .ceiling)
    }

    @Test("truncation never offers a rescan")
    func truncationNeverRescans() {
        let page = DictionarySearchPage(
            outcome: makeOutcome(hits: 60, truncated: true),
            window: .initial
        )
        #expect(page.footer == .loadMore(.reveal))

        let ceiling = DictionarySearchPage(
            outcome: makeOutcome(hits: 60, truncated: true),
            window: DictionarySearchWindow(limit: DictionarySearchEngine.maxRows)
        )
        #expect(ceiling.footer == .ceiling)

        // Synthetic: the ladder never saturates and truncates together; the
        // projection still refuses a rescan for the combined state.
        let both = DictionarySearchPage(
            outcome: makeOutcome(hits: 60, saturated: true, truncated: true),
            window: .initial
        )
        #expect(both.footer == .loadMore(.reveal))

        let bothWithoutHeldRows = DictionarySearchPage(
            outcome: makeOutcome(hits: 50, saturated: true, truncated: true),
            window: .initial
        )
        #expect(bothWithoutHeldRows.footer == .ceiling)

        #expect(page.footer != .loadMore(.rescan))
        #expect(ceiling.footer != .loadMore(.rescan))
        #expect(both.footer != .loadMore(.rescan))
        #expect(bothWithoutHeldRows.footer != .loadMore(.rescan))
    }

    @Test("an empty page separates no matches from an empty scanned window")
    func emptyStateSeparatesNoMatchesFromAScannedWindow() {
        let rows = DictionarySearchPage(outcome: makeOutcome(hits: 20), window: .initial)
        #expect(rows.emptyState == nil)
        #expect(rows.isEmpty == false)

        let noMatches = DictionarySearchPage(outcome: .empty, window: .initial)
        #expect(noMatches.emptyState == .noMatches)
        #expect(noMatches.footer == .none)
        #expect(noMatches.isEmpty)

        let scannedWindow = DictionarySearchPage(
            outcome: makeOutcome(hits: 0, truncated: true),
            window: .initial
        )
        #expect(scannedWindow.emptyState == .noMatchesInScannedWindow)
        #expect(scannedWindow.footer == .none)
        #expect(scannedWindow.isFloor)

        // Synthetic: saturation always keeps at least `limit` hits; kept to
        // pin the empty-window label for a saturated answer.
        let saturatedWindow = DictionarySearchPage(
            outcome: makeOutcome(hits: 0, saturated: true),
            window: .initial
        )
        #expect(saturatedWindow.emptyState == .noMatchesInScannedWindow)
        #expect(saturatedWindow.footer == .none)
    }

    @Test("a wider window appends to the same prefix")
    func aWiderWindowAppendsToTheSamePrefix() {
        let outcome = makeOutcome(hits: 120)
        let first = DictionarySearchPage(
            outcome: outcome,
            window: DictionarySearchWindow(limit: 50)
        )
        let second = DictionarySearchPage(
            outcome: outcome,
            window: DictionarySearchWindow(limit: 100)
        )

        #expect(Array(first.hits) == Array(outcome.hits.prefix(50)))
        #expect(Array(second.hits) == Array(outcome.hits.prefix(100)))
        #expect(Array(second.hits.prefix(first.hits.count)) == Array(first.hits))
        #expect(second.hits.count == 100)
    }

    @Test("the page keeps a slice of the outcome's own array")
    func pageKeepsASliceOfTheOutcomeArray() {
        let outcome = makeOutcome(hits: 120)
        let page = DictionarySearchPage(
            outcome: outcome,
            window: DictionarySearchWindow(limit: 50)
        )

        #expect(page.hits.startIndex == outcome.hits.startIndex)
        #expect(page.hits.endIndex == 50)
        #expect(Array(page.hits) == Array(outcome.hits.prefix(50)))
    }
}
