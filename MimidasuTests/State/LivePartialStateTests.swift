@testable import Mimidasu
import Testing

/// Tests `LivePartialState` observed partial set/clear.
@MainActor
@Suite("LivePartialState")
struct LivePartialStateTests {

    // MARK: - Helpers

    private func makeSUT() -> (LivePartialState, ObservedValuesRecorder<String>) {
        let sut = LivePartialState()
        let observed = ObservedValuesRecorder(read: { sut.partial })
        return (sut, observed)
    }

    // MARK: - Observed partial

    @Test("the partial fires each observed change")
    func partialFiresEachChange() async {
        let (sut, observed) = makeSUT()

        sut.partial = "こんにちは"

        #expect(sut.partial == "こんにちは")
        #expect(await pollUntil { observed.values == ["こんにちは"] }, "the recorder fires the new partial")

        sut.partial = ""

        #expect(await pollUntil { observed.values == ["こんにちは", ""] }, "clearing fires an empty string")
        #expect(sut.partial == "")
    }
}
