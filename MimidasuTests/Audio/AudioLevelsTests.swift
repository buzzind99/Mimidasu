@testable import Mimidasu
import Testing

/// Direct assertions for `AudioLevels`: `rms`, which also executes indirectly
/// in the `SessionController` meter handoff and the `MockASREngine` /
/// `CrispASREngine` speech gates, and `silenceFloorRMS`, the no-audio
/// watchdog's threshold.
@Suite("AudioLevels")
struct AudioLevelsTests {

    struct Row: Sendable {
        let summary: String
        let samples: [Float]?
        let expected: Float
    }

    @Test("rms and the silence floor match their documented values", arguments: [
        Row(summary: "rms of empty input is zero", samples: [], expected: 0),
        Row(
            summary: "rms of a constant buffer equals its amplitude",
            samples: [Float](repeating: 0.5, count: 100),
            expected: 0.5
        ),
        Row(summary: "rms squares before averaging, so sign cancels", samples: [0.5, -0.5], expected: 0.5),
        Row(summary: "the silence floor pins the -60 dBFS threshold", samples: nil, expected: 0.001)
    ])
    func levelsMatchDocumentedValues(row: Row) {
        let actual: Float = if let samples = row.samples {
            AudioLevels.rms(of: samples)
        } else {
            AudioLevels.silenceFloorRMS
        }

        #expect(abs(actual - row.expected) < 1e-6, "\(row.summary)")
    }
}
