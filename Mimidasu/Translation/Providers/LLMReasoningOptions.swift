import Foundation

/// Reasoning-related request fields for one LLM call. Providers accept
/// different dialects; only the non-nil fields are encoded.
struct LLMRequestOptions: Sendable, Equatable {
    var reasoningEffort: String?
    var thinking: Thinking?
    var outputConfig: OutputConfig?
    var maxTokens: Int?

    struct Thinking: Sendable, Equatable {
        var type: String
        var keep: String?
    }

    struct OutputConfig: Sendable, Equatable {
        var effort: String
    }

    static let anthropicDefaultMaxTokens = 4096

    /// True when the request asks the provider to change its reasoning
    /// behavior. Such a request may be rejected by a model that does not
    /// recognize the dialect, which is what the compatible fallback handles.
    var hasReasoningFields: Bool {
        reasoningEffort != nil || thinking != nil || outputConfig != nil
    }

    /// The compatible fallback: the same request with every reasoning field
    /// removed. `maxTokens` is provider-required (Anthropic) and is kept.
    var withoutReasoningFields: LLMRequestOptions {
        LLMRequestOptions(
            reasoningEffort: nil,
            thinking: nil,
            outputConfig: nil,
            maxTokens: maxTokens
        )
    }
}

/// Compiles the fast-mode posture for a provider and model. Pure and static:
/// known IDs and curated families get a verified field, unknown models get
/// none. Never guesses a provider's dialect for an unknown model.
enum LLMReasoningPolicy {
    static func options(
        for provider: TranslationProvider, model: String
    ) -> LLMRequestOptions {
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return switch provider {
        case .apple, .google, .deepl, .openrouter:
            LLMRequestOptions()
        case .openai:
            openAIOptions(model)
        case .anthropic:
            anthropicOptions(model)
        case .moonshot:
            moonshotOptions(model)
        case .zai:
            zaiOptions(model)
        case .deepseek:
            deepSeekOptions(model)
        case .xai:
            xAIOptions(model)
        }
    }

    // MARK: - OpenAI

    private static func openAIOptions(_ model: String) -> LLMRequestOptions {
        guard !model.isEmpty else { return LLMRequestOptions() }
        // Non-reasoning legacy models and fine-tunes reject reasoning fields.
        if model.hasPrefix("gpt-4") || model.hasPrefix("ft:") || model.hasPrefix("ft-") {
            return LLMRequestOptions()
        }
        let tokens = model.split { character in
            character == "-" || character == "." || character == "/" || character == ":"
        }
        if tokens.contains(where: { token in
            token == "luna" || token == "nano" || token == "mini"
        }) {
            return LLMRequestOptions(reasoningEffort: "none")
        }
        let effortFamilies = ["gpt-6", "gpt-5.6", "gpt-5.5", "gpt-5.4"]
        if effortFamilies.contains(where: { family in hasFamilyPrefix(model, family) }) {
            return LLMRequestOptions(reasoningEffort: "low")
        }
        return LLMRequestOptions()
    }

    // MARK: - Anthropic

    private static func anthropicOptions(_ model: String) -> LLMRequestOptions {
        let maxTokens = LLMRequestOptions.anthropicDefaultMaxTokens
        guard let rule = anthropicRule(for: model) else {
            return LLMRequestOptions(maxTokens: maxTokens)
        }
        return LLMRequestOptions(
            reasoningEffort: nil,
            thinking: rule.thinking,
            outputConfig: rule.effort.map { effort in
                LLMRequestOptions.OutputConfig(effort: effort)
            },
            maxTokens: maxTokens
        )
    }

    private struct AnthropicRule {
        let thinking: LLMRequestOptions.Thinking?
        let effort: String?
    }

    private static let anthropicRules: [(prefix: String, rule: AnthropicRule)] = [
        ("claude-haiku-5-5", AnthropicRule(thinking: .init(type: "disabled"), effort: "low")),
        ("claude-sonnet-5-5", AnthropicRule(thinking: .init(type: "between_tools"), effort: "low")),
        ("claude-sonnet-5", AnthropicRule(thinking: .init(type: "disabled"), effort: "low")),
        ("claude-sonnet-4-6", AnthropicRule(thinking: .init(type: "disabled"), effort: "low")),
        ("claude-sonnet-4-5", AnthropicRule(thinking: .init(type: "disabled"), effort: nil)),
        ("claude-opus-5-5", AnthropicRule(thinking: nil, effort: "low")),
        ("claude-opus-5", AnthropicRule(thinking: .init(type: "disabled"), effort: "low")),
        ("claude-opus-4-5", AnthropicRule(thinking: .init(type: "disabled"), effort: "low")),
        ("claude-opus-4-6", AnthropicRule(thinking: .init(type: "disabled"), effort: "low")),
        ("claude-opus-4-7", AnthropicRule(thinking: .init(type: "disabled"), effort: "low")),
        ("claude-opus-4-8", AnthropicRule(thinking: .init(type: "disabled"), effort: "low")),
        ("claude-haiku-4-5", AnthropicRule(thinking: .init(type: "disabled"), effort: nil)),
        ("claude-fable-5-1", AnthropicRule(thinking: nil, effort: "low")),
        ("claude-fable-5", AnthropicRule(thinking: nil, effort: "low")),
        ("claude-mythos-5-1", AnthropicRule(thinking: nil, effort: "low")),
        ("claude-mythos-5", AnthropicRule(thinking: nil, effort: "low")),
        ("claude-mythos-preview", AnthropicRule(thinking: nil, effort: "low"))
    ]

