import Foundation

/// Settings "Test" button actions, per provider. Google/DeepL run a minimal
/// one-sentence translation (cheap, exercises the real request path);
/// OpenRouter hits `GET /api/v1/key` — validates the key without spending
/// tokens. Probes run with zero transient retries so a failed test settles
/// in a single round-trip. Outcomes land in `TranslationSettings` and render
/// inline.
enum TranslationConnectionTester {
    /// - Parameters:
    ///   - target: the selected translation target, threaded into the
    ///     translate probes (Google/DeepL request bodies); OpenRouter's key
    ///     probe is target-independent.
    /// - Throws: A short-status `TranslationEngineError` from the engine
    ///   taxonomy (never key material or raw response bodies).
    static func test(
        provider: TranslationProvider,
        key: String,
        target: TargetLanguage = .english,
        transport: HTTPTranslationTransport? = nil
    ) async throws(TranslationEngineError) {
        switch provider {
        case .apple:
            return
        case .google:
            try await translateProbe(
                GoogleTranslateEngine(
                    apiKey: key,
                    target: target,
                    transport: transport,
                    ladder: TransientRetryLadder(retries: 0)
                )
            )
        case .deepl:
            try await translateProbe(
                DeepLEngine(
                    apiKey: key,
                    target: target,
                    transport: transport,
                    ladder: TransientRetryLadder(retries: 0)
                )
            )
        case .openrouter:
            try await keyProbe(key, transport: transport)
        }
    }

    private static func translateProbe(
        _ engine: any TranslationEngine
    ) async throws(TranslationEngineError) {
        let translations: [String]
        do {
            translations = try await engine.translate(["こんにちは"])
        } catch {
            throw TransientRetryLadder.engineError(of: error)
        }
        guard translations.allSatisfy({ translation in !translation.isEmpty }) else {
            throw TranslationEngineError.badResponse("Provider returned an empty translation")
        }
    }

    /// OpenRouter key validation: `GET /api/v1/key` requires a valid bearer
    /// key and costs no tokens.
    private static func keyProbe(
        _ key: String,
        transport: HTTPTranslationTransport?
    ) async throws(TranslationEngineError) {
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/key")!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")

        let transport = transport ?? HTTPTranslationTransport(timeout: 15)
        do {
            _ = try await transport.send(request, classify: ChatCompletionsClient.classify)
        } catch {
            throw TransientRetryLadder.engineError(of: error)
        }
    }
}
