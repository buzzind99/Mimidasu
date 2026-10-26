@testable import Mimidasu
import Testing

/// Tests `LatencyState` rounding/observation behavior: values round to 0.1 s,
/// the 0.05 boundary rounds up, equal rounded values never re-fire, and
/// `reset()` is a no-op at zero.
@MainActor
@Suite("LatencyState")
struct LatencyStateTests {

    // MARK: - Helpers

    private func makeSUT() -> (LatencyState, ObservedValuesRecorder<Double>) {
        let sut = LatencyState()
        let observed = ObservedValuesRecorder(read: { sut.seconds })
        return (sut, observed)
    }

    // MARK: - update(_:)

    @Test(
        "update rounds to the nearest tenth",
        arguments: [
            (input: 0.14, expected: 0.1, observed: [0.1]),
            (input: 0.16, expected: 0.2, observed: [0.2]),
            (input: 0.05, expected: 0.1, observed: [0.1]),
            (input: 0.04, expected: 0.0, observed: [Double]()),
        ]
    )
    func updateRoundsToNearestTenth(input: Double, expected: Double, observed: [Double]) async {
        let (sut, recorder) = makeSUT()

        sut.update(input)
        await flushObservations()

        #expect(sut.seconds == expected)
        #expect(recorder.values == observed, "the recorder fires exactly the rounded changes")
    }

    @Test("does not re-fire when the rounded value is unchanged")
    func unchangedValueDoesNotRefire() async {
        let (sut, observed) = makeSUT()

        sut.update(0.3)
        #expect(await pollUntil { observed.values == [0.3] })
        sut.update(0.31)
        await flushObservations()

        #expect(observed.values == [0.3], "an unchanged rounded value must not re-fire")
        #expect(sut.seconds == 0.3)
    }

    // MARK: - reset()

    @Test("reset fires zero after a nonzero value")
    func resetFiresZero() async {
        let (sut, observed) = makeSUT()
        sut.update(0.42)
        #expect(await pollUntil { observed.values == [0.4] })

        sut.reset()
        #expect(await pollUntil { observed.values == [0.4, 0.0] })

        #expect(sut.seconds == 0.0)
    }

    @Test("reset is a no-op at zero and fires nothing")
    func resetAtZeroDoesNotFire() async {
        let (sut, observed) = makeSUT()

        sut.reset()
        await flushObservations()

        #expect(sut.seconds == 0.0)
        #expect(observed.values.isEmpty)
    }
}
