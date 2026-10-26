import Foundation
@testable import Mimidasu
import Testing

/// Tests `TranslationConnectionTester` against scripted transports. Every
/// probe captures the request it issues, so both the request shape and the
/// zero-retry ladder wiring are asserted, not just the outcome.
@Suite("TranslationConnectionTester")
struct TranslationConnectionTesterTests {

    // MARK: - Helpers

    private static let chatReply = Data(#"{"choices":[{"message":{"content":"hello"}}]}"#.utf8)
    private static let openRouterEndpoint = URL(string: "https://openrouter.ai/api/v1/chat/completions")!
    private static let openAIEndpoint = URL(string: "https://api.openai.com/v1/chat/completions")!
    private static let anthropicEndpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    private static func httpResponse(_ url: URL, _ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    private static func jsonObject(_ data: Data?) throws -> [String: Any] {
        let data = try #require(data)
        let object = try JSONSerialization.jsonObject(with: data)
        return try #require(object as? [String: Any])
    }

    /// Records every request the probe issues; responses come from a scripted
    /// per-call handler, so retries (or the lack of them) are observable.
    private final class Script: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var requests: [URLRequest] = []
        private(set) var bodies: [Data] = []

        let handler: @Sendable (_ index: Int) throws -> (Data, HTTPURLResponse)

        init(handler: @escaping @Sendable (_ index: Int) throws -> (Data, HTTPURLResponse)) {
            self.handler = handler
        }

        func record(_ request: URLRequest) {
            lock.withLock {
                requests.append(request)
                bodies.append(request.httpBody ?? Data())
            }
        }

        var requestCount: Int {
            lock.withLock { requests.count }
        }
    }

    private func makeTransport(_ script: Script) -> HTTPTranslationTransport {
        HTTPTranslationTransport(timeout: 1) { request in
            let index = script.requestCount
            script.record(request)
            return try script.handler(index)
        }
    }

    // MARK: - Probes

    @Test("Apple needs no probe")
    func appleSucceeds() async throws {
        let compatibleMode = try await TranslationConnectionTester.test(provider: .apple, key: "")

        #expect(compatibleMode == false)
    }

    @Test(
        "Google probes with a one-sentence translate carrying the selected target",
        arguments: [(TargetLanguage.english, "en"), (TargetLanguage(code: "zh-Hans"), "zh-CN")]
    )
    func googleProbe(target: TargetLanguage, wireTarget: String) async throws {
        let script = Script(handler: { _ in
            (
                Data(#"{"data":{"translations":[{"translatedText":"hello"}]}}"#.utf8),
                Self.httpResponse(GoogleTranslateEngine.endpoint, 200)
            )
        })
        let transport = makeTransport(script)

        let compatibleMode = try await TranslationConnectionTester.test(
            provider: .google, key: "k", target: target, transport: transport
        )

        #expect(compatibleMode == false)
        let request = try #require(script.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url == GoogleTranslateEngine.endpoint)
        #expect(request.value(forHTTPHeaderField: "X-goog-api-key") == "k")
        let decoded = try JSONDecoder().decode(GoogleProbeBody.self, from: #require(script.bodies.first))
        #expect(decoded.q == ["こんにちは"])
        #expect(decoded.source == "ja")
        #expect(decoded.target == wireTarget)
    }

    @Test(
        "DeepL probes with a one-sentence translate on the Pro endpoint carrying the selected target",
        arguments: [(TargetLanguage.english, "EN"), (TargetLanguage(code: "th"), "TH")]
    )
    func deeplProbe(target: TargetLanguage, wireTarget: String) async throws {
        let script = Script(handler: { _ in
            (
                Data(#"{"translations":[{"detected_source_language":"JA","text":"hello"}]}"#.utf8),
                Self.httpResponse(DeepLEngine.proEndpoint, 200)
            )
        })
        let transport = makeTransport(script)

        let compatibleMode = try await TranslationConnectionTester.test(
            provider: .deepl, key: "k", target: target, transport: transport
        )

        #expect(compatibleMode == false)
        let request = try #require(script.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url == DeepLEngine.proEndpoint)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "DeepL-Auth-Key k")
        let decoded = try JSONDecoder().decode(DeepLProbeBody.self, from: #require(script.bodies.first))
        #expect(decoded.text == ["こんにちは"])
        #expect(decoded.sourceLang == "JA")
        #expect(decoded.targetLang == wireTarget)
    }

    @Test("OpenRouter probes a chat-completions translation with its catalog default model")
    func openRouterTranslationProbe() async throws {
        let script = Script(handler: { _ in
            (Self.chatReply, Self.httpResponse(Self.openRouterEndpoint, 200))
        })
        let transport = makeTransport(script)

        let compatibleMode = try await TranslationConnectionTester.test(
            provider: .openrouter, key: "or-key", transport: transport
        )

        #expect(compatibleMode == false)
        let request = try #require(script.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url == Self.openRouterEndpoint)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer or-key")
        let body = try JSONDecoder().decode(ChatProbeBody.self, from: #require(script.bodies.first))
        #expect(body.model == "tencent/hy-mt2-30b-a3b")
        #expect(script.requestCount == 1)
    }

    @Test("OpenAI probes with a bearer key and the explicit model")
    func openAIProbe() async throws {
        let script = Script(handler: { _ in
            (Self.chatReply, Self.httpResponse(Self.openAIEndpoint, 200))
        })
        let transport = makeTransport(script)

        let compatibleMode = try await TranslationConnectionTester.test(
            provider: .openai, key: "oa-key", model: "gpt-6-luna-2026", transport: transport
        )

        #expect(compatibleMode == false)
        let request = try #require(script.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url == Self.openAIEndpoint)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer oa-key")
        let body = try JSONDecoder().decode(ChatProbeBody.self, from: #require(script.bodies.first))
        #expect(body.model == "gpt-6-luna-2026")
        #expect(script.requestCount == 1)
    }

    @Test("Anthropic probes the Messages endpoint with its native headers and the explicit model")
    func anthropicProbe() async throws {
        let reply = Data(#"{"content":[{"type":"text","text":"hello"}]}"#.utf8)
        let script = Script(handler: { _ in
            (reply, Self.httpResponse(Self.anthropicEndpoint, 200))
        })
        let transport = makeTransport(script)

        let compatibleMode = try await TranslationConnectionTester.test(
            provider: .anthropic, key: "anthropic-key",
            model: "claude-sonnet-5-5", transport: transport
        )

        #expect(compatibleMode == false)
        let request = try #require(script.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url == Self.anthropicEndpoint)
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "anthropic-key")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        let body = try JSONDecoder().decode(AnthropicProbeBody.self, from: #require(script.bodies.first))
        #expect(body.model == "claude-sonnet-5-5")
        #expect(script.requestCount == 1)
    }

    // MARK: - Failures

    @Test(
        "a failed probe surfaces its engine error in exactly one request",
        arguments: [
            (TranslationProvider.google, "", GoogleTranslateEngine.endpoint, 403,
             TranslationEngineError.invalidKey),
            (TranslationProvider.deepl, "", DeepLEngine.proEndpoint, 403,
             TranslationEngineError.invalidKey),
            (TranslationProvider.deepl, "", DeepLEngine.proEndpoint, 429,
             TranslationEngineError.rateLimited),
            (TranslationProvider.openai, "gpt-6-luna", Self.openAIEndpoint, 500,
             TranslationEngineError.serverError(500))
        ]
    )
    func failedProbeSurfacesItsEngineError(
        provider: TranslationProvider,
        model: String,
        endpoint: URL,
        status: Int,
        expected: TranslationEngineError
    ) async {
        let script = Script(handler: { _ in (Data(), Self.httpResponse(endpoint, status)) })
        let transport = makeTransport(script)

        let thrown = await #expect(throws: TranslationEngineError.self) {
            _ = try await TranslationConnectionTester.test(
                provider: provider, key: "k", model: model, transport: transport
            )
        }

        #expect(thrown == expected)
        #expect(script.requestCount == 1, "the probe ladder has zero retries")
    }

    @Test("a DeepL probe with an empty translation fails as badResponse")
    func deeplEmptyTranslation() async {
        let script = Script(handler: { _ in
            (Data(#"{"translations":[{"text":""}]}"#.utf8), Self.httpResponse(DeepLEngine.proEndpoint, 200))
        })
        let transport = makeTransport(script)

        let thrown = await #expect(throws: TranslationEngineError.self) {
            _ = try await TranslationConnectionTester.test(provider: .deepl, key: "k", transport: transport)
        }

        #expect(thrown == .badResponse("Provider returned an empty translation"))
    }

    @Test("an empty chat-completions translation fails as badResponse")
    func chatEmptyTranslation() async {
        let emptyReply = Data(#"{"choices":[{"message":{"content":""}}]}"#.utf8)
        let script = Script(handler: { _ in
            (emptyReply, Self.httpResponse(Self.openRouterEndpoint, 200))
        })
        let transport = makeTransport(script)

        let thrown = await #expect(throws: TranslationEngineError.self) {
            _ = try await TranslationConnectionTester.test(
                provider: .openrouter, key: "k", transport: transport
            )
        }

        #expect(thrown == .badResponse("Model returned an empty translation"))
        #expect(script.requestCount == 1)
    }

    // MARK: - Compatible mode

    @Test("an OpenAI compatible-mode retry counts as a successful probe")
    func compatibleModeProbeSucceeds() async throws {
        let script = Script(handler: { index in
            if index == 0 {
                return (Data(), Self.httpResponse(Self.openAIEndpoint, 400))
            }
            return (Self.chatReply, Self.httpResponse(Self.openAIEndpoint, 200))
        })
        let transport = makeTransport(script)

        let compatibleMode = try await TranslationConnectionTester.test(
            provider: .openai, key: "k", model: "gpt-6-luna", transport: transport
        )

        #expect(compatibleMode)
        #expect(script.requestCount == 2)
        let first = try JSONDecoder().decode(ChatProbeBody.self, from: #require(script.bodies.first))
        #expect(first.reasoningEffort == "none")
        let retry = try Self.jsonObject(script.bodies.last)
        #expect(retry["reasoning_effort"] == nil)
    }

    @Test("a model rejection that survives the compatible retry throws the fixed copy")
    func compatibleModeProbeFailsWithFixedCopy() async throws {
        let providerBody = Data(#"{"error":{"message":"raw-provider-detail"}}"#.utf8)
        let script = Script(handler: { _ in
            (providerBody, Self.httpResponse(Self.openAIEndpoint, 400))
        })
        let transport = makeTransport(script)

        let thrown = await #expect(throws: TranslationEngineError.self) {
            _ = try await TranslationConnectionTester.test(
                provider: .openai, key: "k", model: "gpt-6-luna", transport: transport
            )
        }

        #expect(
            thrown == .invalidConfiguration(
                "The provider rejected the model or its fast-mode settings."
            )
        )
        let message = try #require(thrown?.statusMessage)
        #expect(!message.contains("raw-provider-detail"), "provider bodies never reach the copy")
        #expect(script.requestCount == 2)
    }
}

private struct GoogleProbeBody: Decodable {
    let q: [String]
    let source: String
    let target: String
}

private struct DeepLProbeBody: Decodable {
    let text: [String]
    let sourceLang: String
    let targetLang: String

    enum CodingKeys: String, CodingKey {
        case text
        case sourceLang = "source_lang"
        case targetLang = "target_lang"
    }
}

private struct ChatProbeBody: Decodable {
    let model: String
    let reasoningEffort: String?

    enum CodingKeys: String, CodingKey {
        case model
        case reasoningEffort = "reasoning_effort"
    }
}

private struct AnthropicProbeBody: Decodable {
    let model: String
}