    /// Exact IDs first, then the longest family prefix. A dated ID such as
    /// `claude-sonnet-5-5-20260101` matches its family prefix; the longest
    /// match keeps `claude-sonnet-5-5` ahead of `claude-sonnet-5`.
    private static func anthropicRule(for model: String) -> AnthropicRule? {
        if let exact = anthropicRules.first(where: { entry in entry.prefix == model }) {
            return exact.rule
        }
        return anthropicRules
            .filter { entry in hasFamilyPrefix(model, entry.prefix) }
            .max { left, right in left.prefix.count < right.prefix.count }?
            .rule
    }

    // MARK: - Moonshot

    private static func moonshotOptions(_ model: String) -> LLMRequestOptions {
        let rules: [(prefix: String, options: LLMRequestOptions)] = [
            ("kimi-k2.7-code-highspeed", LLMRequestOptions()),
            ("kimi-k2.7-code", LLMRequestOptions()),
            ("kimi-k3", LLMRequestOptions(reasoningEffort: "low")),
            ("kimi-k2.6", LLMRequestOptions(thinking: .init(type: "disabled"))),
            ("kimi-k2.5", LLMRequestOptions(thinking: .init(type: "disabled")))
        ]
        return longestRule(for: model, rules: rules)
    }

    // MARK: - Z.ai

    private static func zaiOptions(_ model: String) -> LLMRequestOptions {
        guard let version = glmVersion(in: model) else { return LLMRequestOptions() }
        if version.major > 5 || (version.major == 5 && version.minor >= 3) {
            return LLMRequestOptions(
                reasoningEffort: "low",
                thinking: .init(type: "enabled")
            )
        }
        return LLMRequestOptions(thinking: .init(type: "disabled"))
    }

    /// Parses the leading `glm-<major>.<minor>` version. Anything else is
    /// unknown — including an unparseable version.
    private static func glmVersion(in model: String) -> (major: Int, minor: Int)? {
        guard model.hasPrefix("glm-") else { return nil }
        let version = model.dropFirst("glm-".count)
        let parts = version.split(separator: ".", maxSplits: 1)
        guard parts.count == 2,
              let major = Int(parts[0]),
              let minorDigits = parts[1].prefix(while: { character in character.isNumber }).nilIfEmpty,
              let minor = Int(minorDigits)
        else { return nil }
        return (major, minor)
    }

    // MARK: - DeepSeek

    private static func deepSeekOptions(_ model: String) -> LLMRequestOptions {
        let rules: [(prefix: String, options: LLMRequestOptions)] = [
            ("deepseek-flash", LLMRequestOptions(thinking: .init(type: "disabled"))),
            ("deepseek-v4-pro", LLMRequestOptions(thinking: .init(type: "disabled")))
        ]
        return longestRule(for: model, rules: rules)
    }

    // MARK: - xAI

    private static func xAIOptions(_ model: String) -> LLMRequestOptions {
        let rules: [(prefix: String, options: LLMRequestOptions)] = [
            ("grok-4.7", LLMRequestOptions(reasoningEffort: "low")),
            ("grok-4.6", LLMRequestOptions(reasoningEffort: "low")),
            ("grok-4.5", LLMRequestOptions(reasoningEffort: "low"))
        ]
        return longestRule(for: model, rules: rules)
    }

    // MARK: - Matching

    /// Prefix match at a token boundary, so `gpt-6` does not match `gpt-60`
    /// and `kimi-k3` does not match `kimi-k30`.
    private static func hasFamilyPrefix(_ model: String, _ family: String) -> Bool {
        guard model.hasPrefix(family) else { return false }
        guard model.count > family.count else { return true }
        let boundary = model[model.index(model.startIndex, offsetBy: family.count)]
        return boundary == "-" || boundary == "." || boundary == "/" || boundary == ":"
    }

    private static func longestRule(
        for model: String, rules: [(prefix: String, options: LLMRequestOptions)]
    ) -> LLMRequestOptions {
        if let exact = rules.first(where: { entry in entry.prefix == model }) {
            return exact.options
        }
        return rules
            .filter { entry in hasFamilyPrefix(model, entry.prefix) }
            .max { left, right in left.prefix.count < right.prefix.count }?
            .options ?? LLMRequestOptions()
    }
}

private extension Substring {
    var nilIfEmpty: Substring? {
        isEmpty ? nil : self
    }
}
