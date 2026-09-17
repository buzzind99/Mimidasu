import Foundation

// MARK: - Draining & teardown

extension CrispASREngine {
    func poll() -> ASREvent? {
        state.withLock { current -> ASREvent? in
            guard !current.inbox.isEmpty else { return nil }
            return current.inbox.removeFirst()
        }
    }

    func finish() -> [ASREvent] {
        state.withLock { current in current.finishing = true }
        // Wait (bounded) for any in-flight decode or VAD pass to finish.
        // The deadline caps the TOTAL wait: each semaphore wait is at most
        // the remaining budget, so a hung decode/VAD call (its flag never
        // clears) delays teardown by at most `drainTimeout` instead of
        // re-arming a fresh 30 s wait forever. Each pass re-checks the flags
        // in its own `withLock` scope — release/wait/relock around the
        // bounded semaphore wait.
        let deadline = ContinuousClock.now + Duration.seconds(drainTimeout)
        while true {
            let inFlight = state.withLock { current in
                current.decodeInFlight || current.vadInFlight
            }
            if !inFlight {
                break
            }
            let remaining = deadline - ContinuousClock.now
            if remaining <= .zero {
                break
            }
            let components = remaining.components
            let nanoseconds = components.seconds * 1_000_000_000
                + components.attoseconds / 1_000_000_000
            _ = jobFinished.wait(timeout: .now() + .nanoseconds(Int(nanoseconds)))
        }

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

        if hadSpeech, let sessionHandle {
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

        return state.withLock { current -> [ASREvent] in
            let drained = current.inbox
            current.inbox = []
            return drained
        }
    }

    /// Releases the C session (and the resident model) permanently. Not part
    /// of normal teardown — sessions stay warm so restarts are instant. Used
    /// only when the factory discards the engine (e.g. the model file was
    /// replaced and a fresh one takes its place).
    func close() {
        prepareMutex.withLock { _ in
            let sessionHandle = state.withLock { current -> OpaquePointer? in
                current.finishing = true
                let handle = current.session
                current.session = nil
                return handle
            }
            if let sessionHandle {
                lib.closeSession(sessionHandle)
            }
        }
    }
}
