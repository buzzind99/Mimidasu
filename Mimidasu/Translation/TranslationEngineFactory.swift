import Foundation

/// The single engine-construction path. The live coordinator, the re-translate
/// lane, and the connection tester all build through here, so a new provider
/// only needs a catalog entry and a policy case.
enum TranslationEngineFactory {
    /// - Parameters:
    ///   - model: the user's override; empty resolves to the catalog default.
    ///   - compatibleMode: seeds the engine's fast-mode downgrade memory for
    ///     the provider+effective model.
    /// - Returns: nil for Apple (served by the `.translationTask` host) and
    ///   for a provider with no catalog entry.
    static func make(
        provider: TranslationProvider,
        key: String,
        model: String,
        target: TargetLanguage,
        transport: HTTPTranslationTransport?,
        ladder: TransientRetryLadder? = nil,
        compatibleMode: Bool = false
    ) -> (any TranslationEngine)? {
        switch provider {
        case .apple:
            return nil
        case .google:
            return GoogleTranslateEngine(
                apiKey: key,
                target: target,
                transport: transport,
                ladder: ladder ?? TransientRetryLadder()
            )
        case .deepl:
            return DeepLEngine(
                apiKey: key,
                target: target,
                transport: transport,
                ladder: ladder ?? TransientRetryLadder()
            )
        case .openrouter, .openai, .anthropic, .moonshot, .zai, .deepseek, .xai:
            guard let spec = LLMProviderCatalog.spec(for: provider) else { return nil }
            let effectiveModel = model.isEmpty ? spec.defaultModel : model
            let options = LLMReasoningPolicy.options(
                for: provider, model: effectiveModel
            )
            let client: any LLMChatClient = switch spec.api {
            case .chatCompletions:
                ChatCompletionsClient(
                    config: ChatCompletionsClient.Config(
                        endpoint: spec.endpoint,
                        headers: ["Authorization": "Bearer \(key)"],
                        model: effectiveModel,
                        options: options,
                        treatClientErrorsAsConfiguration: provider != .openrouter
                    ),
                    transport: transport,
                    ladder: ladder ?? TransientRetryLadder(retriesBadResponse: true)
                )
            case .anthropicMessages:
                AnthropicMessagesClient(
                    config: AnthropicMessagesClient.Config(
                        endpoint: spec.endpoint,
                        apiKey: key,
                        model: effectiveModel,
                        options: options
                    ),
                    transport: transport,
                    ladder: ladder ?? TransientRetryLadder(retriesBadResponse: true)
                )
            }
            return LLMTranslationEngine(
                target: target,
                client: client,
                compatibleMode: compatibleMode
            )
        }
    }
}
