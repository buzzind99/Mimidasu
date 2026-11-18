import Foundation

/// The fixed facts for a provider that translates through a chat model:
/// endpoint, wire protocol, default model, reasoning dialect, and whether a
/// client error means the request shape needs the compatible fallback.
struct LLMProviderSpec: Sendable, Equatable {
    enum API: Sendable, Equatable {
        case chatCompletions
        case anthropicMessages
    }

    let endpoint: URL
    let api: API
    let defaultModel: String
    let reasoning: LLMReasoningDialect
    /// Whether a client-side rejection counts as a configuration error that
    /// must not spend the transient budget. Only the chat-completions client
    /// consults it; the Messages client always applies the compatible
    /// fallback for reasoning fields.
    let treatsClientErrorsAsConfiguration: Bool
    /// Extra request headers the provider's gateway expects, merged over the
    /// auth header. Empty for providers that need none.
    var extraHeaders: [String: String] = [:]
}

/// The reasoning request-field family a chat-model provider accepts.
/// `LLMReasoningPolicy` compiles the fields for one model within a family.
enum LLMReasoningDialect: Sendable, Equatable {
    case none
    case openAI
    case anthropic
    case moonshot
    case zai
    case deepSeek
    case xAI
    case opencodeGateway
}

/// One provider's fixed identity: how its tier resolves, how requests reach
/// it, and the settings-row copy. Canonical names stay on `TranslationTier`.
struct ProviderSpec: Sendable, Equatable {
    /// How the provider's concrete tier is resolved from the runtime facts
    /// the app knows.
    enum Tier: Sendable, Equatable {
        /// Apple's tier follows the OS strategy probe.
        case appleProbed
        /// DeepL's tier follows the subscription behind the stored key.
        case deepLSubscription
        /// Every other provider sits at one fixed tier.
        case fixed(TranslationTier)

        func resolve(
            appleHighFidelity: Bool, deepLTier: TranslationTier.DeepLTier
        ) -> TranslationTier {
            switch self {
            case .appleProbed:
                appleHighFidelity ? .appleHighFidelity : .appleOnDevice
            case .deepLSubscription:
                .deepL(deepLTier)
            case let .fixed(tier):
                tier
            }
        }
    }

    /// The fixed-contract machine translation API family behind a route.
    enum MachineTranslationFamily: Sendable, Equatable {
        case googleTranslate
        case deepL
    }

    /// How the provider translates: on-device, a fixed-contract machine
    /// translation API, or a chat model.
    enum Route: Sendable, Equatable {
        case onDevice
        case machineTranslation(MachineTranslationFamily)
        case chatModel(LLMProviderSpec)
    }

    let tier: Tier
    let route: Route
    /// The engine identity a selection for this provider resolves to. Nil for
    /// Apple, whose concrete engine is decided by the OS strategy probe.
    let engineKind: TranslationEngineKind?
    let settingsIcon: String
    let shortName: String

    /// The chat-model facts; nil unless the route is `.chatModel`.
    var llm: LLMProviderSpec? {
        guard case let .chatModel(spec) = route else { return nil }
        return spec
    }

    /// True when requests leave the machine.
    var isExternal: Bool {
        route != .onDevice
    }

    /// True when the provider translates through a chat model.
    var isLLM: Bool {
        llm != nil
    }

    /// Supporting detail line under the provider name. Verified external
    /// providers append a "Configured" marker.
    func settingsDetail(configured: Bool) -> String {
        switch route {
        case .onDevice:
            "On-device"
        case .machineTranslation:
            configured ? "External · API key · Configured" : "External · API key"
        case .chatModel:
            configured
                ? "External · API key + model · Configured"
                : "External · API key + model"
        }
    }
}

/// The single provider table: every fixed fact about a provider is one row.
/// The switches are exhaustive, so a new provider case cannot ship without a
/// row, and every row is built once.
enum ProviderCatalog {
    static func spec(for provider: TranslationProvider) -> ProviderSpec {
        switch provider {
        case .apple: appleRow
        case .google: googleRow
        case .deepl: deepLRow
        case .openrouter, .openai, .anthropic, .moonshot, .zai, .deepseek, .xai, .opencodeGo,
             .opencodeConsole:
            chatModelSpec(for: provider)
        }
    }

    private static func chatModelSpec(for provider: TranslationProvider) -> ProviderSpec {
        switch provider {
        case .openrouter: openRouterRow
        case .openai: openAIRow
        case .anthropic: anthropicRow
        case .moonshot: moonshotRow
        case .zai: zaiRow
        case .deepseek: deepSeekRow
        case .xai: xAIRow
        case .opencodeGo: opencodeGoRow
        case .opencodeConsole: opencodeConsoleRow
        case .apple, .google, .deepl:
            preconditionFailure("\(provider.rawValue) has no chat-model row")
        }
    }

    // MARK: - On-device and fixed-contract rows

    private static let appleRow = ProviderSpec(
        tier: .appleProbed,
        route: .onDevice,
        engineKind: nil,
        settingsIcon: "apple.logo",
        shortName: "Apple"
    )

    private static let googleRow = ProviderSpec(
        tier: .fixed(.google),
        route: .machineTranslation(.googleTranslate),
        engineKind: .google,
        settingsIcon: "g.circle.fill",
        shortName: "Google"
    )

    private static let deepLRow = ProviderSpec(
        tier: .deepLSubscription,
        route: .machineTranslation(.deepL),
        engineKind: .deepl,
        settingsIcon: "d.circle.fill",
        shortName: "DeepL"
    )

    // MARK: - Chat-model rows

