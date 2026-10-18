import Foundation
@testable import Mimidasu
import Synchronization

/// Shared fixtures for the archive-translation suites: the
/// `AppModelArchiveTranslation` harness (a finalized three-sentence archive
/// stored target `fr`, open in the pane, plus the scripted engine doubles
/// and toast/run predicates), and the `ArchiveTranslationJob` suite's
/// recorder/gate/engine doubles.
@MainActor
struct ArchiveTranslationSUT {
    let model: AppModel
    let store: ArchiveStore
    let id: Int64
}

private func metadata(target: String) -> SessionMetadata {
    SessionMetadata(
        startedAt: Date(timeIntervalSince1970: 1_000_000),
        sourceLang: "ja", targetLang: target, model: "test-model", chunkMS: 160
    )
}

private func sentence(_ index: Int, text: String) -> Sentence {
    Sentence(index: index, startS: Double(index), endS: Double(index) + 1, lang: "ja", text: text)
}

/// Seeds a finalized three-sentence archive (stored target `fr`) open in the
/// pane; `translations` seeds pre-existing rows by sentence index.
@MainActor
func makeSUT(
    suite: String = "test.AppModelArchiveTranslation",
    sentences: [String] = ["こんにちは", "さようなら", "おはよう"],
    target: String = "fr",
    translations: [Int: String] = [:]
) async -> ArchiveTranslationSUT {
    let store = isolatedArchive()
    var id: Int64?
    for (index, text) in sentences.enumerated() {
        id = store.append(
            sentence: sentence(index, text: text), sessionID: id, metadata: metadata(target: target)
        )
    }
    let finalized = id ?? -1
    for (index, text) in translations {
        store.upsert(
            translation: SentenceTranslation(lang: target, text: text),
            index: index, session: finalized
        )
    }
    store.finalize(session: finalized, durationMS: 60000, saved: false)

    let model = AppModel(
        translationSettings: isolatedTranslationSettings(suite: suite),
        asrModelSettings: isolatedASRModelSettings(suite: suite),
        favorites: isolatedFavorites(),
        archive: store,
        highFidelityProbe: { _ in false },
        initialModelResolve: { _ in nil }
    )
    await model.initialModelCheck?.value
    model.openArchiveSession(id: finalized)
    return ArchiveTranslationSUT(model: model, store: store, id: finalized)
}

/// Appends one finalized archive (stored target `fr` unless given) to
/// `store` and returns its id — the second pane the cross-archive tests
/// swap to.
@MainActor
func appendArchive(
    to store: ArchiveStore, sentences: [String] = ["bonjour"], target: String = "fr"
) -> Int64 {
    var id: Int64?
    for (index, text) in sentences.enumerated() {
        id = store.append(
            sentence: sentence(index, text: text), sessionID: id, metadata: metadata(target: target)
        )
    }
    let finalized = id ?? -1
    store.finalize(session: finalized, durationMS: 60000, saved: false)
    return finalized
}

/// Installs a factory returning `engine` for one provider and nil for
/// the rest — the test stand-in for a stored key.
@MainActor
func install(
    _ engine: ScriptedArchiveEngine, for provider: TranslationProvider, on model: AppModel
) {
    model.retranslateEngineFactory = { requested, _ in requested == provider ? engine : nil }
}

@MainActor
func archiveToast(_ model: AppModel) -> ToastCenter.Toast? {
    model.toasts.toasts.first { toast in toast.key == ToastKey.archiveTranslation }
}

@MainActor
func retranslateToast(_ model: AppModel) -> ToastCenter.Toast? {
    model.toasts.toasts.first { toast in toast.key == ToastKey.retranslate }
}

/// The run's terminal predicate: the expected translate count landed and
/// the job slot released.
@MainActor
func runFinished(_ model: AppModel, translated: Int) -> Bool {
    model.archiveTranslationJob.translatedCount == translated
        && !model.archiveTranslationRunning
}

/// A per-call parking gate: `acquire` parks until a matching `release`, so a
/// run can be held mid-sentence without sleeps. A release with no parked
/// call pre-authorizes the next one.
final class PermitGate: @unchecked Sendable {
    private struct State {
        var permits = 0
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    func release() {
        let waiter = state.withLock { current -> CheckedContinuation<Void, Never>? in
            guard !current.waiters.isEmpty else {
                current.permits += 1
                return nil
            }
            return current.waiters.removeFirst()
        }
        waiter?.resume()
    }

    func acquire() async {
        await withCheckedContinuation { continuation in
            let immediate = state.withLock { current -> CheckedContinuation<Void, Never>? in
                guard current.permits == 0 else {
                    current.permits -= 1
                    return continuation
                }
                current.waiters.append(continuation)
                return nil
            }
            immediate?.resume()
        }
    }
}

/// Deterministic engine double: translates `text` to `"T:\(text)"`, records
/// every batch (the job sends one sentence per call), fails on scripted
/// texts, and can park every call on a permit gate.
final class ScriptedArchiveEngine: TranslationEngine, @unchecked Sendable {
    let preferredBatchSize = 1
    var onRetry: (@Sendable (RetryProgress) -> Void)?

