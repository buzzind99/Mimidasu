import Foundation
@testable import Mimidasu
import Testing

/// Tests the reasoning-field policy for chat-model providers: each
/// provider's default posture, the per-family model overrides, and the
/// compatible fallback that strips reasoning fields from a request.
@Suite("LLMReasoningOptions")
struct LLMReasoningOptionsTests {

    private struct AnthropicExpectation {
        let model: String
        let thinking: String?
        let effort: String?
    }

    private static let anthropicExpectations: [AnthropicExpectation] = [
        AnthropicExpectation(model: "claude-haiku-5-5", thinking: "disabled", effort: "low"),
        AnthropicExpectation(model: "claude-sonnet-5-5", thinking: "between_tools", effort: "low"),
        AnthropicExpectation(model: "claude-haiku-4-5", thinking: "disabled", effort: nil),
        AnthropicExpectation(model: "claude-sonnet-4-5", thinking: "disabled", effort: nil),
        AnthropicExpectation(model: "claude-opus-5-5", thinking: nil, effort: "low"),
        AnthropicExpectation(model: "claude-fable-5", thinking: nil, effort: "low"),
        AnthropicExpectation(model: "claude-fable-5-1", thinking: nil, effort: "low"),
        AnthropicExpectation(model: "claude-mythos-5", thinking: nil, effort: "low"),
        AnthropicExpectation(model: "claude-mythos-5-1", thinking: nil, effort: "low")
    ]

    private func options(
        for provider: TranslationProvider, model: String
    ) -> LLMRequestOptions {
        LLMReasoningPolicy.options(for: provider, model: model)
    }

    // MARK: - Provider defaults