    private static let openRouterRow = chatModelRow(
        tier: .openRouter,
        llm: LLMProviderSpec(
            endpoint: URL(string: "https://openrouter.ai/api/v1/chat/completions")!,
            api: .chatCompletions,
            defaultModel: "tencent/hy-mt2-30b-a3b",
            reasoning: .none,
            treatsClientErrorsAsConfiguration: false
        ),
        engineKind: .openrouter,
        settingsIcon: "o.circle.fill",
        shortName: "OpenRouter"
    )

    private static let openAIRow = chatModelRow(
        tier: .openAI,
        llm: LLMProviderSpec(
            endpoint: URL(string: "https://api.openai.com/v1/chat/completions")!,
            api: .chatCompletions,
            defaultModel: "gpt-6-luna",
            reasoning: .openAI,
            treatsClientErrorsAsConfiguration: true
        ),
        engineKind: .openai,
        settingsIcon: "o.circle.fill",
        shortName: "OpenAI"
    )

    private static let anthropicRow = chatModelRow(
        tier: .anthropic,
        llm: LLMProviderSpec(
            endpoint: URL(string: "https://api.anthropic.com/v1/messages")!,
            api: .anthropicMessages,
            defaultModel: "claude-haiku-5-5",
            reasoning: .anthropic,
            treatsClientErrorsAsConfiguration: true
        ),
        engineKind: .anthropic,
        settingsIcon: "a.circle.fill",
        shortName: "Anthropic"
    )

    private static let moonshotRow = chatModelRow(
        tier: .moonshot,
        llm: LLMProviderSpec(
            endpoint: URL(string: "https://api.moonshot.ai/v1/chat/completions")!,
            api: .chatCompletions,
            defaultModel: "kimi-k2.6",
            reasoning: .moonshot,
            treatsClientErrorsAsConfiguration: true
        ),
        engineKind: .moonshot,
        settingsIcon: "m.circle.fill",
        shortName: "Moonshot"
    )

    private static let zaiRow = chatModelRow(
        tier: .zai,
        llm: LLMProviderSpec(
            endpoint: URL(string: "https://api.z.ai/api/paas/v4/chat/completions")!,
            api: .chatCompletions,
            defaultModel: "glm-5.3-flash",
            reasoning: .zai,
            treatsClientErrorsAsConfiguration: true
        ),
        engineKind: .zai,
        settingsIcon: "z.circle.fill",
        shortName: "Z.ai"
    )

    private static let deepSeekRow = chatModelRow(
        tier: .deepSeek,
        llm: LLMProviderSpec(
            endpoint: URL(string: "https://api.deepseek.com/chat/completions")!,
            api: .chatCompletions,
            defaultModel: "deepseek-flash",
            reasoning: .deepSeek,
            treatsClientErrorsAsConfiguration: true
        ),
        engineKind: .deepseek,
        settingsIcon: "d.circle.fill",
        shortName: "DeepSeek"
    )

    private static let xAIRow = chatModelRow(
        tier: .xAI,
        llm: LLMProviderSpec(
            endpoint: URL(string: "https://api.x.ai/v1/chat/completions")!,
            api: .chatCompletions,
            defaultModel: "grok-4.7",
            reasoning: .xAI,
            treatsClientErrorsAsConfiguration: true
        ),
        engineKind: .xai,
        settingsIcon: "x.circle.fill",
        shortName: "xAI"
    )

    /// OpenCode's subscription gateway. Chat completions is available for
    /// every Go text model. Go asks every client to send a stable session id
    /// so it can optimize routing and prompt caching, so every Go request
    /// carries one id per app run (see `GatewaySession`). The key is an
    /// OpenCode Console API key, stored under this row's own Keychain account.
    private static let opencodeGoRow = chatModelRow(
        tier: .opencodeGo,
        llm: LLMProviderSpec(
            endpoint: URL(string: "https://opencode.ai/inference/go/openai/v1/chat/completions")!,
            api: .chatCompletions,
            defaultModel: "deepseek-v4.1-flash",
            reasoning: .opencodeGateway,
            treatsClientErrorsAsConfiguration: true,
            extraHeaders: [GatewaySession.header: GatewaySession.id]
        ),
        engineKind: .opencodeGo,
        settingsIcon: "chevron.left.forwardslash.chevron.right",
        shortName: "OpenCode Go"
    )

    /// OpenCode's pay-as-you-go inference gateway. The Console API key is
    /// stored under this row's own Keychain account, separate from Go's. The
    /// gateway routes on the key alone, so no session header is sent. The
    /// default is a paid model because free-tier models are refused outside
    /// OpenCode.
    private static let opencodeConsoleRow = chatModelRow(
        tier: .opencodeConsole,
        llm: LLMProviderSpec(
            endpoint: URL(string: "https://opencode.ai/inference/openai/v1/chat/completions")!,
            api: .chatCompletions,
            defaultModel: "deepseek-v4.1-flash",
            reasoning: .opencodeGateway,
            treatsClientErrorsAsConfiguration: true
        ),
        engineKind: .opencodeConsole,
        settingsIcon: "c.circle.fill",
        shortName: "OpenCode Console"
    )

    /// The Go gateway's per-run session id, sent on every Go request.
    /// Translations share no conversation context, so one id per app run is
    /// enough.
    private enum GatewaySession {
        static let header = "x-opencode-session"
        static let id = "ses_\(UUID().uuidString)"
    }

    private static func chatModelRow(
        tier: TranslationTier,
        llm: LLMProviderSpec,
        engineKind: TranslationEngineKind,
        settingsIcon: String,
        shortName: String
    ) -> ProviderSpec {
        ProviderSpec(
            tier: .fixed(tier),
            route: .chatModel(llm),
            engineKind: engineKind,
            settingsIcon: settingsIcon,
            shortName: shortName
        )
    }
}
