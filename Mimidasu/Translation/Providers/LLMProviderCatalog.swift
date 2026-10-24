import Foundation

/// The fixed facts for a provider that translates through a chat model:
/// endpoint, wire protocol, and default model. UI copy lives on
/// `TranslationProvider`; the fast-mode policy lives on `LLMReasoningPolicy`.
struct LLMProviderSpec: Sendable {
    enum API: Sendable, Equatable {
        case chatCompletions
        case anthropicMessages
    }

    let endpoint: URL
    let api: API
    let defaultModel: String
}

/// Single source of truth for LLM endpoints and default models. Google,
/// DeepL, and Apple have no entry.
enum LLMProviderCatalog {
    static func spec(for provider: TranslationProvider) -> LLMProviderSpec? {
        switch provider {
        case .apple, .google, .deepl:
            nil
        case .openrouter:
            LLMProviderSpec(
                endpoint: URL(string: "https://openrouter.ai/api/v1/chat/completions")!,
                api: .chatCompletions,
                defaultModel: "tencent/hy-mt2-30b-a3b"
            )
        case .openai:
            LLMProviderSpec(
                endpoint: URL(string: "https://api.openai.com/v1/chat/completions")!,
                api: .chatCompletions,
                defaultModel: "gpt-6-luna"
            )
        case .anthropic:
            LLMProviderSpec(
                endpoint: URL(string: "https://api.anthropic.com/v1/messages")!,
                api: .anthropicMessages,
                defaultModel: "claude-haiku-5-5"
            )
        case .moonshot:
            LLMProviderSpec(
                endpoint: URL(string: "https://api.moonshot.ai/v1/chat/completions")!,
                api: .chatCompletions,
                defaultModel: "kimi-k2.6"
            )
        case .zai:
            LLMProviderSpec(
                endpoint: URL(string: "https://api.z.ai/api/paas/v4/chat/completions")!,
                api: .chatCompletions,
                defaultModel: "glm-5.3-flash"
            )
        case .deepseek:
            LLMProviderSpec(
                endpoint: URL(string: "https://api.deepseek.com/chat/completions")!,
                api: .chatCompletions,
                defaultModel: "deepseek-flash"
            )
        case .xai:
            LLMProviderSpec(
                endpoint: URL(string: "https://api.x.ai/v1/chat/completions")!,
                api: .chatCompletions,
                defaultModel: "grok-4.7"
            )
        }
    }
}
