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

    /// Appends chunks from the capture's callbacks. A fresh suite instance
    /// per test keeps tests isolated; reads happen after the callback's
    /// semaphore handoff, so no lock is needed.
    private final class ChunkSink: @unchecked Sendable {
        private(set) var chunks: [AudioChunk] = []

        func record(_ chunk: AudioChunk) {
            chunks.append(chunk)
        }
    }

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

    @Test("pause fences an in-flight extraction and drops later buffers")
    func pauseDropsInFlightAndLaterSamples() async {
        let capture = SystemAudioCapture()
        let sink = ChunkSink()
        capture.onChunk = { chunk in sink.record(chunk) }
        capture.setRunningForTesting(true)
        let buffer = AudioBufferListSynthesis.make(frames: 2560)

        // Park the callback inside `extractMono` — past every entry guard,
        // still before the locked re-check — so `pause()` provably runs
        // while a callback is in flight. The rig-less `stopIO` no-ops, so
        // the pause returns once the fence is up.
        let extractionEntered = DispatchSemaphore(value: 0)
        let releaseExtraction = DispatchSemaphore(value: 0)
        capture.onExtractionEntered = {
            extractionEntered.signal()
            releaseExtraction.wait()
        }

        let callbackFinished = DispatchSemaphore(value: 0)
        let callbackBuffer = buffer
        let callbackThread = Thread {
            capture.handleAudioBufferList(callbackBuffer.pointer, format: callbackBuffer.asbd)
            callbackFinished.signal()
        }
        callbackThread.start()
        #expect(waitForSignal(extractionEntered) == .success)

        await capture.pause()
        releaseExtraction.signal()

        #expect(waitForSignal(callbackFinished) == .success)
        #expect(capture.isPaused)
        #expect(sink.chunks.isEmpty, "the chunk racing the pause is dropped at the fence")

        // One more buffer while paused: the entry guard drops it.
        capture.handleAudioBufferList(buffer.pointer, format: buffer.asbd)
        #expect(sink.chunks.isEmpty)

        capture.stop()
    }

    /// Bounded semaphore wait in a sync scope: `DispatchSemaphore.wait` is
    /// noasync, so the async test cannot call it directly.
    private func waitForSignal(_ semaphore: DispatchSemaphore) -> DispatchTimeoutResult {
        semaphore.wait(timeout: .now() + 2)
    }
}
