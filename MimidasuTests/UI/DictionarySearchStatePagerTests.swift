@testable import Mimidasu
import Testing

/// The pager-index half of `DictionarySearchStateTests`: the row's own
/// entry position, clamped into the promoted list it is measured against.
/// Split out of the parent suite to keep both type bodies small, over the
/// fixture the parent builds.
@MainActor
extension DictionarySearchStateTests {

    @Test("the displayed index clamps the row's own entry into the list",
          arguments: [
              // (2, 4, 2) pins in-range pass-through: fallback 2 sits inside
              // a 4-entry list, so nothing is clamped away.
              (2, 4, 2),
              (5, 3, 2),
              (-5, 3, 0),
              (1, 1, 0),
              (1, 0, 0)
          ])
    func validatedIndexClampsFallback(fallback: Int, count: Int, expected: Int) throws {
        let fixture = try makeState()

        let index = fixture.state.validatedIndex(
            for: "食べる", in: result(entries: count), fallback: fallback
        )

        #expect(index == expected)
    }
}
