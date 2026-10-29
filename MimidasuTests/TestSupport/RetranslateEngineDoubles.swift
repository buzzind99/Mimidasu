@testable import Mimidasu
import Synchronization

/// Session-engine fixture: prefixes with "EN:", recording each batch so a
/// test can pin exactly which sentences the queue served.
final class QueueEchoEngine: TranslationEngine, @unchecked Sendable {
    let preferredBatchSize = 16
    var onRetry: (@Sendable (RetryProgress) -> Void)?

    private let state = Mutex([[String]]())

    var recordedBatches: [[String]] {
        state.withLock { batches in batches }
    }

    func translate(_ texts: [String]) async throws -> [String] {
        state.withLock { batches in batches.append(texts) }
        return texts.map { text in "EN:\(text)" }
    }
}

/// Lane fixture: prefixes every input with "JA:", recording each batch.
final class LaneEchoEngine: TranslationEngine, @unchecked Sendable {
    let preferredBatchSize = 4
    var onRetry: (@Sendable (RetryProgress) -> Void)?

    private let state = Mutex([[String]]())

    var recordedBatches: [[String]] {
        state.withLock { batches in batches }
    }

    func translate(_ texts: [String]) async throws -> [String] {
        state.withLock { batches in batches.append(texts) }
        return texts.map { text in "JA:\(text)" }
    }
}

/// Lane fixture whose `translate` parks until the gate opens, so a test can
/// hold a flight mid-air and prove a second click does not start a competing
/// one and that a late landing is dropped. Completed flights are counted so
/// a negative assertion can wait on the flight it concerns instead of
/// sleeping past it.
final class LaneGatedEngine: TranslationEngine, @unchecked Sendable {
    let preferredBatchSize = 4
    var onRetry: (@Sendable (RetryProgress) -> Void)?

    private let state = Mutex(LaneGateState())

    var recordedBatches: [[String]] {
        state.withLock { gateState in gateState.batches }
    }

    /// Flights that entered, parked, and returned — the deterministic
    /// "this flight finished" observable.
    var completions: Int {
        state.withLock { gateState in gateState.completions }
    }

    /// Releases every parked `translate`, and lets any that arrives later
    /// through.
    func openGate() {
        let parked = state.withLock { gateState -> [CheckedContinuation<Void, Never>] in
            gateState.open = true
            let parked = gateState.waiters
            gateState.waiters.removeAll()
            return parked
        }
        for waiter in parked {
            waiter.resume()
        }
    }

    func translate(_ texts: [String]) async throws -> [String] {
        state.withLock { gateState in gateState.batches.append(texts) }
        await withCheckedContinuation { continuation in
            let immediate = state.withLock { gateState -> CheckedContinuation<Void, Never>? in
                guard !gateState.open else { return continuation }
                gateState.waiters.append(continuation)
                return nil
            }
            immediate?.resume()
        }
        state.withLock { gateState in gateState.completions += 1 }
        return texts.map { text in "JA:\(text)" }
    }
}

private struct LaneGateState {
    var open = false
    var batches: [[String]] = []
    var waiters: [CheckedContinuation<Void, Never>] = []
    var completions = 0
}
