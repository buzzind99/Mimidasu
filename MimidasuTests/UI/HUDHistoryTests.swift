@testable import Mimidasu
import Testing

@Suite("HUDHistory")
struct HUDHistoryTests {

    // MARK: - Helpers

    private func entry(_ index: Int) -> SessionEntry {
        SessionEntry(
            sentence: Sentence(index: index, startS: 0, endS: 1, lang: "ja", text: "text\(index)")
        )
    }

    private func entries(_ indexes: [Int]) -> [SessionEntry] {
        indexes.map(entry)
    }

    // MARK: - displayedIndex

    @Test(
        "displayedIndex follows a resolving pin and otherwise shows the newest entry",
        arguments: [
            ([Int](), nil, nil),
            ([Int](), 7, nil),
            ([0, 1, 2], nil, 2),
            ([0, 1, 2], 0, 0),
            ([0, 1, 2], 2, 2),
            ([0, 1, 2], 99, 2),
            ([5], nil, 5),
            ([5], 5, 5),
            ([5], 3, 5),
        ]
    )
    func displayedIndexMapping(indexes: [Int], pinned: Int?, expected: Int?) {
        let displayed = HUDHistory.displayedIndex(in: entries(indexes), pinned: pinned)

        #expect(displayed == expected)
    }

    // MARK: - cycle

    @Test(
        "cycle steps the pin, clears it on the newest, and clamps or holds at the ends",
        arguments: [
            ([Int](), nil, -1, nil),
            ([Int](), 3, 1, 3),
            ([0, 1, 2], nil, -1, 1),
            ([0, 1, 2], nil, 1, nil),
            ([0, 1, 2], 1, 1, nil),
            ([0, 1, 2], 0, -1, 0),
            ([0, 1, 2], 42, -1, 42),
            ([0, 1, 2], 0, 1, 1),
            ([0, 1, 2], 1, -1, 0),
            ([0, 1, 2], 2, -1, 1),
            ([0, 1, 2], 2, 1, 2),
            ([7], nil, -1, nil),
            ([7], 7, -1, 7),
            ([7], 7, 1, 7),
        ]
    )
    func cycleMapping(indexes: [Int], pinned: Int?, step: Int, expected: Int?) {
        let cycled = HUDHistory.cycle(entries: entries(indexes), pinned: pinned, step: step)

        #expect(cycled == expected)
    }

    // MARK: - Enablement

    @Test(
        "step enablement allows older only without a pin and disables the ends",
        arguments: [
            ([Int](), nil, false, false),
            ([0], nil, false, false),
            ([0], 0, false, false),
            ([0, 1, 2], nil, false, true),
            ([0, 1, 2], 0, true, false),
            ([0, 1, 2], 1, true, true),
            ([0, 1, 2], 2, false, true),
        ]
    )
    func stepEnablement(indexes: [Int], pinned: Int?, canNewer: Bool, canOlder: Bool) {
        let newer = HUDHistory.canStepNewer(entries: entries(indexes), pinned: pinned)
        let older = HUDHistory.canStepOlder(entries: entries(indexes), pinned: pinned)

        #expect(newer == canNewer)
        #expect(older == canOlder)
    }

    // MARK: - Jump enablement

    @Test(
        "jump enablement offers the far end only, and treats a pin on the newest like no pin",
        arguments: [
            ([Int](), nil, false, false),
            ([Int](), 3, false, false),
            ([5], nil, false, false),
            ([5], 5, false, false),
            ([0, 1, 2], nil, true, false),
            ([0, 1, 2], 0, false, true),
            ([0, 1, 2], 1, true, true),
            ([0, 1, 2], 2, true, false),
        ]
    )
    func jumpEnablementAtPin(
        indexes: [Int], pinned: Int?, canJumpOldest: Bool, canJumpNewest: Bool
    ) {
        let oldest = HUDHistory.canJumpToOldest(entries: entries(indexes), pinned: pinned)
        let newest = HUDHistory.canJumpToNewest(entries: entries(indexes), pinned: pinned)

        #expect(oldest == canJumpOldest)
        #expect(newest == canJumpNewest)
    }
}