    private struct State {
        var batches: [[String]] = []
        var failing: Set<String> = []
    }

    private let state = Mutex(State())
    private let gate: PermitGate?

    init(gate: PermitGate? = nil) {
        self.gate = gate
    }

    var recordedBatches: [[String]] {
        state.withLock { current in current.batches }
    }

    /// Inputs that throw instead of translating.
    func fail(on texts: Set<String>) {
        state.withLock { current in current.failing.formUnion(texts) }
    }

    func clearFailures() {
        state.withLock { current in current.failing.removeAll() }
    }

    func translate(_ texts: [String]) async throws -> [String] {
        state.withLock { current in current.batches.append(texts) }
        if let gate {
            await gate.acquire()
        }
        try Task.checkCancellation()
        let failing = state.withLock { current in current.failing }
        if texts.contains(where: { text in failing.contains(text) }) {
            throw TranslationEngineError.serverError(500)
        }
        return texts.map { text in "T:\(text)" }
    }
}

// MARK: - Fixtures

/// The job's event and landing sinks, kept together so a test can script a
/// one-shot cancel after the Nth landing.
@MainActor
final class Recorder {
    private(set) var events: [ArchiveTranslationJob.Event] = []
    private(set) var landedIndexes: [Int] = []
    private(set) var landed: [SentenceTranslation] = []

    /// The landing ordinal that triggers `cancel` once, then defuses.
    var cancelAfterLandings: Int?
    var cancel: (@MainActor () -> Void)?

    func recordEvent(_ event: ArchiveTranslationJob.Event) {
        events.append(event)
    }

    /// Indexes whose landing reports a lost write (an upsert that failed).
    var unlandedIndexes: Set<Int> = []

    func recordLanding(_ index: Int, _ translation: SentenceTranslation) -> Bool {
        landedIndexes.append(index)
        landed.append(translation)
        if landedIndexes.count == cancelAfterLandings {
            cancelAfterLandings = nil
            cancel?()
        }
        return !unlandedIndexes.contains(index)
    }
}

/// A one-shot gate: `wait()` parks until `open()` releases every waiter, and
/// later calls pass straight through. The entered count is the deterministic
/// "the run reached this point" observable.
final class AsyncGate: @unchecked Sendable {
    private struct State {
        var open = false
        var entered = 0
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    var enteredCount: Int {
        state.withLock { current in current.entered }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            let immediate = state.withLock { current -> CheckedContinuation<Void, Never>? in
                current.entered += 1
                guard !current.open else { return continuation }
                current.waiters.append(continuation)
                return nil
            }
            immediate?.resume()
        }
    }

    func open() {
        let parked = state.withLock { current -> [CheckedContinuation<Void, Never>] in
            current.open = true
            let waiters = current.waiters
            current.waiters.removeAll()
            return waiters
        }
        for waiter in parked {
            waiter.resume()
        }
    }
}

/// Deterministic engine double: translates `text` to `"T:\(text)"`, records
/// every batch (one sentence per call, the job's contract), fails or
/// engine-cancels on scripted inputs, and can park each call on a gate until
/// released.
final class ScriptedEngine: TranslationEngine, @unchecked Sendable {
    let preferredBatchSize = 1
    var onRetry: (@Sendable (RetryProgress) -> Void)?

    private struct State {
        var batches: [[String]] = []
        var failing: Set<String> = []
        var cancelling: Set<String> = []
        let gate: AsyncGate?
    }

    private let state: Mutex<State>

    init(gate: AsyncGate? = nil) {
        state = Mutex(State(gate: gate))
    }

    var recordedBatches: [[String]] {
        state.withLock { current in current.batches }
    }

    /// Inputs that throw instead of translating.
    func fail(on texts: Set<String>) {
        state.withLock { current in current.failing.formUnion(texts) }
    }

    /// Inputs whose call throws `CancellationError` without the task being
    /// cancelled.
    func cancel(on texts: Set<String>) {
        state.withLock { current in current.cancelling.formUnion(texts) }
    }

    func clearFailures() {
        state.withLock { current in current.failing.removeAll() }
    }

    func translate(_ texts: [String]) async throws -> [String] {
        let gate = state.withLock { current -> AsyncGate? in
            current.batches.append(texts)
            return current.gate
        }
        if let gate {
            await gate.wait()
        }
        try Task.checkCancellation()
        let (failing, cancelling) = state.withLock { current in
            (current.failing, current.cancelling)
        }
        if texts.contains(where: { text in cancelling.contains(text) }) {
            throw CancellationError()
        }
        if texts.contains(where: { text in failing.contains(text) }) {
            throw TranslationEngineError.serverError(500)
        }
        return texts.map { text in "T:\(text)" }
    }
}
