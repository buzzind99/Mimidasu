import Foundation
@testable import Mimidasu
import Testing

/// Tests `LLMTranslationEngine` against a scripted chat-completions transport:
/// one request per sentence, request shape, target prompt wiring, lenient
/// reply parsing, error mapping, the transient retry ladder, and the fast-mode
/// downgrade memory. No network.
@Suite("LLMTranslationEngine")
struct LLMTranslationEngineTests {

    // MARK: - Helpers

    private static let apiKey = "openrouter-key-1234"
    private static let endpoint = URL(string: "https://openrouter.ai/api/v1/chat/completions")!

    /// Records every request the engine issues; responses come from a
    /// scripted per-request handler indexed by request order.
    private final class Script: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var requests: [URLRequest] = []
        private(set) var bodies: [Data] = []

        let handler: @Sendable (_ index: Int) throws -> (Data, HTTPURLResponse)

        init(handler: @escaping @Sendable (_ index: Int) throws -> (Data, HTTPURLResponse)) {
            self.handler = handler
        }

        func record(_ request: URLRequest, body: Data?) {
            lock.lock()
            defer { lock.unlock() }
            requests.append(request)
            bodies.append(body ?? Data())
        }

        var requestCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return requests.count
        }
    }

    /// Locked progress log for the `onRetry` hook.
    private final class ProgressLog: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var entries: [RetryProgress] = []

        func append(_ progress: RetryProgress) {
            lock.lock()
            defer { lock.unlock() }
            entries.append(progress)
        }
    }

    private struct FakeResponse: Encodable {
        let choices: [FakeChoice]
    }

    private struct FakeChoice: Encodable {
        let message: FakeMessage
    }

    private struct FakeMessage: Encodable {
        let content: String
    }

    private static func httpResponse(_ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: endpoint, statusCode: status, httpVersion: nil, headerFields: nil
        )!
    }

    private static func okContent(
        _ content: String
    ) -> @Sendable (_ index: Int) throws -> (Data, HTTPURLResponse) {
        { _ in
            let body = FakeResponse(
                choices: [FakeChoice(message: FakeMessage(content: content))]
            )
            return try (JSONEncoder().encode(body), httpResponse(200))
        }
    }

    private static func status(
        _ code: Int
    ) -> @Sendable (_ index: Int) throws -> (Data, HTTPURLResponse) {
        { _ in (Data(), httpResponse(code)) }
    }

    private static func decodedBody(_ data: Data?) throws -> RequestBody {
        let data = try #require(data)
        return try JSONDecoder().decode(RequestBody.self, from: data)
    }

    private func makeTransport(script: Script) -> HTTPTranslationTransport {
        HTTPTranslationTransport(timeout: 1) { request in
            let index = script.requestCount
            script.record(request, body: request.httpBody)
            return try script.handler(index)
        }
    }

    /// Builds the production chat-completions client for `provider`, pointed
    /// at the catalog endpoint with a scripted transport, then wraps it in
    /// the engine under test.
    private func makeEngine(
        script: Script,
        provider: TranslationProvider = .openrouter,
        model: String? = nil,
        target: TargetLanguage = .english,
        compatibleMode: Bool = false
    ) throws -> LLMTranslationEngine {
        let spec = try #require(LLMProviderCatalog.spec(for: provider))
        let effectiveModel = model ?? spec.defaultModel
        let client = ChatCompletionsClient(
            config: ChatCompletionsClient.Config(
                endpoint: spec.endpoint,
                headers: ["Authorization": "Bearer \(Self.apiKey)"],
                model: effectiveModel,
                options: LLMReasoningPolicy.options(
                    for: provider, model: effectiveModel
                ),
                treatClientErrorsAsConfiguration: provider != .openrouter
            ),
            transport: makeTransport(script: script),
            ladder: TransientRetryLadder(retriesBadResponse: true, sleep: { _ in })
        )
        return LLMTranslationEngine(
            target: target, client: client, compatibleMode: compatibleMode
        )
    }

    /// Builds OpenRouter's engine through the factory so the empty-model
    /// fallback and catalog facts come from the production path.
    private func makeFactoryEngine(
        script: Script,
        model: String
    ) throws -> any TranslationEngine {
        try #require(
            TranslationEngineFactory.make(
                provider: .openrouter,
                key: Self.apiKey,
                model: model,
                target: .english,
                transport: makeTransport(script: script),
                ladder: TransientRetryLadder(
                    retriesBadResponse: true, sleep: { _ in }
                )
            )
        )
    }

    // MARK: - Request shape

    @Test("sends one chat-completions POST per sentence with the bearer key and model verbatim")
    func requestShape() async throws {
        let script = Script(handler: Self.okContent("hello"))
        let engine = try makeEngine(script: script, model: "test/custom-model")

        _ = try await engine.translate(["こんにちは"])

        let request = try #require(script.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url == Self.endpoint)
        #expect(request.url == LLMProviderCatalog.spec(for: .openrouter)?.endpoint)
        #expect(
            request.value(forHTTPHeaderField: "Authorization")
                == "Bearer \(Self.apiKey)"
        )
        let body = try Self.decodedBody(script.bodies.first)
        #expect(body.model == "test/custom-model")
        #expect(
            body.messages == LLMTranslationPrompt.messages(for: "こんにちは")
        )
        #expect(script.requestCount == 1)
    }

    @Test("an empty model string falls back to the default model")
    func emptyModelFallsBackToDefault() async throws {
        let script = Script(handler: Self.okContent("hello"))
        let engine = try makeFactoryEngine(script: script, model: "")

        _ = try await engine.translate(["こんにちは"])

        let defaultModel = try #require(
            LLMProviderCatalog.spec(for: .openrouter)?.defaultModel
        )
        let body = try Self.decodedBody(script.bodies.first)
        #expect(body.model == defaultModel)
    }

    @Test("the system prompt names the selected target and keeps the ASR caveat")
    func promptNamesTargetLanguage() async throws {
        let script = Script(handler: Self.okContent("hola"))
        let target = TargetLanguage(code: "es")
        let engine = try makeEngine(
            script: script, model: "test/model", target: target
        )

        _ = try await engine.translate(["こんにちは"])

        let body = try Self.decodedBody(script.bodies.first)
        #expect(
            body.messages == LLMTranslationPrompt.messages(
                for: "こんにちは", target: target
            )
        )
        let systemPrompt = try #require(body.messages.first).content
        #expect(systemPrompt.contains("Spanish"))
        #expect(!systemPrompt.contains("English"))
        #expect(systemPrompt.contains("ASR"))
    }

    @Test("the prompt uses the full English name for Chinese variants")
    func promptUsesFullEnglishNameForChineseVariants() {
        let messages = LLMTranslationPrompt.messages(
            for: "こんにちは", target: TargetLanguage(code: "zh-Hans")
        )

        #expect(messages[0].content.contains("Simplified Chinese"))
        #expect(messages[1].content == "こんにちは")
    }

    @Test("multiple texts issue one request per sentence, order preserved")
    func multiTextIssuesOneRequestPerSentence() async throws {
        let script = Script(handler: { index in
            try Self.okContent("translation \(index)")(index)
        })
        let engine = try makeEngine(script: script)

        let translations = try await engine.translate(["一", "二", "三"])

        #expect(
            translations == ["translation 0", "translation 1", "translation 2"]
        )
        #expect(script.requestCount == 3)
        let userMessages = try script.bodies.map { body in
            try Self.decodedBody(body).messages.last?.content
        }
        #expect(userMessages == ["一", "二", "三"])
    }
}

