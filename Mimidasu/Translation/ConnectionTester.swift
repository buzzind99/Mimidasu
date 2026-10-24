import Foundation

/// Settings "Test" button actions, per provider. Every external provider runs
/// a minimal one-sentence translation through the same factory path the live
/// engine uses (cheap, exercises the real request shape). Probes run with
/// zero transient retries; an LLM probe may still issue the one-shot
/// compatible (reasoning-free) request when the fast shape is rejected.
/// Outcomes land in `TranslationSettings` and render inline.
enum TranslationConnectionTester {
    /// - Parameters:
    ///   - model: the draft override to probe; empty resolves to the
    ///     provider's catalog default inside `TranslationEngineFactory`.
    ///   - target: the selected translation target, threaded into the engine
    ///     (Google/DeepL wire codes, LLM prompt).
    /// - Returns: whether the probe had to fall back to compatible mode
    ///   (LLM providers only); a compatible-mode retry counts as success.
    ///   Apple returns false without issuing a request.
    /// - Throws: A short-status `TranslationEngineError` from the engine
    ///   taxonomy (never key material or raw response bodies).
    @discardableResult
    static func test(
        provider: TranslationProvider,
        key: String,
        model: String = "",
        target: TargetLanguage = .english,
        transport: HTTPTranslationTransport? = nil
    ) async throws(TranslationEngineError) -> Bool {
        guard provider.isExternal else { return false }
        // Apple is the only provider the factory serves nil for today, but a
        // future external without a catalog entry must fail the probe, not
        // crash Settings.
        guard let engine = TranslationEngineFactory.make(
            provider: provider,
            key: key,
            model: model,
            target: target,
            transport: transport,
            ladder: TransientRetryLadder(retries: 0, retriesBadResponse: false)
        ) else {
            throw TranslationEngineError.invalidConfiguration(
                "No translation engine is available for \(provider.displayName)."
            )
        }

        let translations: [String]
        do {
            translations = try await engine.translate(["こんにちは"])
        } catch {
            throw TransientRetryLadder.engineError(of: error)
        }
        guard translations.count == 1,
              let translation = translations.first,
              !translation.isEmpty
        else {
            throw TranslationEngineError.badResponse("Provider returned an empty translation")
        }
        return (engine as? LLMTranslationEngine)?.usedCompatibleMode ?? false
    }
}
