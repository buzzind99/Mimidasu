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

    @Test("a lookup that cannot run lands on the row as failed")
    func failedLookupLandsAsFailed() async {
        let sut = state()
        let subject = word

        sut.toggle(subject)

        #expect(await pollUntil { sut.phase(for: subject) != .loading })
        if case .failed = sut.phase(for: subject) {} else {
            Issue.record("a failed open did not land as failed: \(sut.phase(for: subject))")
        }
    }

    @Test("a landed lookup resolves the row's phase")
    func landedLookupResolves() async throws {
        let fixture = try JMDictFixtureDatabase.build()
        defer { fixture.remove() }
        let url = fixture.url
        let sut = FavoritesLookupState(lookup: JMDictLookup(resolveDatabase: { url }))
        let word = FavoriteWord(
            headword: "尾", reading: "お", romaji: "o", addedAt: 0
        )

        sut.toggle(word)

        #expect(await pollUntil { sut.phase(for: word) != .loading })
        if case .resolved = sut.phase(for: word) {} else {
            Issue.record("a fixture hit did not resolve: \(sut.phase(for: word))")
        }
    }

    @Test("a landed lookup with no hit marks the row not found")
    func landedLookupWithoutHitMarksNotFound() async throws {
        let fixture = try JMDictFixtureDatabase.build()
        defer { fixture.remove() }
        let url = fixture.url
        let sut = FavoritesLookupState(lookup: JMDictLookup(resolveDatabase: { url }))
        let word = FavoriteWord(
            headword: "あああああ", reading: "あああああ", romaji: "aaaaa", addedAt: 0
        )

        sut.toggle(word)

        #expect(await pollUntil { sut.phase(for: word) != .loading })
        #expect(sut.phase(for: word) == .notFound)
    }

    /// Releases the gated query and waits until its landing has actually been
    /// attempted. The three waits are each on observed state, never on a fixed
    /// delay: the query entering, the query leaving, and — the one that
    /// matters — the generation guard counting the discard in
    /// `discardedLandings`. That last poll is what makes the tests
    /// deterministic, and what makes a *deleted* guard fail them: with the
    /// guard gone nothing ever counts, so the poll times out instead of the
    /// assertion passing vacuously.
    private func releaseAndAwaitDiscard(
        _ release: DispatchSemaphore, gate: Gate, sut: FavoritesLookupState
    ) async {
        #expect(await pollUntil { gate.hasEntered })
        release.signal()
        #expect(await pollUntil { gate.hasLeft })
        #expect(await pollUntil { sut.discardedLandings == 1 })
    }

    @Test("a lookup that lands after its row collapsed is discarded")
    func staleResultAfterCollapseIsDiscarded() async {
        let release = DispatchSemaphore(value: 0)
        let gate = Gate()
        let sut = FavoritesLookupState(lookup: gatedLookup(release: release, gate: gate))
        sut.toggle(word) // in flight, blocked on `release`
        sut.toggle(word) // collapsed, generation bumped

        await releaseAndAwaitDiscard(release, gate: gate, sut: sut)

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
        await releaseAndAwaitDiscard(release, gate: gate, sut: sut)

        #expect(sut.phase(for: word) == .idle)
    }
}
