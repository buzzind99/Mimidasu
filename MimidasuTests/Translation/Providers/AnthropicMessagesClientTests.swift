import Foundation
@testable import Mimidasu
import Testing

/// Tests `AnthropicMessagesClient` against a scripted transport: native
/// Messages request shape, response text extraction, error mapping, the
/// compatible fallback, and the transient retry ladder. No network.
@Suite("AnthropicMessagesClient")
struct AnthropicMessagesClientTests {

    // MARK: - Helpers

    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private static let apiKey = "anthropic-key-1234"
    private static let defaultModel = "claude-haiku-5-5"
    private static let messages = LLMTranslationPrompt.messages(for: "こんにちは")

    /// Records every request the client issues; responses come from a
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

    private struct FakeBlock: Encodable {
        let type: String
        let text: String?
    }

    private struct FakeResponse: Encodable {
        let content: [FakeBlock]
    }

    private struct FakeErrorEnvelope: Encodable {
        let type: String
        let error: FakeErrorDetail
    }

    private struct FakeErrorDetail: Encodable {
        let type: String
        let message: String
    }

    private static func httpResponse(_ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: endpoint, statusCode: status, httpVersion: nil, headerFields: nil
        )!
    }

    private static func okContent(
        _ blocks: [FakeBlock]
    ) -> @Sendable (_ index: Int) throws -> (Data, HTTPURLResponse) {
        { _ in
            try (JSONEncoder().encode(FakeResponse(content: blocks)), httpResponse(200))
        }
    }

    private static func textContent(
        _ text: String
    ) -> @Sendable (_ index: Int) throws -> (Data, HTTPURLResponse) {
        okContent([FakeBlock(type: "text", text: text)])
    }

    private static func status(
        _ code: Int
    ) -> @Sendable (_ index: Int) throws -> (Data, HTTPURLResponse) {
        { _ in (Data(), httpResponse(code)) }
    }

    private static func errorBody(_ type: String) -> Data {
        guard !type.isEmpty else { return Data() }
        let envelope = FakeErrorEnvelope(
            type: "error",
            error: FakeErrorDetail(type: type, message: "provider detail")
        )
        return (try? JSONEncoder().encode(envelope)) ?? Data()
    }

    private func makeClient(
        script: Script,
        model: String? = nil,
        options: LLMRequestOptions? = nil,
        ladder: TransientRetryLadder? = nil
    ) -> AnthropicMessagesClient {
        let effectiveModel = model ?? Self.defaultModel
        let transport = HTTPTranslationTransport(timeout: 1) { request in
            let index = script.requestCount
            script.record(request, body: request.httpBody)
            return try script.handler(index)
        }
        return AnthropicMessagesClient(
            config: AnthropicMessagesClient.Config(
                endpoint: Self.endpoint,
                apiKey: Self.apiKey,
                model: effectiveModel,
                options: options
                    ?? LLMReasoningPolicy.options(for: .anthropic, model: effectiveModel)
            ),
            transport: transport,
            ladder: ladder ?? TransientRetryLadder(retriesBadResponse: true, sleep: { _ in })
        )
    }

    private static func decodedBody(_ data: Data?) throws -> RequestBody {
        let data = try #require(data)
        return try JSONDecoder().decode(RequestBody.self, from: data)
    }

    private static func jsonObject(_ data: Data?) throws -> [String: Any] {
        let data = try #require(data)
        return try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }

    // MARK: - Request shape

    @Test("sends a native Messages POST with the Anthropic headers")
    func requestShape() async throws {
        let script = Script(handler: Self.textContent("hello"))
        let client = makeClient(script: script)

        let reply = try await client.complete(
            Self.messages, compatibleMode: false, onRetry: nil
        )

        #expect(reply == LLMReply(text: "hello", usedCompatibleMode: false))
        let request = try #require(script.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url == Self.endpoint)
        #expect(request.value(forHTTPHeaderField: "x-api-key") == Self.apiKey)
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(request.value(forHTTPHeaderField: "content-type") == "application/json")
    }

    @Test("Haiku 5.5 sends max_tokens, a top-level system, one user message, disabled thinking, and low effort")
    func haiku55RequestBody() async throws {
        let script = Script(handler: Self.textContent("hello"))
        let client = makeClient(script: script, model: "claude-haiku-5-5")

        _ = try await client.complete(Self.messages, compatibleMode: false, onRetry: nil)

        let body = try Self.decodedBody(script.bodies.first)
        #expect(body.model == "claude-haiku-5-5")
        #expect(body.maxTokens == 4096)
        #expect(body.system?.contains("Japanese-to-English") == true)
        #expect(body.messages.map(\.role) == ["user"])
        #expect(body.messages.first?.content == "こんにちは")
        #expect(body.thinking?.type == "disabled")
        #expect(body.outputConfig?.effort == "low")
    }

    @Test("Haiku 4.5 sends max_tokens without output_config")
    func haiku45RequestBody() async throws {
        let script = Script(handler: Self.textContent("hello"))
        let client = makeClient(script: script, model: "claude-haiku-4-5")

        _ = try await client.complete(Self.messages, compatibleMode: false, onRetry: nil)

        let body = try Self.decodedBody(script.bodies.first)
        let object = try Self.jsonObject(script.bodies.first)
        #expect(body.maxTokens == 4096)
        #expect(body.thinking?.type == "disabled")
        #expect(body.outputConfig == nil)
        #expect(object["output_config"] == nil)
    }

    @Test("an unknown model sends no thinking or output_config but keeps max_tokens")
    func unknownModelRequestBody() async throws {
        let script = Script(handler: Self.textContent("hello"))
        let client = makeClient(script: script, model: "claude-unknown-9")

        _ = try await client.complete(Self.messages, compatibleMode: false, onRetry: nil)

        let body = try Self.decodedBody(script.bodies.first)
        let object = try Self.jsonObject(script.bodies.first)
        #expect(body.maxTokens == 4096)
        #expect(body.thinking == nil)
        #expect(body.outputConfig == nil)
        #expect(object["thinking"] == nil)
        #expect(object["output_config"] == nil)
    }

    @Test("multiple system messages are concatenated into one top-level system string")
    func multipleSystemMessages() async throws {
        let script = Script(handler: Self.textContent("hello"))
        let client = makeClient(script: script)
        let messages = [
            LLMChatMessage(role: "system", content: "first"),
            LLMChatMessage(role: "system", content: "second"),
            LLMChatMessage(role: "user", content: "こんにちは")
        ]

        _ = try await client.complete(messages, compatibleMode: false, onRetry: nil)

        let body = try Self.decodedBody(script.bodies.first)
        #expect(body.system == "first\n\nsecond")
        #expect(body.messages.map(\.role) == ["user"])
        #expect(body.messages.first?.content == "こんにちは")
    }

    // MARK: - Response decoding

    @Test("thinking blocks are ignored and text blocks are concatenated")
    func textBlocksConcatenated() async throws {
        let script = Script(handler: Self.okContent([
            FakeBlock(type: "thinking", text: "internal reasoning"),
            FakeBlock(type: "text", text: "hello "),
            FakeBlock(type: "text", text: "there")
        ]))
        let client = makeClient(script: script)

        let reply = try await client.complete(
            Self.messages, compatibleMode: false, onRetry: nil
        )

        #expect(reply.text == "hello there")
        #expect(reply.usedCompatibleMode == false)
    }

    @Test("a response with no text block is a retried badResponse")
    func noTextBlock() async {
        let script = Script(handler: Self.okContent([
            FakeBlock(type: "thinking", text: "internal reasoning")
        ]))
        let client = makeClient(script: script)

        let thrown = await #expect(throws: TranslationEngineError.self) {
            try await client.complete(Self.messages, compatibleMode: false, onRetry: nil)
        }

        #expect(thrown == .badResponse("Response contained no text"))
        #expect(script.requestCount == 3)
    }

    @Test("malformed output is parsed inside the ladder and retried as badResponse")
    func malformedOutputRetried() async {
        let script = Script(handler: Self.textContent("   "))
        let client = makeClient(script: script)

        let thrown = await #expect(throws: TranslationEngineError.self) {
            try await client.complete(Self.messages, compatibleMode: false, onRetry: nil)
        }

        #expect(thrown == .badResponse("Model returned an empty translation"))
        #expect(script.requestCount == 3)
    }

    @Test("code fences and wrapping quotes are stripped from the reply")
    func lenientReplyStripped() async throws {
        let script = Script(handler: Self.textContent("```json\n\"hello\"\n```"))
        let client = makeClient(script: script)

        let reply = try await client.complete(
            Self.messages, compatibleMode: false, onRetry: nil
        )

        #expect(reply.text == "hello")
    }
}