    @Test("each provider's default model compiles to its expected posture")
    func providerDefaults() {
        #expect(
            options(for: .openai, model: "gpt-6-luna")
                == LLMRequestOptions(reasoningEffort: "none")
        )
        #expect(
            options(for: .anthropic, model: "claude-haiku-5-5")
                == LLMRequestOptions(
                    thinking: .init(type: "disabled"),
                    outputConfig: .init(effort: "low"),
                    maxTokens: 4096
                )
        )
        #expect(
            options(for: .moonshot, model: "kimi-k2.6")
                == LLMRequestOptions(thinking: .init(type: "disabled"))
        )
        #expect(
            options(for: .zai, model: "glm-5.3-flash")
                == LLMRequestOptions(
                    reasoningEffort: "low",
                    thinking: .init(type: "enabled")
                )
        )
        #expect(
            options(for: .deepseek, model: "deepseek-flash")
                == LLMRequestOptions(thinking: .init(type: "disabled"))
        )
        #expect(
            options(for: .xai, model: "grok-4.7")
                == LLMRequestOptions(reasoningEffort: "low")
        )
        #expect(
            options(for: .openrouter, model: "tencent/hy-mt2-30b-a3b")
                == LLMRequestOptions()
        )
    }

    // MARK: - OpenAI

    @Test("OpenAI luna, nano, and mini disable reasoning")
    func openAISmallModelsDisableReasoning() {
        for model in ["gpt-6-luna", "gpt-6.1-nano", "gpt-6-mini"] {
            #expect(
                options(for: .openai, model: model).reasoningEffort == "none",
                "unexpected effort for \(model)"
            )
        }
    }

    @Test("OpenAI sol and astra use low effort")
    func openAISolAndAstraUseLowEffort() {
        for model in ["gpt-6-sol", "gpt-6.1-sol", "gpt-6-astra"] {
            #expect(
                options(for: .openai, model: model).reasoningEffort == "low",
                "unexpected effort for \(model)"
            )
        }
    }

    @Test("OpenAI legacy and unknown models get no reasoning fields")
    func openAILegacyAndUnknownGetNoFields() {
        for model in ["gpt-4o", "gpt-4.1", "mystery-model"] {
            #expect(
                options(for: .openai, model: model) == LLMRequestOptions(),
                "unexpected fields for \(model)"
            )
        }
    }

    // MARK: - Anthropic

    @Test("Anthropic families compile to their thinking and effort posture")
    func anthropicFamilies() {
        for expectation in Self.anthropicExpectations {
            let requestOptions = options(for: .anthropic, model: expectation.model)
            #expect(
                requestOptions.thinking?.type == expectation.thinking,
                "unexpected thinking for \(expectation.model)"
            )
            #expect(
                requestOptions.outputConfig?.effort == expectation.effort,
                "unexpected effort for \(expectation.model)"
            )
            #expect(
                requestOptions.reasoningEffort == nil,
                "\(expectation.model) should not use the effort field"
            )
            #expect(
                requestOptions.maxTokens == LLMRequestOptions.anthropicDefaultMaxTokens,
                "unexpected token budget for \(expectation.model)"
            )
        }
    }

    @Test("Anthropic dated IDs resolve by the longest family prefix")
    func anthropicLongestPrefixWins() {
        let sonnet = options(for: .anthropic, model: "claude-sonnet-5-5-20260101")
        #expect(sonnet.thinking?.type == "between_tools")
        #expect(sonnet.outputConfig?.effort == "low")
        #expect(sonnet.maxTokens == 4096)

        let opus = options(for: .anthropic, model: "claude-opus-5-5-20260101")
        #expect(opus.thinking == nil)
        #expect(opus.outputConfig?.effort == "low")
        #expect(opus.maxTokens == 4096)
    }

    @Test("unknown Anthropic models keep the required token budget")
    func anthropicUnknownKeepsTokenBudget() {
        let requestOptions = options(for: .anthropic, model: "claude-unknown-9")
        #expect(requestOptions.thinking == nil)
        #expect(requestOptions.outputConfig == nil)
        #expect(requestOptions.reasoningEffort == nil)
        #expect(requestOptions.maxTokens == 4096)
    }

    // MARK: - Moonshot

    @Test("Moonshot model families")
    func moonshotFamilies() {
        #expect(
            options(for: .moonshot, model: "kimi-k2.6")
                == LLMRequestOptions(thinking: .init(type: "disabled"))
        )
        #expect(
            options(for: .moonshot, model: "kimi-k3")
                == LLMRequestOptions(reasoningEffort: "low")
        )
        #expect(
            options(for: .moonshot, model: "kimi-k2.7-code") == LLMRequestOptions()
        )
        #expect(
            options(for: .moonshot, model: "kimi-k2.7-code-highspeed")
                == LLMRequestOptions()
        )
        #expect(
            options(for: .moonshot, model: "kimi-unknown") == LLMRequestOptions()
        )
    }

    // MARK: - Z.ai

    @Test("Z.ai GLM versions")
    func zaiFamilies() {
        #expect(
            options(for: .zai, model: "glm-5.3-flash")
                == LLMRequestOptions(
                    reasoningEffort: "low",
                    thinking: .init(type: "enabled")
                )
        )
        #expect(
            options(for: .zai, model: "glm-5.2")
                == LLMRequestOptions(thinking: .init(type: "disabled"))
        )
        #expect(
            options(for: .zai, model: "glm-4.6")
                == LLMRequestOptions(thinking: .init(type: "disabled"))
        )
        #expect(options(for: .zai, model: "glm-unknown") == LLMRequestOptions())
        #expect(options(for: .zai, model: "not-glm") == LLMRequestOptions())
    }

    // MARK: - DeepSeek

    @Test("DeepSeek reasoning-capable models disable thinking explicitly")
    func deepSeekFamilies() {
        for model in ["deepseek-flash", "deepseek-v4-pro"] {
            #expect(
                options(for: .deepseek, model: model)
                    == LLMRequestOptions(thinking: .init(type: "disabled")),
                "unexpected fields for \(model)"
            )
        }
        #expect(
            options(for: .deepseek, model: "deepseek-chat") == LLMRequestOptions()
        )
    }

    // MARK: - xAI

    @Test("xAI Grok families use low effort")
    func xAIFamilies() {
        for model in ["grok-4.7", "grok-4.6", "grok-4.5"] {
            #expect(
                options(for: .xai, model: model)
                    == LLMRequestOptions(reasoningEffort: "low"),
                "unexpected fields for \(model)"
            )
        }
        #expect(options(for: .xai, model: "grok-3") == LLMRequestOptions())
    }

    // MARK: - OpenRouter

    @Test("OpenRouter never sends reasoning fields")
    func openRouterNeverSendsReasoningFields() {
        #expect(
            options(for: .openrouter, model: "tencent/hy-mt2-30b-a3b")
                == LLMRequestOptions()
        )
        #expect(
            options(for: .openrouter, model: "openai/gpt-6-luna")
                == LLMRequestOptions()
        )
    }

    // MARK: - Compatible fallback

    @Test("the compatible fallback clears reasoning fields and keeps max tokens")
    func compatibleFallbackClearsReasoningFields() {
        let requestOptions = options(for: .anthropic, model: "claude-haiku-5-5")
        #expect(requestOptions.hasReasoningFields)

        let fallback = requestOptions.withoutReasoningFields
        #expect(!fallback.hasReasoningFields)
        #expect(fallback.reasoningEffort == nil)
        #expect(fallback.thinking == nil)
        #expect(fallback.outputConfig == nil)
        #expect(fallback.maxTokens == 4096)
        #expect(fallback == LLMRequestOptions(maxTokens: 4096))
    }

    @Test("the compatible fallback keeps a nil token budget nil")
    func compatibleFallbackKeepsNilTokenBudget() {
        let fallback = options(for: .openai, model: "gpt-6-sol")
            .withoutReasoningFields
        #expect(fallback == LLMRequestOptions())
    }
}
