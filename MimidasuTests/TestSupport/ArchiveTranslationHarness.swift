import Foundation
@testable import Mimidasu
import Synchronization

/// Shared fixture for the `AppModelArchiveTranslation` suite: a finalized
/// three-sentence archive (stored target `fr`) open in the pane, plus the
/// scripted engine doubles and toast/run predicates the suite asserts on.
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

/// Installs a factory returning `engine` for one provider and nil for
/// the rest — the test stand-in for a stored key.
@MainActor
func install(
    _ engine: ScriptedArchiveEngine, for provider: TranslationProvider, on model: AppModel
) {
    model.retranslateEngineFactory = { requested in requested == provider ? engine : nil }
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
