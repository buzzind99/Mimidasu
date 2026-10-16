@testable import Mimidasu
import Testing

/// The pager half of `DictionarySearchStateTests`: the absolute-target step,
/// the bounds it clamps to, the pruning a departed row triggers, and the
/// promoted-lead restart. Split out of the parent suite to keep both type
/// bodies small, over the fixture the parent builds.
@MainActor
extension DictionarySearchStateTests {

    @Test("an absent row's pager starts at the first entry")
    func absentRowStartsAtZero() throws {
        let fixture = try makeState()

        #expect(fixture.state.entryIndex(for: "食べる") == 0)
    }

    @Test("the pager step is clamped to the entry list",
          arguments: [
              // (2, 4, 2) pins in-range pass-through: target 2 sits inside a
              // 4-entry list, so nothing is clamped away.
              (2, 4, 2),
              (5, 3, 2),
              (-5, 3, 0),
              (1, 1, 0),
              (1, 0, 0)
          ])
    func pagerStepClamps(target: Int, count: Int, expected: Int) throws {
        let fixture = try makeState()

        let state = fixture.state
        state.stepEntry("食べる", to: target, in: result(entries: count))

        #expect(state.entryIndex(for: "食べる") == expected)
    }

    @Test("the pager step stores the pager's absolute target")
    func stepStoresAbsoluteTarget() throws {
        let fixture = try makeState()
        let state = fixture.state

        state.stepEntry("食べる", to: 1, in: result(entries: 4))
        #expect(state.entryIndex(for: "食べる") == 1)

        // The pager hands over absolute indices (current ± 1): a second press
        // from page 1 must land on 2, not on stored + target.
        state.stepEntry("食べる", to: 2, in: result(entries: 4))
        #expect(state.entryIndex(for: "食べる") == 2)
    }

    @Test("a stepped pager resets when its row leaves the rows")
    func steppedPagerResetsWhenRowLeaves() async throws {
        let fixture = try makeState()
        let state = fixture.state

        state.query = "あめ"
        #expect(await pollUntil(timeout: 2) { state.outcome.hits.count == 4 }, "the あめ rows land")
        state.stepEntry("飴", to: 1, in: result(entries: 2))
        #expect(state.entryIndex(for: "飴") == 1)

        // A lead change to the Names scope drops 飴 from the rows; the
        // landing prunes the stored pager alongside the expansion, so the
        // next open starts at the first entry instead of a stale page.
        state.filters = DictionarySearchFilters(scope: .names)
        #expect(await pollUntil(timeout: 2) { state.outcome.hits.map(\.entSeq) == [15_668_307] }, "the names landing lands")
        #expect(state.entryIndex(for: "飴") == 0)
    }

    @Test("the promoted pager resets when the lead entry changes")
    func promotedPagerResetsOnLeadChange() throws {
        let fixture = try makeState()
        let state = fixture.state
        let baseline = result(entries: 2)

        #expect(state.validatedIndex(for: "飴", in: baseline) == 0)
        state.stepEntry("飴", to: 1, in: baseline)
        #expect(state.validatedIndex(for: "飴", in: baseline) == 1)

        // A promotion reorder moves another entry to the front; the stored
        // page belonged to the old order, so the display restarts at the lead
        // instead of silently retargeting. Storage lags until the next press
        // overwrites it — the view only ever reads `validatedIndex`.
        let identity = FavoriteIdentity(keys: ["語2"])
        let reordered = FavoritesPromotion.promotingFavorites(in: baseline, identity: identity)
        #expect(reordered.entries.map(\.entSeq) == [2, 1])
        #expect(state.validatedIndex(for: "飴", in: reordered) == 0)
        #expect(state.entryIndex(for: "飴") == 1)
    }

    @Test("the promoted pager clamps when the lead is unchanged")
    func promotedPagerClampsWithoutLeadChange() throws {
        let fixture = try makeState()
        let state = fixture.state
        let promoted = result(entries: 3)

        #expect(state.validatedIndex(for: "飴", in: promoted) == 0)
        state.stepEntry("飴", to: 5, in: promoted)
        #expect(state.validatedIndex(for: "飴", in: promoted) == 2)
        // The clamp persists, so the stored index and the shown page agree.
        #expect(state.entryIndex(for: "飴") == 2)
    }
}