// MARK: - Response parsing

extension LLMTranslationEngineTests {

    @Test("the reply is the translation")
    func happyPath() async throws {
        let script = Script(handler: Self.okContent("hello there"))
        let engine = try makeEngine(script: script)

        let translations = try await engine.translate(["こんにちは"])

        #expect(translations == ["hello there"])
    }

    @Test("code fences around the translation are stripped")
    func codeFencesStripped() throws {
        #expect(try LLMTranslationPrompt.parse("```json\nhello\n```") == "hello")
        #expect(try LLMTranslationPrompt.parse("```\nhello there\n```") == "hello there")
    }

    @Test("a fence with no newline still strips the bare markers")
    func fenceWithoutNewlineStripped() throws {
        #expect(try LLMTranslationPrompt.parse("```hello```") == "hello")
        #expect(try LLMTranslationPrompt.parse("```not json") == "not json")
    }

    @Test("one pair of wrapping quotes is stripped")
    func wrappingQuotesStripped() throws {
        #expect(try LLMTranslationPrompt.parse("\"hello\"") == "hello")
        #expect(try LLMTranslationPrompt.parse("\u{201C}hello\u{201D}") == "hello")
        #expect(try LLMTranslationPrompt.parse("\u{300C}hello\u{300D}") == "hello")
    }

