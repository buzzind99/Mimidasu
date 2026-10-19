import Foundation

/// The transition entry points of `SessionController`: `pause()`, `resume()`,
/// `restartCapture()`, and `stop()` are enqueued on one serial main-actor
/// queue so their capture and engine calls can never interleave. `stop()` is
/// latched synchronously at request time — before its first suspension — so
/// an airborne transition observes it after every await and leaves the
/// teardown to the queued `performStop()`; that ordering closes the HAL races
/// between a stop and an airborne pause, resume, or rebuild. `begin()` waits
/// the tail out for a clean start.
extension SessionController {
    /// Suspends the live session without ending it: the capture stops at the
    /// IOProc (no callbacks while paused), the in-flight utterance is flushed
    /// through the engine so speech spoken just before pausing still lands as
    /// a sentence, and the live surfaces clear. Timers keep running so the
    /// flush final and the buffer tick close what the flush emits. The
    /// translation queue is deliberately left alone — enqueued sentences
    /// finish normally.
    func pause() async {
        let task = enqueue { controller in
            await controller.performPause()
        }
        pauseCompletedTask = task
        await task.value
    }

    /// Resumes the capture stopped by `pause()`: restarts the IOProc, arms a
    /// fresh no-audio watchdog grace window, and resets the presence latch so
    /// that grace restarts genuinely instead of counting the pre-pause
    /// silence. Throws when the rig is gone or the HAL refuses the restart —
    /// the owner then falls back to the capture-lost rebuild flow.
    func resume() async throws {
        let outcome = TransitionOutcome()
        let task = enqueue { controller in
            do {
                try await controller.performResume()
                outcome.result = .success(())
            } catch {
                outcome.result = .failure(error)
            }
        }
        await task.value
        try outcome.result?.get()
    }

    /// Rebuilds the capture stream mid-session after the source died — the
    /// `capture.lost` toast's Restart action. The engine, timers, sentence
    /// buffer, and translation queue are untouched (no model reload, and
    /// `onSessionBegin` does not re-fire). A no-op without a live engine
    /// (the session is already down) or once a stop owns the teardown.
    func restartCapture() async throws {
        let outcome = TransitionOutcome()
        let task = enqueue { controller in
            do {
                try await controller.performRestartCapture()
                outcome.result = .success(())
            } catch {
                outcome.result = .failure(error)
            }
        }
        await task.value
        try outcome.result?.get()
    }

    /// Tears the session down, ordered so pending translations finish first:
    /// the final flushed sentence is enqueued, and only after the translation
    /// queue drains (bounded by a timeout) does the session wind down, which
    /// keeps the tail of the session exportable with translations intact. The
    /// engine stays warm — the loaded model is reused by the next session.
    ///
    /// The stop is latched before it is enqueued: the channel refuses any new
    /// pause flush, an airborne one is consumed by the stop's `finish`, and a
    /// pause/resume/restart waking from its own await skips the work the stop
    /// now owns. The queued teardown waits out whatever transition is ahead
    /// of it, so the HAL calls stay serialized.
    func stop() async {
        stopRequested = true
        requestEngineStop()
        let task = enqueue { controller in
            await controller.performStop()
        }
        await task.value
    }

    /// Awaits the most recently enqueued pause transition; a no-op when none
    /// was requested. The deferred-resume path reads it to chain a rebuild
    /// behind an airborne pause flush.
    func awaitPauseCompletion() async {
        await pauseCompletedTask?.value
    }

    /// The queue primitive: captures the current tail, then appends an
    /// operation that waits that tail out before running. The tail is stored
    /// before the operation can start, so concurrent callers chain in call
    /// order; it stays `Task<Void, Never>`, so one failed operation cannot
    /// break the chain — throwing operations report through an outcome box.
    @discardableResult
    private func enqueue(
        _ operation: @escaping @MainActor (SessionController) async -> Void
    ) -> Task<Void, Never> {
        let previous = transitionTail
        let task = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            await operation(self)
        }
        transitionTail = task
        return task
    }
}

/// Rethrow channel for the queued throwing transitions: the queue tail is
/// non-throwing, so the queued operation writes its outcome here and the
/// caller reads it back after the task completes.
@MainActor
private final class TransitionOutcome {
    var result: Result<Void, any Error>?
}
