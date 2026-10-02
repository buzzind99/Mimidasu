import Foundation
@testable import Mimidasu
import Testing

/// Expansion bookkeeping for the Favorites window's rows, with the rules that
/// decide whether a lookup's result is still wanted: the window closed
/// (`reset()`), the row collapsed, or the word left the list (`remove`) — and
/// in each case a result landing afterwards is discarded rather than
/// re-populating a row nobody is looking at.
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

    /// A flag the gated query sets from its detached task and the test polls
    /// from the main actor, so the test never blocks a thread or calls a
    /// semaphore from an async context.
    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var entered = false
        private var left = false

        func markEntered() {
            lock.lock()
            defer { lock.unlock() }
            entered = true
        }

        func markLeft() {
            lock.lock()
            defer { lock.unlock() }
            left = true
        }

        var hasEntered: Bool {
            lock.lock()
            defer { lock.unlock() }
            return entered
        }

        var hasLeft: Bool {
            lock.lock()
            defer { lock.unlock() }
            return left
        }
    }

    /// A lookup whose `resolveDatabase` blocks until the test releases it, so a
    /// query is genuinely in flight across a collapse or a reset. It resolves to
    /// a path that is not there, so the query that follows the release throws —
    /// landing on the row as `.failed` if the generation bump were missing, and
    /// leaving it `.idle` when the bump is there. The gate runs on the detached
    /// task, so blocking there never touches the main actor.
    private func gatedLookup(
        release: DispatchSemaphore, gate: Gate
    ) -> JMDictLookup {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("mimidasu-favorites-lookup-gated-\(UUID().uuidString).sqlite")
        return JMDictLookup(resolveDatabase: {
            gate.markEntered()
            release.wait()
            gate.markLeft()
            return missing
        })
    }

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

    @Test("removing a deleted row's headword drops its expansion and phase")
    func removeDropsState() {
        let sut = state()
        sut.toggle(word)

        sut.remove(headword: word.headword)

        #expect(!sut.isExpanded(word) && sut.phase(for: word) == .idle)
    }

    /// Waits until the released query has entered and left `resolveDatabase`,
    /// then lets the main actor drain before the caller reads a phase. The
    /// query leaving is not the landing: the throw and the hop back still have
    /// to happen, so reading the phase immediately would race the very write
    /// these tests exist to catch. The two polls are asserted so a query that
    /// never ran fails loudly instead of passing vacuously.
    private func drainAfterGatedQuery(_ gate: Gate) async {
        #expect(await pollUntil { gate.hasEntered })
        #expect(await pollUntil { gate.hasLeft })
        for _ in 0 ..< 5 {
            await Task.yield()
        }
        try? await Task.sleep(for: .milliseconds(20))
    }

    @Test("a lookup that lands after its row collapsed is discarded")
    func staleResultAfterCollapseIsDiscarded() async {
        let release = DispatchSemaphore(value: 0)
        let gate = Gate()
        let sut = FavoritesLookupState(lookup: gatedLookup(release: release, gate: gate))
        sut.toggle(word) // in flight, blocked on `release`
        sut.toggle(word) // collapsed, generation bumped

        release.signal()
        await drainAfterGatedQuery(gate)

        // Still idle: the in-flight result found a stale generation and was
        // dropped rather than re-populating a row that was collapsed.
        #expect(sut.phase(for: word) == .idle)
    }

    @Test("a lookup that lands after reset is discarded")
    func staleResultAfterResetIsDiscarded() async {
        let release = DispatchSemaphore(value: 0)
        let gate = Gate()
        let sut = FavoritesLookupState(lookup: gatedLookup(release: release, gate: gate))
        sut.toggle(word)

        sut.reset()
        release.signal()
        await drainAfterGatedQuery(gate)

        #expect(sut.phase(for: word) == .idle)
    }
}
