import Foundation
@testable import Mimidasu
import Testing

/// Tests the one provider catalog: the single row per provider, the facts
/// derived from it, and — for chat-model providers — the endpoint, default
/// model, wire protocol, and fast-mode dialect each one pins.
@Suite("ProviderCatalog")
struct ProviderCatalogTests {

    private struct ExpectedEndpoint {
        let provider: TranslationProvider
        let endpoint: String
        let defaultModel: String
    }

    private struct ExpectedPresentation {
        let provider: TranslationProvider
        let kind: TranslationEngineKind?
        let icon: String
        let shortName: String
    }

    private static let expectedEndpoints: [ExpectedEndpoint] = [
        ExpectedEndpoint(
            provider: .openrouter,
            endpoint: "https://openrouter.ai/api/v1/chat/completions",
            defaultModel: "tencent/hy-mt2-30b-a3b"
        ),
        ExpectedEndpoint(
            provider: .openai,
            endpoint: "https://api.openai.com/v1/chat/completions",
            defaultModel: "gpt-6-luna"
        ),
        ExpectedEndpoint(
            provider: .anthropic,
            endpoint: "https://api.anthropic.com/v1/messages",
            defaultModel: "claude-haiku-5-5"
        ),
        ExpectedEndpoint(
            provider: .moonshot,
            endpoint: "https://api.moonshot.ai/v1/chat/completions",
            defaultModel: "kimi-k2.6"
        ),
        ExpectedEndpoint(
            provider: .zai,
            endpoint: "https://api.z.ai/api/paas/v4/chat/completions",
            defaultModel: "glm-5.3-flash"
        ),
        ExpectedEndpoint(
            provider: .deepseek,
            endpoint: "https://api.deepseek.com/chat/completions",
            defaultModel: "deepseek-flash"
        ),
        ExpectedEndpoint(
            provider: .xai,
            endpoint: "https://api.x.ai/v1/chat/completions",
            defaultModel: "grok-4.7"
        )
    ]

    // MARK: - Catalog membership

    @Test("non-LLM providers have no catalog entry")
    func nonLLMProvidersHaveNoEntry() {
        for provider in [TranslationProvider.apple, .google, .deepl] {
            #expect(ProviderCatalog.spec(for: provider).llm == nil)
        }
    }

    @Test("every LLM provider has a catalog entry")
    func everyLLMProviderHasEntry() {
        let llmProviders = TranslationProvider.allCases.filter(\.isLLM)
        let expected = Self.expectedEndpoints.map { entry in entry.provider }
        #expect(Set(llmProviders.map(\.rawValue)) == Set(expected.map(\.rawValue)))
    }

    // MARK: - Endpoint and default model

