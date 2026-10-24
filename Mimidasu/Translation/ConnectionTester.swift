import Foundation

/// Settings "Test" button actions, per provider. Every external provider runs
/// a minimal one-sentence translation through the same factory path the live
/// engine uses (cheap, exercises the real request shape). Probes run with
/// zero transient retries so a failed test settles in a single round-trip.
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
        // The factory is total for external providers: every one has a
        // catalog spec, and Apple is the only nil case above.
        let engine = TranslationEngineFactory.make(
            provider: provider,
            key: key,
            model: model,
            target: target,
            transport: transport,
            ladder: TransientRetryLadder(retries: 0, retriesBadResponse: false)
        )!

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
