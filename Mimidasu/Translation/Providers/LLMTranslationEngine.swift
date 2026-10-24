import Foundation
import Synchronization

/// One sentence per request through a chat model: the reply *is* the
/// translation, so a malformed reply fails one sentence rather than a batch.
/// Input is ASR output, so the shared prompt tells the model to infer intent
/// past recognition errors. Parsing is defensive and runs inside the
/// client's ladder; malformed output is retried as `.badResponse`.
///
/// The engine remembers a compatible-mode downgrade for its lifetime: once
/// the client had to drop the fast-mode fields, later sentences go out
/// without them from the first attempt. `onCompatibleModeLearned` lets the
/// owner persist that fact for future engines (keyed by provider+model).
struct LLMTranslationEngine: TranslationEngine {
    /// Long numbered lists degrade LLM adherence and translation quality;
    /// the queue slices every batch to one sentence.
    let preferredBatchSize = 1

    /// LLM replies are nondeterministic: `.badResponse` is a transient
    /// (retryable) failure when the client's ladder retries it. The factory
    /// derives this from the injected ladder so the queue's severity matches
    /// the engine's actual retry posture.
    let transientBadResponse: Bool

    var onRetry: (@Sendable (RetryProgress) -> Void)?

    /// Selected target language; names the language in the system prompt.
    private let target: TargetLanguage

    private let client: any LLMChatClient

    private let modeState: CompatibleModeState

    /// Fires once when this engine first discovers that the provider+model
    /// needs the reasoning-free shape. The owner persists it for later
    /// engines; nil means this engine is only a probe.
    private let onCompatibleModeLearned: (@Sendable () async -> Void)?

    init(
        target: TargetLanguage,
        client: any LLMChatClient,
        compatibleMode: Bool = false,
        transientBadResponse: Bool = true,
        onCompatibleModeLearned: (@Sendable () async -> Void)? = nil
    ) {
        self.target = target
        self.client = client
        self.transientBadResponse = transientBadResponse
        self.onCompatibleModeLearned = onCompatibleModeLearned
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
            let reply: LLMReply
            do {
                reply = try await client.complete(
                    LLMTranslationPrompt.messages(for: text, target: target),
                    compatibleMode: modeState.isCompatible,
                    onRetry: onRetry
                )
            } catch let error as TranslationEngineError {
                // Terminal configuration rejection: the field-free retry was
                // rejected, or no retry was possible (already compatible /
                // nothing to strip), so later sentences send only the
                // field-free shape.
                if case .invalidConfiguration = error {
                    modeState.rememberTerminalConfigurationFailure()
                }
                throw error
            }
            if modeState.record(reply.usedCompatibleMode) {
                await onCompatibleModeLearned?()
            }
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

    /// Records a successful reasoning-free retry. Returns true only for the
    /// first transition, so the owner persists the discovery once.
    func record(_ usedCompatibleMode: Bool) -> Bool {
        guard usedCompatibleMode else { return false }
        let newlyLearned = compatibleMode.withLock { stored -> Bool in
            guard !stored else { return false }
            stored = true
            return true
        }
        observedCompatibleMode.withLock { observed in observed = true }
        return newlyLearned
    }

    /// The field-free retry was rejected as configuration: stop sending the
    /// fast-mode fields for the rest of this engine's life, without claiming
    /// a successful downgrade.
    func rememberTerminalConfigurationFailure() {
        compatibleMode.withLock { stored in stored = true }
    }
}
