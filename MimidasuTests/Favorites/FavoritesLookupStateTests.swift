import Foundation
@testable import Mimidasu
import Testing

/// Expansion bookkeeping for the Favorites window's rows, with the one rule
/// this turn added: closing the window drops every row, so the next open finds
/// nothing to collapse.
@Suite("FavoritesLookupState")
@MainActor
struct FavoritesLookupStateTests {

    /// A lookup pointed at a database that is not there. Expanding still moves
    /// the row to `.loading` synchronously, before the query runs, so expansion
    /// and phase are observable with no fixture — and the query that follows
    /// throws off-main, which is the case `reset()`'s generation bump exists for.
    private func state() -> FavoritesLookupState {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("mimidasu-favorites-lookup-missing-\(UUID().uuidString).sqlite")
        return FavoritesLookupState(lookup: JMDictLookup(resolveDatabase: { missing }))
    }

    private let word = FavoriteWord(
        headword: "見る", reading: "みる", romaji: "miru", addedAt: 0
    )

    @Test("reset collapses an expanded row")
    func resetCollapsesExpandedRow() {
        let sut = state()
        sut.toggle(word)

        sut.reset()

        #expect(!sut.isExpanded(word))
    }

    @Test("reset returns an expanded row's phase to idle")
    func resetClearsPhase() {
        let sut = state()
        sut.toggle(word)

        sut.reset()

        #expect(sut.phase(for: word) == .idle)
    }

    @Test("a row expands again after a reset")
    func rowExpandsAfterReset() {
        let sut = state()
        sut.toggle(word)
        sut.reset()

        sut.toggle(word)

        #expect(sut.isExpanded(word))
    }

    @Test("reset leaves a never-expanded row alone")
    func resetLeavesCollapsedRowAlone() {
        let sut = state()

        sut.reset()

        #expect(sut.phase(for: word) == .idle)
    }
}
