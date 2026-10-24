import Foundation
import Synchronization

/// One sentence per request through a chat model: the reply *is* the
/// translation, so a malformed reply fails one sentence rather than a batch.
/// Input is ASR output, so the shared prompt tells the model to infer intent
/// past recognition errors. Parsing is defensive and runs inside the
/// client's ladder; malformed output is retried as `.badResponse`.
///
/// The engine remembers a compatible-mode downgrade for its provider+model:
/// once the client had to drop the fast-mode fields, later sentences go out
/// without them from the first attempt.
struct LLMTranslationEngine: TranslationEngine {
    /// Long numbered lists degrade LLM adherence and translation quality;
    /// the queue slices every batch to one sentence.
    let preferredBatchSize = 1

    /// LLM replies are nondeterministic: `.badResponse` is a transient
    /// (retryable) failure, matching the ladder's `retriesBadResponse: true`.
    let transientBadResponse = true

    var onRetry: (@Sendable (RetryProgress) -> Void)?

    /// Selected target language; names the language in the system prompt.
    private let target: TargetLanguage

    private let client: any LLMChatClient

    private let modeState: CompatibleModeState

    init(
        target: TargetLanguage,
        client: any LLMChatClient,
        compatibleMode: Bool = false
    ) {
        self.target = target
        self.client = client
        modeState = CompatibleModeState(compatibleMode: compatibleMode)
    }

    var usedCompatibleMode: Bool {
        modeState.usedCompatibleMode
    }

    func translate(_ texts: [String]) async throws -> [String] {
        guard !texts.isEmpty else { return [] }

        // The queue slices batches to `preferredBatchSize == 1`, but stay
        // correct for any caller: one request per sentence, order preserved.
        var results: [String] = []
        results.reserveCapacity(texts.count)
        for text in texts {
            let reply = try await client.complete(
                LLMTranslationPrompt.messages(for: text, target: target),
                compatibleMode: modeState.isCompatible,
                onRetry: onRetry
            )
            modeState.record(reply.usedCompatibleMode)
            results.append(reply.text)
        }
        return results
    }
}

/// Class-backed lock storage: a struct conforming to `TranslationEngine` is
/// Copyable, while `Mutex` is non-Copyable, so the locks live in a reference
/// box shared by every copy of the engine value.
private final class CompatibleModeState: Sendable {
    private let compatibleMode = Mutex(false)
    private let observedCompatibleMode = Mutex(false)

    init(compatibleMode: Bool) {
        self.compatibleMode.withLock { stored in stored = compatibleMode }
    }

    var isCompatible: Bool {
        compatibleMode.withLock { stored in stored }
    }

    var usedCompatibleMode: Bool {
        observedCompatibleMode.withLock { observed in observed }
    }

    func record(_ usedCompatibleMode: Bool) {
        guard usedCompatibleMode else { return }
        compatibleMode.withLock { stored in stored = true }
        observedCompatibleMode.withLock { observed in observed = true }
    }
}
