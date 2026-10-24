import Foundation
@testable import Mimidasu
import Testing

/// Tests the catalog facts for chat-model providers: which providers have an
/// entry, the endpoint and default model each one pins, and the auth scheme
/// its client uses.
@Suite("LLMProviderCatalog")
struct LLMProviderCatalogTests {

    private struct ExpectedEndpoint {
        let provider: TranslationProvider
        let endpoint: String
        let defaultModel: String
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
            #expect(LLMProviderCatalog.spec(for: provider) == nil)
        }
    }

    @Test("every LLM provider has a catalog entry")
    func everyLLMProviderHasEntry() {
        let llmProviders = TranslationProvider.allCases.filter(\.isLLM)
        let expected = Self.expectedEndpoints.map { entry in entry.provider }
        #expect(Set(llmProviders.map(\.rawValue)) == Set(expected.map(\.rawValue)))
        for provider in llmProviders {
            #expect(LLMProviderCatalog.spec(for: provider) != nil)
        }
    }

    // MARK: - Endpoint and default model

    @Test("each provider resolves to its endpoint and default model")
    func endpointAndDefaultModel() throws {
        for entry in Self.expectedEndpoints {
            let spec = try #require(LLMProviderCatalog.spec(for: entry.provider))
            #expect(
                spec.endpoint.absoluteString == entry.endpoint,
                "unexpected endpoint for \(entry.provider.rawValue)"
            )
            #expect(
                spec.defaultModel == entry.defaultModel,
                "unexpected default model for \(entry.provider.rawValue)"
            )
        }
    }

    @Test("DeepSeek defaults to the flash model")
    func deepSeekDefaultModel() {
        let spec = LLMProviderCatalog.spec(for: .deepseek)
        #expect(spec?.defaultModel == "deepseek-flash")
        #expect(spec?.defaultModel != "deepseek-v4.1-flash")
    }

    // MARK: - Auth scheme

    @Test("every provider uses bearer auth except Anthropic")
    func authSchemePerProvider() throws {
        for provider in TranslationProvider.allCases where provider.isLLM {
            let spec = try #require(LLMProviderCatalog.spec(for: provider))
            if provider == .anthropic {
                #expect(
                    isAnthropicAuth(spec.auth),
                    "Anthropic should use its native auth scheme"
                )
            } else {
                #expect(
                    isBearerAuth(spec.auth),
                    "\(provider.rawValue) should use bearer auth"
                )
            }
        }
    }

    // MARK: - Default-model agreement

    @Test("provider default models agree with the catalog")
    func defaultModelsAgreeWithCatalog() {
        for provider in TranslationProvider.allCases {
            let catalogModel = LLMProviderCatalog.spec(for: provider)?.defaultModel
            #expect(
                provider.defaultModel == (catalogModel ?? ""),
                "default model drift for \(provider.rawValue)"
            )
            if provider.isLLM {
                #expect(
                    !provider.defaultModel.isEmpty,
                    "\(provider.rawValue) needs a default model"
                )
            } else {
                #expect(
                    provider.defaultModel.isEmpty,
                    "\(provider.rawValue) must not have a default model"
                )
            }
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

    // MARK: - Helpers

    private func isBearerAuth(_ auth: LLMProviderSpec.Auth) -> Bool {
        if case .bearer = auth {
            return true
        }
        return false
    }

    private func isAnthropicAuth(_ auth: LLMProviderSpec.Auth) -> Bool {
        if case .anthropic = auth {
            return true
        }
        return false
    }
}