    @Test("each provider resolves to its endpoint and default model")
    func endpointAndDefaultModel() throws {
        for entry in Self.expectedEndpoints {
            let spec = try #require(ProviderCatalog.spec(for: entry.provider).llm)
            #expect(
                spec.endpoint.absoluteString == entry.endpoint,
                "unexpected endpoint for \(entry.provider.rawValue)"
            )
            #expect(
                spec.defaultModel == entry.defaultModel,
                "unexpected default model for \(entry.provider.rawValue)"
            )
            #expect(entry.provider.defaultModel == entry.defaultModel)
        }
    }

    // MARK: - Wire protocol

    @Test("every provider uses chat completions except Anthropic")
    func apiPerProvider() throws {
        for provider in TranslationProvider.allCases where provider.isLLM {
            let spec = try #require(ProviderCatalog.spec(for: provider).llm)
            if provider == .anthropic {
                #expect(
                    spec.api == .anthropicMessages,
                    "Anthropic should use the native Messages API"
                )
            } else {
                #expect(
                    spec.api == .chatCompletions,
                    "\(provider.rawValue) should use chat completions"
                )
            }
        }
    }

    // MARK: - Default-model agreement

    @Test("only chat-model providers carry a default model")
    func defaultModelsAgreeWithCatalog() {
        for provider in TranslationProvider.allCases {
            if provider.isLLM {
                let catalogModel = ProviderCatalog.spec(for: provider).llm?.defaultModel ?? ""
                #expect(
                    !catalogModel.isEmpty,
                    "\(provider.rawValue) needs a default model"
                )
                #expect(
                    !provider.defaultModel.isEmpty,
                    "\(provider.rawValue) needs a default model"
                )
            } else {
                #expect(ProviderCatalog.spec(for: provider).llm == nil)
                #expect(
                    provider.defaultModel.isEmpty,
                    "\(provider.rawValue) must not have a default model"
                )
            }
        }
    }

    // MARK: - One identity

    @Test("provider presentation facts stay pinned")
    func catalogPresentationFacts() {
        let expected: [ExpectedPresentation] = [
            ExpectedPresentation(provider: .apple, kind: nil, icon: "apple.logo", shortName: "Apple"),
            ExpectedPresentation(provider: .google, kind: .google, icon: "g.circle.fill", shortName: "Google"),
            ExpectedPresentation(provider: .deepl, kind: .deepl, icon: "d.circle.fill", shortName: "DeepL"),
            ExpectedPresentation(
                provider: .openrouter, kind: .openrouter, icon: "o.circle.fill", shortName: "OpenRouter"
            ),
            ExpectedPresentation(provider: .openai, kind: .openai, icon: "o.circle.fill", shortName: "OpenAI"),
            ExpectedPresentation(
                provider: .anthropic, kind: .anthropic, icon: "a.circle.fill", shortName: "Anthropic"
            ),
            ExpectedPresentation(
                provider: .moonshot, kind: .moonshot, icon: "m.circle.fill", shortName: "Moonshot"
            ),
            ExpectedPresentation(provider: .zai, kind: .zai, icon: "z.circle.fill", shortName: "Z.ai"),
            ExpectedPresentation(
                provider: .deepseek, kind: .deepseek, icon: "d.circle.fill", shortName: "DeepSeek"
            ),
            ExpectedPresentation(provider: .xai, kind: .xai, icon: "x.circle.fill", shortName: "xAI")
        ]

        #expect(expected.count == TranslationProvider.allCases.count)
        for entry in expected {
            #expect(entry.provider.spec.settingsIcon == entry.icon)
            #expect(entry.provider.settingsIcon == entry.icon)
            #expect(entry.provider.spec.shortName == entry.shortName)
            #expect(entry.provider.shortName == entry.shortName)
            #expect(entry.provider.spec.engineKind == entry.kind)
            #expect(TranslationEngineKind(provider: entry.provider) == entry.kind)
            #expect(
                entry.provider.isExternal == (entry.provider != .apple),
                "only Apple is on-device for \(entry.provider.rawValue)"
            )
            #expect(entry.provider.spec.isExternal == entry.provider.isExternal)
        }
    }

    @Test("external providers share one raw value across provider, selection, and kind")
    func externalIdentitiesShareOneRawValue() {
        for provider in TranslationProvider.allCases {
            #expect(
                TranslationProvider(rawValue: provider.rawValue) == provider,
                "\(provider.rawValue) must round-trip through its raw value"
            )

            if provider.isExternal {
                let selection = RetranslateEngine(provider: provider)
                let kind = TranslationEngineKind(provider: provider)

                #expect(
                    selection?.rawValue == provider.rawValue,
                    "the selection for \(provider.rawValue) must share its raw value"
                )
                #expect(
                    selection?.provider == provider,
                    "the selection for \(provider.rawValue) must name the provider"
                )
                #expect(
                    kind?.rawValue == provider.rawValue,
                    "the kind for \(provider.rawValue) must share its raw value"
                )
                #expect(
                    kind?.provider == provider,
                    "the kind for \(provider.rawValue) must name the provider"
                )
                #expect(
                    RetranslateEngine(rawValue: provider.rawValue) == selection,
                    "the selection's raw-value init must agree with its provider init"
                )
                #expect(
                    TranslationEngineKind(rawValue: provider.rawValue) == kind,
                    "the kind's raw-value init must agree with its provider init"
                )
            } else {
                #expect(RetranslateEngine(provider: provider) == nil)
                #expect(TranslationEngineKind(provider: provider) == nil)
            }
        }
    }

    @Test("every engine kind names its provider or is an Apple engine identity")
    func everyEngineKindNamesItsProvider() {
        let kinds = RetranslateEngine.allCases.compactMap(\.kind)

        #expect(kinds.count == 11, "the selection names 11 engine kinds")
        #expect(
            RetranslateEngine.allCases
                .filter { selection in selection != .session }
                .allSatisfy { selection in selection.kind != nil },
            "every non-session selection must name an engine kind"
        )
        #expect(
            Set(kinds.map(\.rawValue)).count == kinds.count,
            "two selections must not name the same engine kind"
        )

        for kind in kinds {
            switch kind {
            case .appleFast, .appleHighFidelity:
                #expect(
                    kind.provider == nil,
                    "\(kind.rawValue) is an Apple identity, not a provider selection"
                )
            default:
                let roundTripped = kind.provider.flatMap { provider in
                    TranslationEngineKind(provider: provider)
                }
                #expect(
                    roundTripped == kind,
                    "\(kind.rawValue) must round-trip through its provider"
                )
            }
        }
    }

    @Test("every external engine kind's tier matches its provider row")
    func engineKindTierMatchesProviderRow() {
        for kind in RetranslateEngine.allCases.compactMap(\.kind) {
            guard let provider = kind.provider else { continue }
            #expect(
                kind.tier == provider.tier(),
                "unexpected tier for \(kind.rawValue)"
            )
        }
    }

    // MARK: - Fast-mode dialect

    @Test("each chat-model provider declares its fast-mode dialect")
    func chatModelProvidersDeclareTheirDialect() {
        let expected: [(provider: TranslationProvider, dialect: LLMReasoningDialect)] = [
            (.openrouter, .none),
            (.openai, .openAI),
            (.anthropic, .anthropic),
            (.moonshot, .moonshot),
            (.zai, .zai),
            (.deepseek, .deepSeek),
            (.xai, .xAI)
        ]

        for entry in expected {
            #expect(
                ProviderCatalog.spec(for: entry.provider).llm?.reasoning == entry.dialect,
                "unexpected fast-mode dialect for \(entry.provider.rawValue)"
            )
        }

        for provider in [TranslationProvider.apple, .google, .deepl] {
            #expect(ProviderCatalog.spec(for: provider).llm == nil)
            #expect(ProviderCatalog.spec(for: provider).llm?.reasoning == nil)
        }
    }

    @Test("only OpenRouter retries client errors")
    func clientErrorPosture() {
        for provider in TranslationProvider.allCases where provider.isLLM {
            #expect(
                ProviderCatalog.spec(for: provider).llm?
                    .treatsClientErrorsAsConfiguration == (provider != .openrouter),
                "unexpected client-error posture for \(provider.rawValue)"
            )
        }

        for provider in [TranslationProvider.apple, .google, .deepl] {
            #expect(ProviderCatalog.spec(for: provider).llm == nil)
        }
    }

    @Test("the factory returns nil for Apple")
    func factoryReturnsNilForApple() {
        let engine = TranslationEngineFactory.make(
            provider: .apple,
            key: "",
            model: "",
            target: .english,
            transport: nil
        )

        #expect(engine == nil)
    }
}