extension AnthropicMessagesClientTests {

    // MARK: - Error mapping

    @Test(
        "HTTP statuses and error types map into the engine taxonomy",
        arguments: [
            (401, "", TranslationEngineError.invalidKey),
            (500, "authentication_error", .invalidKey),
            (403, "", .invalidKey),
            (500, "permission_error", .invalidKey),
            (402, "", .quotaExceeded),
            (500, "billing_error", .quotaExceeded),
            (429, "", .rateLimited),
            (500, "rate_limit_error", .rateLimited),
            (
                400, "",
                .invalidConfiguration(AnthropicMessagesClient.rejectedConfigurationMessage)
            ),
            (
                404, "",
                .invalidConfiguration(AnthropicMessagesClient.rejectedConfigurationMessage)
            ),
            (
                422, "",
                .invalidConfiguration(AnthropicMessagesClient.rejectedConfigurationMessage)
            ),
            (
                500, "invalid_request_error",
                .invalidConfiguration(AnthropicMessagesClient.rejectedConfigurationMessage)
            ),
            (
                500, "not_found_error",
                .invalidConfiguration(AnthropicMessagesClient.rejectedConfigurationMessage)
            ),
            (529, "", .serverError(529)),
            (500, "overloaded_error", .serverError(529)),
            (500, "", .serverError(500)),
            (503, "unknown_error", .serverError(503))
        ]
    )
    func errorMapping(status: Int, type: String, expected: TranslationEngineError) {
        #expect(AnthropicMessagesClient.classify(status, Self.errorBody(type)) == expected)
    }

