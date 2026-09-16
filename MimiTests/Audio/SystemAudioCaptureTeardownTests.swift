import Foundation
@testable import Mimi
import Testing

/// Tests `SystemAudioCapture`'s teardown paths — the `stop()` fence and the
/// dead-device reset — through the internal seams
/// (`handleAudioBufferList`/`handleDeviceDied`), split out of
/// `SystemAudioCaptureTests` to keep both suites small. Callbacks either run
/// synchronously on the calling thread or are parked on test-owned gates, so
/// the interleavings are structural, not timed. No audio HAL involved.
@Suite("SystemAudioCapture teardown")
struct SystemAudioCaptureTeardownTests {

    // MARK: - Fixtures

    private let recorder = DeliveryRecorder()

    /// Appends chunks/errors from the capture's callbacks. A reference box so
    /// the escaping callbacks can append; a fresh suite instance per test
    /// keeps tests isolated.
    private final class DeliveryRecorder: @unchecked Sendable {
        private(set) var chunks: [AudioChunk] = []
        private(set) var errors: [CaptureError] = []

        func record(_ chunk: AudioChunk) {
            chunks.append(chunk)
        }

        func record(_ error: CaptureError) {
            errors.append(error)
        }
    }

    // MARK: - Helpers

    private func makeCapture(running: Bool) -> SystemAudioCapture {
        let capture = SystemAudioCapture()
        let recorder = recorder
        capture.onChunk = { chunk in recorder.record(chunk) }
        capture.onIOError = { error in recorder.record(error) }
        if running {
            capture.setRunningForTesting(true)
        }
        return capture
    }

    // MARK: - Stop fence

    @Test("stop() fences an in-flight callback and nothing lands after it returns")
    func stopFencesInFlightCallback() {
        let capture = makeCapture(running: true)
        let buffer = AudioBufferListSynthesis.make(frames: 2 * 2560)
        let recorder = recorder

        // Raw Thread + semaphore handoff instead of a `confirmation()`:
        // a confirmation cannot block the pipeline mid-callback, and
        // blocking it is the entire point — stop() must be fenced against
        // an in-flight delivery.
        //
        // Hold the first chunk delivery inside the callback (under the
        // capture's state lock): stop() must not be able to return until the
        // in-flight callback finishes, and no chunk may land afterwards.
        let chunkDelivered = DispatchSemaphore(value: 0)
        let deliveryGate = NSLock()
        deliveryGate.lock()
        capture.onChunk = { chunk in
            recorder.record(chunk)
            chunkDelivered.signal()
            deliveryGate.lock()
            deliveryGate.unlock()
        }

        // The callback thread deliberately hands the buffer in off-main —
        // that is the real production path; the buffer is read-only here.
        let callbackBuffer = buffer
        let callbackThread = Thread {
            capture.handleAudioBufferList(callbackBuffer.pointer, format: callbackBuffer.asbd)
        }
        callbackThread.start()
        #expect(chunkDelivered.wait(timeout: .now() + 2) == .success)
        #expect(recorder.chunks.count == 1)

        let stopReturned = DispatchSemaphore(value: 0)
        let stopThread = Thread {
            capture.stop()
            stopReturned.signal()
        }
        stopThread.start()
        #expect(stopReturned.wait(timeout: .now() + 0.2) == .timedOut)

        deliveryGate.unlock()
        #expect(stopReturned.wait(timeout: .now() + 2) == .success)
        #expect(!capture.isRunning)
        #expect(recorder.chunks.count == 2)
        #expect(recorder.chunks.map(\.startSample) == [0, 2560])
        #expect(recorder.errors.isEmpty)
    }

    @Test("sample buffers are dropped after stop() returns")
    func samplesDroppedAfterStop() {
        let capture = makeCapture(running: true)
        let buffer = AudioBufferListSynthesis.make(frames: 2560)

        capture.handleAudioBufferList(buffer.pointer, format: buffer.asbd)
        #expect(recorder.chunks.count == 1)

        capture.stop()
        capture.handleAudioBufferList(buffer.pointer, format: buffer.asbd)
        #expect(!capture.isRunning)
        #expect(recorder.chunks.count == 1)
        #expect(recorder.errors.isEmpty)
    }

    @Test("a stop during extraction drops the in-flight samples")
    func stopDuringExtractionDropsSamples() {
        let capture = makeCapture(running: true)
        // One chunk's worth: if the fence failed, the buffer would surface
        // as exactly one chunk.
        let buffer = AudioBufferListSynthesis.make(frames: 2560)

        // Park the callback inside `extractMono` — past every entry guard,
        // still before the locked re-check — so `stop()` provably runs while
        // a callback is in flight. The gate makes the interleaving
        // structural: no sleep-based race over whether the callback has
        // reached extraction yet.
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
        #expect(extractionEntered.wait(timeout: .now() + 2) == .success)

        capture.stop()
        releaseExtraction.signal()

        #expect(callbackFinished.wait(timeout: .now() + 2) == .success)
        #expect(!capture.isRunning)
        #expect(recorder.chunks.isEmpty)
        #expect(recorder.errors.isEmpty)
    }

    // MARK: - Device-death handling

    @Test("a device-died event while running resets the state and reports the error")
    func deviceDiedWhileRunning() throws {
        let capture = makeCapture(running: true)
        let deviceError = NSError(
            domain: "mimi.tests", code: 42,
            userInfo: [NSLocalizedDescriptionKey: "stream died"]
        )

        capture.handleDeviceDied(deviceError)

        #expect(!capture.isRunning)
        #expect(recorder.chunks.isEmpty)
        #expect(recorder.errors.count == 1)
        let error = try #require(recorder.errors.first)
        guard case let .captureLost(detail) = error else {
            Issue.record("expected .captureLost, got \(error)")
            return
        }
        #expect(detail == "stream died")
    }

    @Test(
        "a device-died event clears the accumulator so new samples never stitch onto leftovers"
    )
    func deviceDiedClearsAccumulator() throws {
        let capture = makeCapture(running: true)
        let deviceError = NSError(domain: "mimi.tests", code: 9)

        // A full chunk pre-death: pins that session-relative offsets
        // intentionally continue across the death (`startSample` does not
        // reset), while the accumulator itself is dropped.
        let first = AudioBufferListSynthesis.make(frames: 2560)
        capture.handleAudioBufferList(first.pointer, format: first.asbd)
        #expect(recorder.chunks.count == 1)
        capture.handleDeviceDied(deviceError)

        // The instance stays usable after the device died: the next run must
        // not stitch new samples onto pre-death leftovers.
        capture.setRunningForTesting(true)
        let second = AudioBufferListSynthesis.make(frames: 2560)
        capture.handleAudioBufferList(second.pointer, format: second.asbd)

        #expect(recorder.chunks.count == 2)
        let chunk = try #require(recorder.chunks.last)
        #expect(chunk.startSample == 2560)
        #expect(chunk.samples == (0 ..< 2560).map(Float.init))
    }

    @Test("a device-died event while not running is a no-op")
    func deviceDiedWhenNotRunning() {
        let capture = makeCapture(running: false)
        let deviceError = NSError(domain: "mimi.tests", code: 7)

        capture.handleDeviceDied(deviceError)

        #expect(!capture.isRunning)
        #expect(recorder.errors.isEmpty)
    }
}
