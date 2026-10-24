import Foundation

/// The fixed facts for a provider that translates through a chat model:
/// endpoint, wire protocol, default model, and auth header style. UI copy and
/// the reasoning policy stay on `TranslationProvider`.
struct LLMProviderSpec: Sendable {
    enum API: Sendable {
        case chatCompletions
        case anthropicMessages
    }

    enum Auth: Sendable {
        case bearer
        case anthropic
    }

    let endpoint: URL
    let api: API
    let defaultModel: String
    let auth: Auth
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
                defaultModel: "tencent/hy-mt2-30b-a3b",
                auth: .bearer
            )
        case .openai:
            LLMProviderSpec(
                endpoint: URL(string: "https://api.openai.com/v1/chat/completions")!,
                api: .chatCompletions,
                defaultModel: "gpt-6-luna",
                auth: .bearer
            )
        case .anthropic:
            LLMProviderSpec(
                endpoint: URL(string: "https://api.anthropic.com/v1/messages")!,
                api: .anthropicMessages,
                defaultModel: "claude-haiku-5-5",
                auth: .anthropic
            )
        case .moonshot:
            LLMProviderSpec(
                endpoint: URL(string: "https://api.moonshot.ai/v1/chat/completions")!,
                api: .chatCompletions,
                defaultModel: "kimi-k2.6",
                auth: .bearer
            )
        case .zai:
            LLMProviderSpec(
                endpoint: URL(string: "https://api.z.ai/api/paas/v4/chat/completions")!,
                api: .chatCompletions,
                defaultModel: "glm-5.3-flash",
                auth: .bearer
            )
        case .deepseek:
            LLMProviderSpec(
                endpoint: URL(string: "https://api.deepseek.com/chat/completions")!,
                api: .chatCompletions,
                defaultModel: "deepseek-flash",
                auth: .bearer
            )
        case .xai:
            LLMProviderSpec(
                endpoint: URL(string: "https://api.x.ai/v1/chat/completions")!,
                api: .chatCompletions,
                defaultModel: "grok-4.7",
                auth: .bearer
            )
        }
    }
}