    @Test("an unquoted reply is left untouched")
    func plainReplyUnchanged() throws {
        #expect(try LLMTranslationPrompt.parse("hello there") == "hello there")
    }

    @Test("a whitespace-only reply surfaces as badResponse")
    func emptyTranslationThrows() {
        #expect(
            throws: TranslationEngineError.badResponse(
                "Model returned an empty translation"
            )
        ) {
            try LLMTranslationPrompt.parse("   ")
        }
        #expect(
            throws: TranslationEngineError.badResponse(
                "Model returned an empty translation"
            )
        ) {
            try LLMTranslationPrompt.parse("")
        }
    }

    @Test("a 200 response with no choices is retried then surfaces as badResponse")
    func noChoicesThrows() async throws {
        let script = Script(handler: { _ in
            let body = FakeResponse(choices: [])
            return try (JSONEncoder().encode(body), Self.httpResponse(200))
        })
        let engine = try makeEngine(script: script)

        let thrown = await #expect(throws: TranslationEngineError.self) {
            try await engine.translate(["こんにちは"])
        }

        #expect(thrown == .badResponse("Response contained no choices"))
        #expect(script.requestCount == 3)
    }

    @Test("an unparseable 200 body is retried then surfaces as badResponse")
    func unparseableBodyThrows() async throws {
        let script = Script(handler: { _ in
            (Data("garbage".utf8), Self.httpResponse(200))
        })
        let engine = try makeEngine(script: script)

        let thrown = await #expect(throws: TranslationEngineError.self) {
            try await engine.translate(["こんにちは"])
        }

        #expect(thrown == .badResponse("Unparseable response body"))
        #expect(script.requestCount == 3)
    }

    @Test("malformed model output is retried as badResponse")
    func malformedOutputIsRetried() async throws {
        let script = Script(handler: Self.okContent("   "))
        let log = ProgressLog()
        var engine = try makeEngine(script: script)
        engine.onRetry = { progress in log.append(progress) }

        let thrown = await #expect(throws: TranslationEngineError.self) {
            try await engine.translate(["こんにちは"])
        }

        #expect(thrown == .badResponse("Model returned an empty translation"))
        #expect(script.requestCount == 3)
        #expect(log.entries.map(\.attemptsLeft) == [2, 1])
    }

    // MARK: - Retry behavior

    @Test("a transient failure is retried")
    func transientFailureIsRetried() async throws {
        let script = Script(handler: { index in
            if index == 0 {
                return try Self.status(429)(index)
            }
            return try Self.okContent("hello")(index)
        })
        let log = ProgressLog()
        var engine = try makeEngine(script: script)
        engine.onRetry = { progress in log.append(progress) }

        let translations = try await engine.translate(["こんにちは"])

        #expect(translations == ["hello"])
        #expect(script.requestCount == 2)
        #expect(log.entries.count == 1)
        #expect(log.entries[0].stage == .batchRetry)
        #expect(log.entries[0].attemptsLeft == 2)
    }

    @Test("a 5xx response is retried")
    func serverErrorIsRetried() async throws {
        let script = Script(handler: { index in
            if index == 0 {
                return try Self.status(503)(index)
            }
            return try Self.okContent("hello")(index)
        })
        let engine = try makeEngine(script: script)

        let translations = try await engine.translate(["こんにちは"])

        #expect(translations == ["hello"])
        #expect(script.requestCount == 2)
    }

    @Test("an invalid key fails immediately without retrying")
    func invalidKeyFailsImmediately() async throws {
        let script = Script(handler: Self.status(401))
        let engine = try makeEngine(script: script)

        let thrown = await #expect(throws: TranslationEngineError.self) {
            try await engine.translate(["こんにちは"])
        }

        #expect(thrown == .invalidKey)
        #expect(script.requestCount == 1)
    }

    // MARK: - Error mapping

    @Test("OpenRouter HTTP errors map into the engine taxonomy", arguments: [
        (401, TranslationEngineError.invalidKey),
        (402, TranslationEngineError.quotaExceeded),
        (429, TranslationEngineError.rateLimited),
        (400, TranslationEngineError.serverError(400)),
        (500, TranslationEngineError.serverError(500))
    ])
    func errorMapping(status: Int, expected: TranslationEngineError) async throws {
        let script = Script(handler: Self.status(status))
        let engine = try makeEngine(script: script)

        let thrown = await #expect(throws: TranslationEngineError.self) {
            try await engine.translate(["こんにちは"])
        }

        #expect(thrown == expected)
    }

    @Test("OpenRouter treats a 400 as a server error, not invalidConfiguration")
    func openRouter400IsServerError() async throws {
        let script = Script(handler: Self.status(400))
        let engine = try makeEngine(script: script)

        let thrown = await #expect(throws: TranslationEngineError.self) {
            try await engine.translate(["こんにちは"])
        }

        #expect(thrown == .serverError(400))
        // The server-error ladder spent both retries before giving up.
        #expect(script.requestCount == 3)
    }
}

