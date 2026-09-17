import Foundation
@testable import Mimidasu
import Testing

/// Tests the `SessionController` no-audio watchdog: a fresh capture that
/// stays silent (or delivers only zero-amplitude chunks) through the grace
/// window surfaces `onNoAudioDetected`; the first chunk above the silence
/// floor suppresses the warning and surfaces `onAudioDetected`; `stop()`
/// cancels a pending watchdog. The grace window is injected small so the
/// tests never wait the production 8 s.
@MainActor
@Suite("SessionController no-audio watchdog")
struct SessionControllerNoAudioTests {

    // MARK: - Fixtures

    private let modelURL = URL(fileURLWithPath: "/tmp/mimidasu-watchdog.gguf")
    private let modelID = "test-model-GGUF"
    private let audibleSample: Float = 0.5
    private let silentSample: Float = 0
    private let chunkSamples = 2560

    // MARK: - Fakes

    private final class ScriptedASREngine: ASREngine, @unchecked Sendable {
        let isMock = true
        var onEngineError: ((String) -> Void)?
        var processedSamples = 0
        var pushedSamples = 0

        func prepare() {}
        func openStream() {}
        func push(_ samples: [Float]) {}
        func poll() -> ASREvent? {
            nil
        }

        func finish() -> [ASREvent] {
            []
        }
    }

    private final class ScriptedCapture: AudioCapturing, @unchecked Sendable {
        var onChunk: ((AudioChunk) -> Void)?
        var onIOError: ((CaptureError) -> Void)?

        func start() async throws {}
        func stop() {}
    }

    private struct SUT {
        let controller: SessionController
        let capture: ScriptedCapture
    }

    // MARK: - Helpers

    private func makeSUT(silenceGracePeriod: Duration) -> SUT {
        let capture = ScriptedCapture()
        let controller = SessionController(
            live: LivePartialState(), latency: LatencyState(), translationQueue: TranslationQueue(),
            makeEngine: { _, _ in ScriptedASREngine() },
            makeCapture: { capture },
            warmUpEnabled: { false },
            silenceGracePeriod: silenceGracePeriod
        )
        return SUT(controller: controller, capture: capture)
    }

    private func chunk(of sample: Float) -> AudioChunk {
        AudioChunk(samples: [Float](repeating: sample, count: chunkSamples), startSample: 0)
    }

    // MARK: - Tests

    @Test("silence through the grace window surfaces onNoAudioDetected")
    func silenceWarns() async throws {
        let sut = makeSUT(silenceGracePeriod: .milliseconds(20))
        var warned = false
        sut.controller.onNoAudioDetected = { warned = true }
        _ = try await sut.controller.begin(modelURL: modelURL, modelID: modelID)

        sut.controller.armNoAudioWatchdog()

        #expect(await pollUntil { warned }, "silence past the grace window warns")
    }

    @Test("the watchdog does not count the pre-running start phase as silence")
    func watchdogIdleUntilRunning() async throws {
        let sut = makeSUT(silenceGracePeriod: .milliseconds(30))
        var warned = false
        sut.controller.onNoAudioDetected = { warned = true }

        _ = try await sut.controller.begin(modelURL: modelURL, modelID: modelID)
        try? await Task.sleep(for: .milliseconds(80))

        #expect(!warned, "the watchdog arms only once the session is running")
    }

    @Test("a zero-amplitude chunk does not count as audio")
    func silentChunkStillWarns() async throws {
        let sut = makeSUT(silenceGracePeriod: .milliseconds(40))
        var warned = false
        sut.controller.onNoAudioDetected = { warned = true }
        _ = try await sut.controller.begin(modelURL: modelURL, modelID: modelID)

        sut.capture.onChunk?(chunk(of: silentSample))
        sut.controller.armNoAudioWatchdog()

        #expect(await pollUntil { warned }, "a zero-amplitude chunk is silence")
    }

    @Test("an audible chunk surfaces onAudioDetected and suppresses the warning")
    func audibleChunkSuppressesWarning() async throws {
        let sut = makeSUT(silenceGracePeriod: .milliseconds(200))
        var warned = false
        var heard = false
        sut.controller.onNoAudioDetected = { warned = true }
        sut.controller.onAudioDetected = { heard = true }
        _ = try await sut.controller.begin(modelURL: modelURL, modelID: modelID)
        sut.controller.startTimers()
        sut.controller.armNoAudioWatchdog()

        sut.capture.onChunk?(chunk(of: audibleSample))
        #expect(await pollUntil { heard }, "the first audible chunk surfaces")
        try? await Task.sleep(for: .milliseconds(300))

        #expect(!warned)
    }

    @Test("stop cancels a pending watchdog")
    func stopCancelsWatchdog() async throws {
        let sut = makeSUT(silenceGracePeriod: .milliseconds(30))
        var warned = false
        sut.controller.onNoAudioDetected = { warned = true }
        _ = try await sut.controller.begin(modelURL: modelURL, modelID: modelID)

        sut.controller.armNoAudioWatchdog()
        await sut.controller.stop()
        try? await Task.sleep(for: .milliseconds(80))

        #expect(!warned)
    }
}
