import Foundation

/// Owns the engine's `flushUtterance` / `finish` ordering for one session.
/// A pause flush is started at most once per live stretch, its events are
/// delivered exactly once, and a stop consumes an airborne flush instead of
/// racing it. `idle` / `live` / `paused` describe a healthy session;
/// `pausing` / `stopping` / `finished` mark a decode or teardown in flight so
/// reentrant calls become no-ops instead of duplicate decodes.
@MainActor
final class SessionEngineChannel {
    enum PauseOutcome: Sendable {
        case delivered([ASREvent])
        case superseded
    }

    private enum Phase: Equatable {
        case idle
        case live
        case pausing
        case paused
        case stopping
        case finished
    }

    private var phase: Phase = .idle
    /// The pause flush in flight (or its completed result awaiting a stop's
    /// finish) — a superseded pause leaves it here so the one consumer left
    /// owns the events.
    private var pauseFlushTask: Task<[ASREvent], Never>?
    /// One-shot finish: a second concurrent `finish` awaits this task and
    /// returns no events, keeping the first caller the only delivery point.
    private var finishTask: Task<[ASREvent], Never>?

    /// Returns to `.idle` with both pending operations cleared — a new
    /// session always starts from a clean channel.
    func reset() {
        phase = .idle
        pauseFlushTask = nil
        finishTask = nil
    }

    /// The stream is open: a pause may flush the in-flight utterance.
    func started() {
        phase = .live
    }

    /// The capture is running again after a resume or a successful rebuild.
    /// Ignored while a pause flush is airborne and for the rest of teardown.
    func markLive() {
        switch phase {
        case .idle, .live, .paused:
            phase = .live
        case .pausing, .stopping, .finished:
            return
        }
    }

    /// Runs the pause flush off-main (the decode is a multi-second C call),
    /// stores it, and awaits it. Delivers only when nothing else took over
    /// while it ran; a stop/finish that superseded it leaves the pending task
    /// in place, and the teardown's `finish` owns its events.
    func pauseFlush(engine: ASREngine) async -> PauseOutcome {
        guard phase == .live else { return .superseded }
        phase = .pausing
        let flush = Task.detached(priority: .userInitiated) { engine.flushUtterance() }
        pauseFlushTask = flush
        let flushed = await flush.value
        guard phase == .pausing else { return .superseded }
        pauseFlushTask = nil
        phase = .paused
        return .delivered(flushed)
    }

    /// A stop was requested. Synchronous so the latch is visible before the
    /// caller's first suspension: an airborne pause flush is never cancelled
    /// or dropped — the following `finish` consumes it.
    func requestStop() {
        guard phase != .finished else { return }
        phase = .stopping
    }

    /// Final teardown: awaits and clears any pending pause flush, then runs
    /// `engine.finish()` off-main. Returns the flush events followed by the
    /// finish events, exactly once — a second/concurrent caller awaits the
    /// same one-shot task and gets no events.
    func finish(engine: ASREngine) async -> [ASREvent] {
        if let finishTask {
            _ = await finishTask.value
            return []
        }
        guard phase != .finished else { return [] }
        phase = .stopping
        let pending = pauseFlushTask
        pauseFlushTask = nil
        // The one-shot task owns both awaits: it is stored before the first
        // suspension, so a concurrent `finish` can only observe it.
        let task = Task.detached(priority: .userInitiated) { () -> [ASREvent] in
            let flushed = await pending?.value ?? []
            return flushed + engine.finish()
        }
        finishTask = task
        let events = await task.value
        if phase == .stopping {
            phase = .finished
        }
        return events
    }
}