// MARK: - Reasoning fields and compatible fallback

extension LLMTranslationEngineTests {

    @Test("an OpenRouter request body carries no reasoning fields")
    func openRouterBodyHasNoReasoningFields() async throws {
        let script = Script(handler: Self.okContent("hello"))
        let engine = try makeEngine(script: script)

        _ = try await engine.translate(["こんにちは"])

        let body = try Self.decodedBody(script.bodies.first)
        #expect(body.reasoningEffort == nil)
        #expect(body.thinking == nil)
        #expect(body.outputConfig == nil)
    }

    @Test("an unknown model sends no reasoning fields")
    func unknownModelSendsNoReasoningFields() async throws {
        let model = "unknown-model"
        let script = Script(handler: Self.okContent("hello"))
        let engine = try makeEngine(
            script: script, provider: .deepseek, model: model
        )

        _ = try await engine.translate(["こんにちは"])

        #expect(
            LLMReasoningPolicy.options(for: .deepseek, model: model)
                == LLMRequestOptions()
        )
        let body = try Self.decodedBody(script.bodies.first)
        #expect(body.reasoningEffort == nil)
        #expect(body.thinking == nil)
        #expect(body.outputConfig == nil)
        #expect(script.requestCount == 1)
    }

    // MARK: - Compatible fallback

    @Test("a rejected fast-mode field is retried without it and remembered")
    func fastModeDowngradeIsRemembered() async throws {
        let script = Script(handler: { index in
            if index == 0 {
                return try Self.status(400)(index)
            }
            return try Self.okContent("hello")(index)
        })
        let engine = try makeEngine(
            script: script, provider: .openai, model: "gpt-6-luna"
        )

        let first = try await engine.translate(["こんにちは"])

        #expect(first == ["hello"])
        #expect(engine.usedCompatibleMode)
        #expect(script.requestCount == 2)
        let firstBody = try Self.decodedBody(script.bodies.first)
        #expect(firstBody.reasoningEffort == "none")
        let retryBody = try Self.decodedBody(script.bodies.last)
        #expect(retryBody.reasoningEffort == nil)

        let second = try await engine.translate(["さようなら"])

        #expect(second == ["hello"])
        #expect(script.requestCount == 3)
        let laterBody = try Self.decodedBody(script.bodies.last)
        #expect(laterBody.reasoningEffort == nil)
    }

    @Test("a second configuration rejection surfaces the fixed copy after exactly two requests")
    func fastModeDowngradeFinalRejection() async throws {
        let script = Script(handler: Self.status(400))
        let engine = try makeEngine(
            script: script, provider: .openai, model: "gpt-6-luna"
        )

        let thrown = await #expect(throws: TranslationEngineError.self) {
            try await engine.translate(["こんにちは"])
        }

        #expect(
            thrown == .invalidConfiguration(
                "The provider rejected the model or its fast-mode settings."
            )
        )
        #expect(script.requestCount == 2)
        #expect(!engine.usedCompatibleMode)
    }

    @Test(
        "a 404 or 422 configuration rejection also retries without the fields",
        arguments: [404, 422]
    )
    func configurationRejectionDowngrades(status: Int) async throws {
        let script = Script(handler: { index in
            if index == 0 {
                return try Self.status(status)(index)
            }
            return try Self.okContent("hello")(index)
        })
        let engine = try makeEngine(
            script: script, provider: .openai, model: "gpt-6-luna"
        )

        let translations = try await engine.translate(["こんにちは"])

        #expect(translations == ["hello"])
        #expect(engine.usedCompatibleMode)
        #expect(script.requestCount == 2)
        let retryBody = try Self.decodedBody(script.bodies.last)
        #expect(retryBody.reasoningEffort == nil)
    }

    @Test("a rejection without reasoning fields fails immediately with no second attempt")
    func configurationRejectionWithoutReasoningFields() async throws {
        let script = Script(handler: Self.status(400))
        let engine = try makeEngine(
            script: script, provider: .deepseek, model: "unknown-model"
        )

        let thrown = await #expect(throws: TranslationEngineError.self) {
            try await engine.translate(["こんにちは"])
        }

        #expect(
            thrown == .invalidConfiguration(
                ChatCompletionsClient.rejectedConfigurationMessage
            )
        )
        #expect(script.requestCount == 1)
        #expect(!engine.usedCompatibleMode)
    }
}

