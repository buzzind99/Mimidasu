import Foundation
@testable import Mimidasu
import Testing

/// Tests `SessionController.pause()` / `resume()` over scripted doubles: the
/// capture pause/resume calls and their ordering with the engine flush, the
/// flushed utterance landing as a sentence, the live-surface clears, the
/// watchdog disarm/re-arm, and stop-after-pause teardown.
///
/// Excluded (audio HAL): the real IOProc stop/start — the scripted capture
/// records the calls; `SystemAudioCapture`'s own fence is pinned in the
/// Audio suites.
@MainActor
@Suite("SessionController pause")
struct SessionControllerPauseTests {

    // MARK: - Fixtures

    private let flushTailSentence = "終わりです"

    /// Thread-safe ordered call log (main actor + the detached flush).
    private final class CallLog: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String] = []

        func record(_ name: String) {
            lock.withLock { entries.append(name) }
        }

        var names: [String] {
            lock.withLock { entries }
        }

        func contains(inOrder needle: [String]) -> Bool {
            var index = 0
            for entry in names where index < needle.count {
                if entry == needle[index] {
                    index += 1
                }
            }
            return index == needle.count
        }
    }

    private final class ScriptedASREngine: ASREngine, @unchecked Sendable {
        let isMock = true
        var onEngineError: ((String) -> Void)?
        var processedSamples = 0
        var pushedSamples = 0

        private let log: CallLog
        private let flushScript: [ASREvent]

        init(log: CallLog, flush: [ASREvent] = []) {
            self.log = log
            flushScript = flush
        }

        func prepare() {
            log.record("engine.prepare")
        }

        func openStream() {
            log.record("engine.openStream")
        }

        func push(_ samples: [Float]) {}

        func poll() -> ASREvent? {
            nil
        }

        func finish() -> [ASREvent] {
            log.record("engine.finish")
            return []
        }

        func flushUtterance() -> [ASREvent] {
            log.record("engine.flushUtterance")
            return flushScript
        }
    }

    private final class ScriptedCapture: AudioCapturing, @unchecked Sendable {
        var onChunk: ((AudioChunk) -> Void)?
        var onIOError: ((CaptureError) -> Void)?

        private let log: CallLog
        private let resumeError: (any Error)?

        init(log: CallLog, resumeError: (any Error)? = nil) {
            self.log = log
            self.resumeError = resumeError
        }

        func start() async throws {
            log.record("capture.start")
        }

        func stop() {
            log.record("capture.stop")
        }

        func pause() async {
            log.record("capture.pause")
        }

        func resume() async throws {
            log.record("capture.resume")
            if let resumeError {
                throw resumeError
            }
        }
    }

    private struct SUT {
        let controller: SessionController
        let live: LivePartialState
        let latency: LatencyState
        let audioLevel: AudioLevelState
        let engine: ScriptedASREngine
        let capture: ScriptedCapture
        let log: CallLog
        var sentences: () -> [Sentence]
    }

    private func makeSUT(
        flush: [ASREvent] = [],
        resumeError: (any Error)? = nil,
        silenceGracePeriod: Duration = SessionController.noAudioWarningDelay
    ) -> SUT {
        let log = CallLog()
        let live = LivePartialState()
        let latency = LatencyState()
        let audioLevel = AudioLevelState()
        let engine = ScriptedASREngine(log: log, flush: flush)
        let capture = ScriptedCapture(log: log, resumeError: resumeError)
        let sentences = SentenceSink()
        let controller = SessionController(
            live: live, latency: latency, audioLevel: audioLevel,
            translationQueue: TranslationQueue(),
            makeEngine: { _, _ in engine },
            makeCapture: { capture },
            warmUpEnabled: { false },
            silenceGracePeriod: silenceGracePeriod
        )
        controller.onSentence = { sentence in sentences.record(sentence) }
        return SUT(
            controller: controller, live: live, latency: latency, audioLevel: audioLevel,
            engine: engine, capture: capture, log: log,
            sentences: { sentences.all }
        )
    }

    private final class SentenceSink: @unchecked Sendable {
        private let lock = NSLock()
        private var sentences: [Sentence] = []

        func record(_ sentence: Sentence) {
            lock.withLock { sentences.append(sentence) }
        }

        var all: [Sentence] {
            lock.withLock { sentences }
        }
    }

    // MARK: - Pause

    @Test("pause stops the capture first, then flushes the utterance")
    func pauseOrdersCaptureBeforeFlush() async throws {
        let sut = makeSUT()
        _ = try await sut.controller.begin(modelURL: nil, modelID: "test-model")

        await sut.controller.pause()

        #expect(sut.log.contains(inOrder: ["capture.start", "capture.pause", "engine.flushUtterance"]))
    }

    @Test("the flushed final lands as a sentence through the buffer flush")
    func pauseFlushesOpenUtteranceIntoSentence() async throws {
        let sut = makeSUT(flush: [
            .final(text: flushTailSentence, startSample: 0, endSample: 16000, lang: "ja")
        ])
        _ = try await sut.controller.begin(modelURL: nil, modelID: "test-model")

        await sut.controller.pause()

        #expect(sut.sentences().map { sentence in sentence.text } == [flushTailSentence])
    }

    @Test("pause clears the live partial, latency, and audio staging")
    func pauseClearsLiveSurfaces() async throws {
        let sut = makeSUT()
        _ = try await sut.controller.begin(modelURL: nil, modelID: "test-model")
        sut.live.partial = "認識中"
        sut.latency.update(1.5)
        sut.audioLevel.update(rms: 0.5)

        await sut.controller.pause()

        #expect(sut.live.partial == "")
        #expect(sut.latency.seconds == 0)
        #expect(sut.audioLevel.dBFS == -.infinity)
    }

    @Test("pause disarms the no-audio watchdog")
    func pauseDisarmsWatchdog() async throws {
        let sut = makeSUT(silenceGracePeriod: .milliseconds(100))
        _ = try await sut.controller.begin(modelURL: nil, modelID: "test-model")
        let warning = WarningFlag()
        sut.controller.onNoAudioDetected = { warning.fire() }
        sut.controller.armNoAudioWatchdog()

        await sut.controller.pause()
        try? await Task.sleep(for: .milliseconds(300))

        #expect(!warning.fired)
    }

    // MARK: - Resume

    @Test("resume restarts the capture")
    func resumeRestartsCapture() async throws {
        let sut = makeSUT()
        _ = try await sut.controller.begin(modelURL: nil, modelID: "test-model")
        await sut.controller.pause()

        try await sut.controller.resume()

        #expect(sut.log.contains(inOrder: ["capture.pause", "capture.resume"]))
    }

    @Test("resume re-arms the watchdog so a silent capture warns after the grace")
    func resumeRearmsWatchdog() async throws {
        let sut = makeSUT(silenceGracePeriod: .milliseconds(100))
        _ = try await sut.controller.begin(modelURL: nil, modelID: "test-model")
        let warning = WarningFlag()
        sut.controller.onNoAudioDetected = { warning.fire() }
        await sut.controller.pause()

        try await sut.controller.resume()
        let fired = await pollUntil { warning.fired }

        #expect(fired)
    }

    @Test("a failed resume rethrows so the owner can fall back to capture-lost")
    func failedResumeThrows() async throws {
        let sut = makeSUT(resumeError: CaptureError.setupFailed("boom"))
        _ = try await sut.controller.begin(modelURL: nil, modelID: "test-model")
        await sut.controller.pause()

        await #expect(throws: CaptureError.self) {
            try await sut.controller.resume()
        }
    }

    // MARK: - Stop after pause

    @Test("stop after pause tears down without a second flush decode")
    func stopAfterPauseTearsDown() async throws {
        let sut = makeSUT(flush: [
            .final(text: flushTailSentence, startSample: 0, endSample: 16000, lang: "ja")
        ])
        _ = try await sut.controller.begin(modelURL: nil, modelID: "test-model")
        await sut.controller.pause()

        await sut.controller.stop()

        #expect(sut.log.contains(inOrder: ["capture.pause", "capture.stop", "engine.finish"]))
        #expect(sut.log.names.filter { name in name == "engine.flushUtterance" }.count == 1)
        #expect(sut.sentences().map { sentence in sentence.text } == [flushTailSentence])
    }

    private final class WarningFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false

        func fire() {
            lock.withLock { value = true }
        }

        var fired: Bool {
            lock.withLock { value }
        }
    }
}
