import Foundation

/// The single engine-construction path. The live coordinator, the re-translate
/// lane, and the connection tester all build through here. Construction
/// switches on the provider's catalog route, so a new provider needs only a
/// catalog row; a new engine is needed only for a new transport family.
enum TranslationEngineFactory {
    /// - Parameters:
    ///   - model: the user's override; empty resolves to the catalog default.
    ///   - compatibleMode: seeds the engine's fast-mode downgrade memory for
    ///     the provider+effective model.
    ///   - onCompatibleModeLearned: called once when an LLM engine first
    ///     discovers the reasoning-free shape is required; the owner persists
    ///     it for future engines.
    /// - Returns: nil for the on-device route (Apple is served by the
    ///   `.translationTask` host).
    static func make(
        provider: TranslationProvider,
        key: String,
        model: String,
        target: TargetLanguage,
        transport: HTTPTranslationTransport?,
        ladder: TransientRetryLadder? = nil,
        compatibleMode: Bool = false,
        onCompatibleModeLearned: (@Sendable () async -> Void)? = nil
    ) -> (any TranslationEngine)? {
        switch provider.spec.route {
        case .onDevice:
            return nil
        case .machineTranslation(.googleTranslate):
            return GoogleTranslateEngine(
                apiKey: key,
                target: target,
                transport: transport,
                ladder: ladder ?? TransientRetryLadder()
            )
        case .machineTranslation(.deepL):
            return DeepLEngine(
                apiKey: key,
                target: target,
                transport: transport,
                ladder: ladder ?? TransientRetryLadder()
            )
        case let .chatModel(spec):
            let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedModel = trimmedModel.isEmpty ? spec.defaultModel : trimmedModel
            let options = LLMReasoningPolicy.options(for: provider, model: resolvedModel)
            let effectiveLadder = ladder ?? TransientRetryLadder(retriesBadResponse: true)
            let client: any LLMChatClient = switch spec.api {
            case .chatCompletions:
                ChatCompletionsClient(
                    config: ChatCompletionsClient.Config(
                        endpoint: spec.endpoint,
                        headers: ["Authorization": "Bearer \(key)"],
                        model: resolvedModel,
                        options: options,
                        treatClientErrorsAsConfiguration: spec.treatsClientErrorsAsConfiguration
                    ),
                    transport: transport,
                    ladder: effectiveLadder
                )
            case .anthropicMessages:
                AnthropicMessagesClient(
                    config: AnthropicMessagesClient.Config(
                        endpoint: spec.endpoint,
                        apiKey: key,
                        model: resolvedModel,
                        options: options
                    ),
                    transport: transport,
                    ladder: effectiveLadder
                )
            }
            return LLMTranslationEngine(
                target: target,
                client: client,
                compatibleMode: compatibleMode,
                transientBadResponse: effectiveLadder.retriesBadResponse,
                onCompatibleModeLearned: onCompatibleModeLearned
            )
        }
    }
}