// MARK: - Raw client paths

extension LLMTranslationEngineTests {
    @Test("thinking and output_config options are encoded when present")
    func encodesThinkingAndOutputConfig() async throws {
        let script = Script(handler: Self.okContent("hello"))
        let options = LLMRequestOptions(
            reasoningEffort: "low",
            thinking: LLMRequestOptions.Thinking(type: "enabled"),
            outputConfig: LLMRequestOptions.OutputConfig(effort: "low"),
            maxTokens: 512
        )
        let client = ChatCompletionsClient(
            config: ChatCompletionsClient.Config(
                endpoint: Self.endpoint,
                headers: ["Authorization": "Bearer \(Self.apiKey)"],
                model: "test/model",
                options: options
            ),
            transport: makeTransport(script: script),
            ladder: TransientRetryLadder(retriesBadResponse: true, sleep: { _ in })
        )

        _ = try await client.complete(
            LLMTranslationPrompt.messages(for: "こんにちは"),
            compatibleMode: false,
            onRetry: nil
        )

        let body = try Self.decodedBody(script.bodies.first)
        #expect(body.reasoningEffort == "low")
        #expect(body.thinking?.type == "enabled")
        #expect(body.outputConfig?.effort == "low")
    }

    @Test("a compatible retry that fails with a non-configuration error rethrows it")
    func compatibleRetryRethrowsOtherError() async throws {
        let script = Script(handler: { index in
            if index == 0 {
                return try Self.status(400)(index)
            }
            return try Self.status(401)(index)
        })
        let engine = try makeEngine(script: script, provider: .openai, model: "gpt-6-luna")

        let thrown = await #expect(throws: TranslationEngineError.self) {
            try await engine.translate(["こんにちは"])
        }

        #expect(thrown == .invalidKey)
        #expect(script.requestCount == 2)
    }
}

private struct RequestBody: Decodable {
    let model: String
    let messages: [LLMChatMessage]
    let reasoningEffort: String?
    let thinking: Thinking?
    let outputConfig: OutputConfig?

    struct Thinking: Decodable {
        let type: String
        let keep: String?
    }

    struct OutputConfig: Decodable {
        let effort: String
    }

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case reasoningEffort = "reasoning_effort"
        case thinking
        case outputConfig = "output_config"
    }
}
