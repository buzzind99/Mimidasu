import Foundation
@testable import Mimidasu
import Testing

/// Tests `AppModel`'s pause/resume surface: the phase transitions, the
/// pause-excluded duration math, the watchdog/staging reset on resume, the
/// deferred capture-lost handling (no `.sourceLost` flip while paused; the
/// resume rebuild path; a failed resume reporting capture lost), and stop
/// from paused.
///
/// Excluded (audio HAL): the real IOProc stop/start — scripted doubles
/// record the calls.
@MainActor
@Suite(
    "AppModel pause",
    .enabled(if: DictionaryStore.resolve() != nil && InstalledJMDict.url != nil)
)
struct AppModelPauseTests {

    // MARK: - Fixtures

    private final class FlowLog: @unchecked Sendable {
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

        private let log: FlowLog
        private var remaining: [ASREvent] = []

        init(log: FlowLog) {
            self.log = log
        }

        /// Appends one more final; the poll tick picks it up on its next fire
        /// — the deterministic way to place a sentence in a chosen session.
        func enqueue(_ event: ASREvent) {
            remaining.append(event)
        }

        func prepare() {
            log.record("engine.prepare")
        }

        func openStream() {
            log.record("engine.openStream")
        }

        func push(_ samples: [Float]) {}

        func poll() -> ASREvent? {
            remaining.isEmpty ? nil : remaining.removeFirst()
        }

        func finish() -> [ASREvent] {
            log.record("engine.finish")
            return []
        }

        func flushUtterance() -> [ASREvent] {
            log.record("engine.flushUtterance")
            return []
        }
    }

    private final class ScriptedCapture: AudioCapturing, @unchecked Sendable {
        var onChunk: ((AudioChunk) -> Void)?
        var onIOError: ((CaptureError) -> Void)?

        private let log: FlowLog
        private let resumeError: (any Error)?
        private let pauseGate: PermitGate?
        private let resumeGate: PermitGate?

        init(
            log: FlowLog, resumeError: (any Error)? = nil,
            pauseGate: PermitGate? = nil, resumeGate: PermitGate? = nil
        ) {
            self.log = log
            self.resumeError = resumeError
            self.pauseGate = pauseGate
            self.resumeGate = resumeGate
        }

        func start() async throws {
            log.record("capture.start")
        }

        func stop() {
            log.record("capture.stop")
        }

        func pause() async {
            log.record("capture.pause")
            if let pauseGate {
                await pauseGate.acquire()
            }
        }

        func resume() async throws {
            log.record("capture.resume")
            if let resumeGate {
                await resumeGate.acquire()
            }
            if let resumeError {
                throw resumeError
            }
        }
    }

    private struct SUT {
        let model: AppModel
        let controller: SessionController
        let log: FlowLog
        let store: ArchiveStore
        let engine: ScriptedASREngine
    }

    /// A model over a real `SessionController` with scripted engine/capture.
    /// `resumeError` makes the capture's `resume()` fail; `pauseGate` /
    /// `resumeGate` park the capture transitions so a racing resume can be
    /// observed mid-flight.
    private func makeSUT(
        resumeError: (any Error)? = nil,
        pauseGate: PermitGate? = nil,
        resumeGate: PermitGate? = nil
    ) async -> SUT {
        let log = FlowLog()
        let engine = ScriptedASREngine(log: log)
        let capture = ScriptedCapture(
            log: log, resumeError: resumeError, pauseGate: pauseGate, resumeGate: resumeGate
        )
        let store = isolatedArchive()
        let model = AppModel(
            makeSessionController: { live, latency, _, translationQueue in
                SessionController(
                    live: live, latency: latency, translationQueue: translationQueue,
                    makeEngine: { _, _ in engine },
                    makeCapture: { capture },
                    warmUpEnabled: { false },
                    // No `.translationTask` host exists in tests, so a landed
                    // sentence never drains; the short bound keeps `stop` from
                    // waiting out the production 5 s window.
                    translationDrainTimeout: 0.05
                )
            },
            translationSettings: isolatedTranslationSettings(suite: "test.AppModelPause"),
            asrModelSettings: isolatedASRModelSettings(suite: "test.AppModelPause"),
            favorites: isolatedFavorites(),
            archive: store,
            highFidelityProbe: { _ in false },
            initialModelResolve: { _ in nil },
            retireWarmEngine: { log.record("engine.retire") }
        )
        await model.initialModelCheck?.value
        await model.refreshModelAvailability(
            resolve: { _ in URL(fileURLWithPath: "/tmp/model.gguf") }
        )
        return SUT(
            model: model, controller: model.sessionController, log: log,
            store: store, engine: engine
        )
    }

