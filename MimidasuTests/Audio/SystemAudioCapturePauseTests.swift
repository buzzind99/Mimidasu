import Foundation
@testable import Mimidasu
import Testing

/// Tests `SystemAudioCapture`'s pause/resume state machine with a running
/// flag but no live tap: `pause()` and `resume()` reach the production HAL
/// rig, whose pause helpers no-op without tracked objects, so the state
/// transitions and their failure arms run without Core Audio devices.
///
/// Excluded: `resume()`'s success arm — it needs a tracked rig, so it is
/// only reachable with a real tap (the live path).
@Suite("SystemAudioCapture pause")
struct SystemAudioCapturePauseTests {

    @Test("pause marks a running capture paused; stop clears the mark")
    func pauseThenStopClearsPaused() async {
        let capture = SystemAudioCapture()
        capture.setRunningForTesting(true)

        await capture.pause()
        #expect(capture.isPaused)
        #expect(capture.isRunning, "pause suspends, it does not end the session")

        capture.stop()

        #expect(!capture.isPaused)
        #expect(!capture.isRunning)
    }

    @Test("pause is a no-op on a stopped capture")
    func pauseWithoutRunningIsNoop() async {
        let capture = SystemAudioCapture()

        await capture.pause()

        #expect(!capture.isPaused)
    }

    @Test("a second pause is a no-op")
    func pauseTwiceKeepsPaused() async {
        let capture = SystemAudioCapture()
        capture.setRunningForTesting(true)
        await capture.pause()

        await capture.pause()

        #expect(capture.isPaused)
        capture.stop()
    }

    @Test("resume without a pause fails as not-paused")
    func resumeWithoutPauseThrows() async {
        let capture = SystemAudioCapture()
        capture.setRunningForTesting(true)

        await #expect(throws: CaptureError.self) {
            try await capture.resume()
        }

        #expect(!capture.isPaused)
    }

    @Test("resume with no tracked rig throws and leaves the capture paused")
    func resumeWithNoRigThrows() async {
        let capture = SystemAudioCapture()
        capture.setRunningForTesting(true)
        await capture.pause()

        await #expect(throws: CaptureError.self) {
            try await capture.resume()
        }

        #expect(capture.isPaused, "a failed resume stays paused for the rebuild fallback")
        capture.stop()
    }
}