    @Test("a 2xx status is not an error even with an error-shaped body")
    func successStatusIsNotAnError() {
        #expect(AnthropicMessagesClient.classify(200, Data()) == nil)
        #expect(AnthropicMessagesClient.classify(204, Self.errorBody("authentication_error")) == nil)
    }

    // MARK: - Compatible fallback

    @Test("a rejected reasoning request retries once without the fields and reports compatible mode")
    func compatibleRetrySucceeds() async throws {
        let script = Script(handler: { index in
            if index == 0 {
                return try Self.status(400)(index)
            }
            return try Self.textContent("hello")(index)
        })
        let client = makeClient(script: script)

        let reply = try await client.complete(
            Self.messages, compatibleMode: false, onRetry: nil
        )

        #expect(reply == LLMReply(text: "hello", usedCompatibleMode: true))
        #expect(script.requestCount == 2)

        let firstBody = try Self.decodedBody(script.bodies.first)
        #expect(firstBody.thinking?.type == "disabled")
        #expect(firstBody.outputConfig?.effort == "low")

        let retryBody = try Self.decodedBody(script.bodies.last)
        let retryObject = try Self.jsonObject(script.bodies.last)
        #expect(retryBody.maxTokens == 4096)
        #expect(retryBody.thinking == nil)
        #expect(retryBody.outputConfig == nil)
        #expect(retryObject["thinking"] == nil)
        #expect(retryObject["output_config"] == nil)
    }

    @Test("a second configuration rejection surfaces the fixed copy after exactly two requests")
    func compatibleRetryFailsWithFixedCopy() async {
        let script = Script(handler: Self.status(400))
        let client = makeClient(script: script)

        let thrown = await #expect(throws: TranslationEngineError.self) {
            try await client.complete(Self.messages, compatibleMode: false, onRetry: nil)
        }