    private func startRunning(_ sut: SUT) async {
        sut.model.start()
        #expect(await pollUntil { sut.model.phase == .running }, "session comes up")
    }

    // MARK: - Phase transitions

    @Test("pause is refused outside .running")
    func pauseOnlyFromRunning() async {
        let sut = await makeSUT()

        sut.model.pause()
        #expect(sut.model.phase == .idle)

        await startRunning(sut)
        sut.model.pause()
        sut.model.pause()
        #expect(sut.model.phase == .paused)

        sut.model.stop()
        #expect(await pollUntil { sut.model.phase == .idle })
    }

    @Test("resume returns a paused session to running")
    func resumeReturnsToRunning() async {
        let sut = await makeSUT()
        await startRunning(sut)
        sut.model.pause()
        #expect(sut.model.phase == .paused)

        sut.model.resume()

        #expect(await pollUntil { sut.model.phase == .running })
        #expect(sut.log.contains(inOrder: ["capture.pause", "capture.resume"]))

        sut.model.stop()
        #expect(await pollUntil { sut.model.phase == .idle })
    }

    // MARK: - Duration math

    @Test("the active duration excludes accumulated and open paused spans")
    func activeDurationExcludesPaused() async {
        let sut = await makeSUT()
        let now = ContinuousClock.now
        sut.model.sessionStartedAt = now.advanced(by: .seconds(-10))
        sut.model.sessionPausedTotal = .seconds(3)

        // Completed span only: 10 s elapsed − 3 s paused.
        let completed = sut.model.activeSessionDurationMS(to: now)
        #expect(completed != nil)
        #expect(abs((completed ?? 0) - 7000) <= 50)

        // Open pause span: 2 more seconds already spent paused.
        sut.model.pauseStartedAt = now.advanced(by: .seconds(-2))
        let open = sut.model.activeSessionDurationMS(to: now)
        #expect(abs((open ?? 0) - 5000) <= 50)

        // No session yet: nil.
        sut.model.sessionStartedAt = nil
        #expect(sut.model.activeSessionDurationMS(to: now) == nil)
    }

    @Test("a completed resume folds the pause span into the accumulated paused total")
    func resumeAccumulatesPausedSpan() async {
        let sut = await makeSUT()
        await startRunning(sut)
        sut.model.pause()
        #expect(await pollUntil { sut.model.phase == .paused })
        try? await Task.sleep(for: .milliseconds(50))

        sut.model.resume()

        #expect(await pollUntil { sut.model.phase == .running })
        #expect(
            sut.model.sessionPausedTotal >= .milliseconds(50),
            "the paused span is accumulated on the resume"
        )
        #expect(sut.model.pauseStartedAt == nil, "the open span is closed")

