import Foundation

// MARK: - Draining & teardown

extension CrispASREngine {
    func poll() -> ASREvent? {
        state.withLock { current -> ASREvent? in
            guard !current.inbox.isEmpty else { return nil }
            return current.inbox.removeFirst()
        }
    }

    /// Waits (bounded) for in-flight decode/VAD jobs to finish. Returns true
    /// when the engine was idle (or became idle within `timeout`); false when
    /// a job was still in flight at the deadline — that job may still be
    /// running a C call in the runtime (a decode also holds a snapshot of
    /// the session handle past the state mutex), so callers must then
    /// neither decode on the session again nor free it.
    ///
    /// The deadline caps the TOTAL wait: each semaphore wait is at most
    /// the remaining budget, so a hung decode/VAD call (its flag never
    /// clears) delays the caller by at most `timeout` instead of
    /// re-arming a fresh 30 s wait forever. Each pass re-checks the flags
    /// in its own `withLock` scope — release/wait/relock around the
    /// bounded semaphore wait. Concurrent drains (a `finish()` racing a
    /// `close()`) share the one job semaphore, so a waiter that loses the
    /// signal count only observes idleness when its bounded wait expires;
    /// the flag re-check then returns immediately — a one-off budget
    /// burn, never a hang.
    private func awaitIdleJobs(timeout: TimeInterval) -> Bool {
        let deadline = ContinuousClock.now + Duration.seconds(timeout)
        while true {
            let inFlight = state.withLock { current in
                current.decodeInFlight || current.vadInFlight
            }
            if !inFlight {
                return true
            }
            let remaining = deadline - ContinuousClock.now
            if remaining <= .zero {
                return false
            }
            let components = remaining.components
            let nanoseconds = components.seconds * 1_000_000_000
                + components.attoseconds / 1_000_000_000
            _ = jobFinished.wait(timeout: .now() + .nanoseconds(Int(nanoseconds)))
        }
    }

    func finish() -> [ASREvent] {
        state.withLock { current in current.finishing = true }
        let drainedCleanly = awaitIdleJobs(timeout: drainTimeout)

        // Flush any open utterance synchronously — capture has already
        // stopped, so nothing new can arrive. Skip speechless buffers
        // (VAD-confirmed silence, or the RMS backstop in degraded mode).
        // Snapshot under the state mutex: `close()` nils the session there.
        let (pcm, start, end, hadSpeech, sessionHandle) = state.withLock { current in
            (
                current.utterance,
                current.vadFirstSpeechStartSample ?? current.utteranceStartSample,
                current.vadLastSpeechEndSample ?? (current.utteranceStartSample + current.utterance.count),
                current.utteranceHasSpeech || (!current.vadActive && current.utteranceHasLoudAudio),
                current.session
            )
        }

        // The flush decode only runs on a drained engine: a job that
        // outlived the drain still owns the session, and two concurrent
        // `transcribe` calls on one session are undefined. The hung job's
        // text is lost; everything already in the inbox still drains below.
        // The decode holds `prepareMutex` — the same lock `close()` takes
        // before its drain — so a concurrent close can only free (or leak)
        // the session after the flush has left it, never underneath it.
        // The handle was snapshotted before the lock, though, so the lock
        // alone is not protection enough: a close could acquire it first
        // (its drain cannot see this not-yet-started, unflagged flush) and
        // free the session in between — the in-lock re-check below skips
        // the flush then. The re-check is pointer equality, so it only
        // guarantees the nilled-session case; production never reopens a
        // closed engine, so a reused address is not a live concern.
        if drainedCleanly, hadSpeech, let sessionHandle {
            prepareMutex.withLock { _ in
                guard state.withLock({ current in current.session }) == sessionHandle else { return }
                if let raw = decode(pcm: pcm, session: sessionHandle) {
                    let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    #if DEBUG
                        print("[asr] flush decode: \(pcm.count) samples -> \(text.isEmpty ? "no text" : "\(text.count) chars")")
                    #endif
                    if !text.isEmpty {
                        state.withLock { current in
                            current.inbox.append(.final(
                                text: text, startSample: start, endSample: end, lang: languageCode
                            ))
                        }
                    }
                }
            }
        }

        return state.withLock { current -> [ASREvent] in
            let drained = current.inbox
            current.inbox = []
            return drained
        }
    }

    /// Releases the C session (and the resident model) permanently. Not part
    /// of normal teardown — sessions stay warm so restarts are instant. Used
    /// only when the factory discards the engine (e.g. the model file was
    /// replaced, or the app quit).
    ///
    /// A short bounded drain runs first: an in-flight decode/VAD job may
    /// still be running a C call in the runtime (a decode also holds a
    /// session snapshot past the state mutex), so freeing underneath it
    /// would be a use-after-free. On a drained engine the session is freed
    /// and `true` returned. When a job outlived the grace, the session is
    /// deliberately leaked — never freed under a running C call — and
    /// `false` returned so the caller skips further runtime teardown too
    /// (the factory latches its poisoned-runtime flag, so the quit-time
    /// cached-model free is skipped as well; the OS reclaims the leak at
    /// exit). A session-less engine closes vacuously clean — an expired
    /// drain still reports the leak even then, since a job may still be
    /// running in the runtime.
    @discardableResult
    func close() -> Bool {
        prepareMutex.withLock { _ in
            // Latch `finishing` before the drain (as `finish()` does) so no
            // new job can be scheduled behind it; the drain then waits out
            // only jobs already in flight.
            state.withLock { current in current.finishing = true }
            let drained = awaitIdleJobs(timeout: closeDrainTimeout)
            let sessionHandle = state.withLock { current -> OpaquePointer? in
                let handle = current.session
                current.session = nil
                return handle
            }
            guard drained else {
                #if DEBUG
                    print("[asr] close: a job outlived the drain — leaking the session, skipping the runtime free")
                #endif
                return false
            }
            guard let sessionHandle else { return true }
            lib.closeSession(sessionHandle)
            return true
        }
    }
}