        #expect(
            thrown == .invalidConfiguration(
                "The provider rejected the model or its fast-mode settings."
            )
        )
        #expect(script.requestCount == 2)
    }

    @Test("a configuration rejection without reasoning fields fails immediately")
    func noReasoningFieldsNoRetry() async {
        let script = Script(handler: Self.status(400))
        let client = makeClient(script: script, options: LLMRequestOptions())

        let thrown = await #expect(throws: TranslationEngineError.self) {
            try await client.complete(Self.messages, compatibleMode: false, onRetry: nil)
        }

        #expect(
            thrown == .invalidConfiguration(
                AnthropicMessagesClient.rejectedConfigurationMessage
            )
        )
        #expect(script.requestCount == 1)
    }

    @Test("compatibleMode strips reasoning fields from the first attempt")
    func compatibleModeFromStart() async throws {
        let script = Script(handler: Self.textContent("hello"))
        let client = makeClient(script: script)

        let reply = try await client.complete(
            Self.messages, compatibleMode: true, onRetry: nil
        )

        #expect(reply == LLMReply(text: "hello", usedCompatibleMode: false))
        #expect(script.requestCount == 1)
        let body = try Self.decodedBody(script.bodies.first)
        #expect(body.maxTokens == 4096)
        #expect(body.thinking == nil)
        #expect(body.outputConfig == nil)
    }

    @Test("compatibleMode with a configuration rejection makes no extra request")
    func compatibleModeNoSecondAttempt() async {
        let script = Script(handler: Self.status(400))
        let client = makeClient(script: script)

        let thrown = await #expect(throws: TranslationEngineError.self) {
            try await client.complete(Self.messages, compatibleMode: true, onRetry: nil)
        }

        #expect(
            thrown == .invalidConfiguration(
                AnthropicMessagesClient.rejectedConfigurationMessage
            )
        )
        #expect(script.requestCount == 1)
    }

    // MARK: - Retry behavior

    @Test("an invalid key fails immediately")
    func invalidKeyFailsImmediately() async {
        let script = Script(handler: Self.status(401))
        let client = makeClient(script: script)

        let thrown = await #expect(throws: TranslationEngineError.self) {
            try await client.complete(Self.messages, compatibleMode: false, onRetry: nil)
        }

        #expect(thrown == .invalidKey)
        #expect(script.requestCount == 1)
    }

    @Test("429 and 529 are retried by the ladder", arguments: [429, 529])
    func transientStatusRetried(status: Int) async throws {
        let script = Script(handler: { index in
            if index == 0 {
                return try Self.status(status)(index)
            }
            return try Self.textContent("hello")(index)
        })
        let log = ProgressLog()
        let client = makeClient(script: script)

        let reply = try await client.complete(
            Self.messages,
            compatibleMode: false,
            onRetry: { progress in log.append(progress) }
        )

        #expect(reply.text == "hello")
        #expect(script.requestCount == 2)
        let progress = try #require(log.entries.first)
        #expect(progress.stage == .batchRetry)
        #expect(progress.attemptsLeft == 2)
    }

    @Test("a compatible retry that fails with a non-configuration error rethrows it")
    func compatibleRetryRethrowsOtherError() async {
        let script = Script(handler: { index in
            if index == 0 {
                return try Self.status(400)(index)
            }
            return try Self.status(401)(index)
        })
        let client = makeClient(script: script)

        let thrown = await #expect(throws: TranslationEngineError.self) {
            try await client.complete(Self.messages, compatibleMode: false, onRetry: nil)
        }

        #expect(thrown == .invalidKey)
        #expect(script.requestCount == 2)
    }

    @Test("an unparseable success body is retried then surfaces as badResponse")
    func unparseableBodyThrows() async {
        let script = Script(handler: { _ in
            (Data("garbage".utf8), Self.httpResponse(200))
        })
        let client = makeClient(script: script)

        let thrown = await #expect(throws: TranslationEngineError.self) {
            try await client.complete(Self.messages, compatibleMode: false, onRetry: nil)
        }

        #expect(thrown == .badResponse("Unparseable response body"))
        #expect(script.requestCount == 3)
    }
}

private struct RequestBody: Decodable {
    let model: String
    let system: String?
    let messages: [LLMChatMessage]
    let thinking: Thinking?
    let outputConfig: OutputConfig?
    let maxTokens: Int

    struct Thinking: Decodable {
        let type: String
        let keep: String?
    }

    struct OutputConfig: Decodable {
        let effort: String
    }

    enum CodingKeys: String, CodingKey {
        case model
        case system
        case messages
        case thinking
        case outputConfig = "output_config"
        case maxTokens = "max_tokens"
    }
}