        sut.model.stop()
        #expect(await pollUntil { sut.model.phase == .idle })
    }

    // MARK: - Deferred capture-lost

    @Test("capture loss while paused is deferred, not surfaced")
    func captureLossWhilePausedIsDeferred() async {
        let sut = await makeSUT()
        await startRunning(sut)
        sut.model.pause()
        #expect(sut.model.phase == .paused)

        sut.controller.onCaptureError?("device died")

        #expect(sut.model.phase == .paused)
        #expect(sut.model.deferredCaptureError == "device died")
        #expect(!sut.model.toasts.toasts.contains { toast in toast.key == ToastKey.captureLost })
    }

    @Test("a successful resume clears a deferral observed while it was in flight")
    func resumeClearsConcurrentDeferral() async {
        let gate = PermitGate()
        let sut = await makeSUT(resumeGate: gate)
        await startRunning(sut)
        sut.model.pause()
        #expect(await pollUntil { sut.log.contains(inOrder: ["capture.pause"]) })

        sut.model.resume()
        #expect(
            await pollUntil { sut.log.contains(inOrder: ["capture.resume"]) },
            "the resume parks on its gate"
        )
        sut.controller.onCaptureError?("device died")
        #expect(sut.model.deferredCaptureError == "device died", "the error defers while paused")

        gate.release()

        #expect(await pollUntil { sut.model.phase == .running })
        #expect(
            sut.model.deferredCaptureError == nil,
            "the successful resume clears the stale deferral"
        )

        sut.model.stop()
        #expect(await pollUntil { sut.model.phase == .idle })
    }

    @Test("a deferred-error resume waits for the airborne pause before rebuilding")
    func deferredResumeChainsBehindAirbornePause() async {
        let gate = PermitGate()
        let sut = await makeSUT(pauseGate: gate)
        await startRunning(sut)
        sut.model.pause()
        #expect(
            await pollUntil { sut.log.contains(inOrder: ["capture.pause"]) },
            "the pause parks on its gate"
        )
        #expect(sut.model.phase == .paused)

        sut.model.deferredCaptureError = "device died"
        sut.model.resume()

        // The pause task still holds the transition, so the rebuild must not
        // have begun yet; without the chain it would flip the phase to
        // `.starting` synchronously.
        try? await Task.sleep(for: .milliseconds(50))
        #expect(sut.model.phase == .paused, "the restart waits behind the pause")
        #expect(
            sut.log.names.filter { name in name == "capture.start" }.count == 1,
            "no capture restart starts while the pause is airborne"
        )

        gate.release()

        #expect(
            await pollUntil { sut.model.phase == .running },
            "the released chain rebuilds the capture and resumes"
        )
        #expect(sut.log.names.filter { name in name == "capture.start" }.count == 2)
        #expect(sut.model.deferredCaptureError == nil)

        sut.model.stop()
        #expect(await pollUntil { sut.model.phase == .idle })
    }

    @Test("resume with a deferred error rebuilds the capture instead of resuming it")
    func resumeWithDeferredErrorRebuildsCapture() async {
        let sut = await makeSUT()
        await startRunning(sut)
        sut.model.pause()
        #expect(await pollUntil { sut.log.contains(inOrder: ["capture.pause"]) })
        sut.model.deferredCaptureError = "device died"

        sut.model.resume()

        #expect(await pollUntil { sut.model.phase == .running })
        #expect(sut.model.deferredCaptureError == nil)
        // The rebuild restarts the capture (a fresh stream) and never calls
        // the dead stream's resume.
        #expect(sut.log.names.filter { name in name == "capture.start" }.count == 2)
        #expect(!sut.log.names.contains("capture.resume"))

        sut.model.stop()
        #expect(await pollUntil { sut.model.phase == .idle })
    }

    @Test("a failed resume falls back to the capture-lost flow")
    func failedResumeReportsCaptureLost() async {
        let gate = PermitGate()
        let sut = await makeSUT(resumeError: CaptureError.setupFailed("boom"), resumeGate: gate)
        await startRunning(sut)
        sut.model.pause()
        #expect(await pollUntil { sut.log.contains(inOrder: ["capture.pause"]) })

        sut.model.resume()
        #expect(
            await pollUntil { sut.log.contains(inOrder: ["capture.resume"]) },
            "the resume parks on its gate"
        )
        sut.controller.onCaptureError?("device died")
        #expect(sut.model.deferredCaptureError == "device died")
        gate.release()

        #expect(await pollUntil { sut.model.phase == .sourceLost })
        #expect(sut.model.toasts.toasts.contains { toast in toast.key == ToastKey.captureLost })
        #expect(
            sut.model.deferredCaptureError == nil,
            "the failed resume clears the stale deferral"
        )
    }

    // MARK: - Stop from paused

    @Test("stop from paused finalizes the session normally")
    func stopFromPausedFinalizes() async {
        let sut = await makeSUT()
        await startRunning(sut)
        sut.model.pause()
        #expect(sut.model.phase == .paused)

        sut.model.stop()

        #expect(await pollUntil { sut.model.phase == .idle })
        #expect(sut.log.contains(inOrder: ["capture.stop", "engine.finish"]))
    }

    @Test("stop from paused closes the final pause span and persists it")
    func stopFromPausedClosesPauseSpan() async {
        let sut = await makeSUT()
        await startRunning(sut)
        sut.engine.enqueue(
            .final(text: "こんにちは。", startSample: 0, endSample: 16000, lang: "ja")
        )
        #expect(
            await pollUntil { sut.model.recordingSessionID != nil },
            "the sentence creates the recording row"
        )

        sut.model.pause()
        #expect(await pollUntil { sut.model.phase == .paused })
        try? await Task.sleep(for: .milliseconds(400))

        sut.model.stop()
        #expect(await pollUntil(timeout: 8) { sut.model.phase == .idle }, "stop winds down")

        #expect(sut.model.pauseStartedAt == nil, "the open pause span is closed by the stop")
        guard let summary = sut.store.list().first,
              let started = sut.model.sessionStartedAt,
              let ended = sut.model.sessionEndedAt
        else {
            Issue.record("the stopped session should be stored with its clock anchors")
            return
        }
        #expect(summary.pausedMS >= 400, "the stored paused time carries the final span")
        let activeMS = AppModel.milliseconds(of: ended - started) - summary.pausedMS
        #expect(
            abs((summary.durationS ?? 0) * 1000 - activeMS) <= 1000,
            "the stored duration excludes the paused span"
        )
    }

    @Test("quitting while paused closes the open pause span")
    func quitWhilePausedClosesPauseSpan() async {
        let sut = await makeSUT()
        await startRunning(sut)
        sut.model.pause()
        #expect(await pollUntil { sut.model.phase == .paused })

        await sut.model.shutdownForTermination()

        #expect(sut.model.pauseStartedAt == nil, "the quit-time teardown closes the pause span")
        #expect(sut.model.phase == .idle)
        #expect(sut.log.names.contains("engine.retire"))
    }
}

extension AppModelPauseTests {
    @Test("a normal resume waits for the airborne pause before restarting capture")
    func normalResumeChainsBehindAirbornePause() async {
        let gate = PermitGate()
        let sut = await makeSUT(pauseGate: gate)
        await startRunning(sut)
        sut.model.pause()
        #expect(
            await pollUntil { sut.log.contains(inOrder: ["capture.pause"]) },
            "the pause parks on its gate"
        )
        #expect(sut.model.phase == .paused)

        sut.model.resume()

        // The pause transition still holds the capture, so the resume must
        // not reach the HAL; the phase stays `.paused` until the IOProc is
        // actually back.
        let resumedWhilePaused = await pollUntil(timeout: 0.05) {
            sut.log.names.contains("capture.resume")
        }
        #expect(!resumedWhilePaused, "the resume waits behind the airborne pause")
        #expect(sut.model.phase == .paused, "the phase does not flip while the resume is chained")

        gate.release()

        #expect(await pollUntil { sut.model.phase == .running })
        #expect(sut.log.contains(inOrder: ["capture.pause", "capture.resume"]))

        sut.model.stop()
        #expect(await pollUntil { sut.model.phase == .idle })
    }
}
