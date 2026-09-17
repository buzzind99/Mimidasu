@testable import Mimidasu
import Testing

/// Direct assertions for `AudioLevels`: `rms`, which also executes indirectly
/// in the `SessionController` meter handoff and the `MockASREngine` /
/// `CrispASREngine` speech gates, and `silenceFloorRMS`, the no-audio
/// watchdog's threshold.
@Suite("AudioLevels")
struct AudioLevelsTests {

    @Test("rms of empty input is zero")
    func emptyIsZero() {
        #expect(AudioLevels.rms(of: []) == 0)
    }

    @Test("rms of a constant buffer equals its amplitude")
    func constantEqualsAmplitude() {
        #expect(AudioLevels.rms(of: .init(repeating: 0.5, count: 100)) == 0.5)
    }

    @Test("rms squares before averaging, so sign cancels")
    func signCancels() {
        #expect(abs(AudioLevels.rms(of: [0.5, -0.5]) - 0.5) < 1e-6)
    }

    @Test("silence floor pins the -60 dBFS threshold")
    func silenceFloorPinsThreshold() {
        #expect(AudioLevels.silenceFloorRMS == 0.001)
    }
}
