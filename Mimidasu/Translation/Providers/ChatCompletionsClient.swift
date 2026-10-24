import Foundation

/// OpenAI-compatible chat-completions core shared by OpenRouter, OpenAI,
/// Moonshot, Z.ai, DeepSeek, and xAI. The provider supplies an endpoint, auth
/// headers, a model, and the reasoning options; this client owns the request
/// envelope, error mapping, retry ladder, and the one-shot compatible
/// fallback when a provider rejects the fast-mode fields.
struct ChatCompletionsClient: LLMChatClient {
    /// Everything that varies between OpenAI-compatible providers.
    struct Config: Sendable {
        let endpoint: URL
        let headers: [String: String]
        let model: String
        let options: LLMRequestOptions
        let treatClientErrorsAsConfiguration: Bool

        init(
            endpoint: URL,
            headers: [String: String],
            model: String,
            options: LLMRequestOptions = LLMRequestOptions(),
            treatClientErrorsAsConfiguration: Bool = false
        ) {
            self.endpoint = endpoint
            self.headers = headers
            self.model = model
            self.options = options
            self.treatClientErrorsAsConfiguration = treatClientErrorsAsConfiguration
        }
    }

    static let rejectedConfigurationMessage =
        "The provider rejected the model or its fast-mode settings."

    private let config: Config
    private let transport: HTTPTranslationTransport
    private let ladder: TransientRetryLadder

    init(
        config: Config,
        transport: HTTPTranslationTransport? = nil,
        ladder: TransientRetryLadder = TransientRetryLadder(retriesBadResponse: true)
    ) {
        self.config = config
        self.transport = transport ?? HTTPTranslationTransport(timeout: 30)
        self.ladder = ladder
    }

    // MARK: - LLM seam

    /// One chat completion with the provider's fast-mode posture, parsed
    /// leniently inside the retry ladder. A rejection of the reasoning
    /// fields is retried once without them; the reply reports the downgrade
    /// so the engine can remember it.
    func complete(
        _ messages: [LLMChatMessage],
        compatibleMode: Bool,
        onRetry: (@Sendable (RetryProgress) -> Void)?
    ) async throws -> LLMReply {
        let effectiveOptions = compatibleMode
            ? config.options.withoutReasoningFields
            : config.options
        do {
            let text = try await perform(
                messages: messages, options: effectiveOptions, onRetry: onRetry
            )
            return LLMReply(text: text, usedCompatibleMode: false)
        } catch let error as TranslationEngineError {
            guard case .invalidConfiguration = error,
                  !compatibleMode,
                  config.options.hasReasoningFields
            else { throw error }
            do {
                let text = try await perform(
                    messages: messages,
                    options: config.options.withoutReasoningFields,
                    onRetry: onRetry
                )
                return LLMReply(text: text, usedCompatibleMode: true)
            } catch let retryError as TranslationEngineError {
                if case .invalidConfiguration = retryError {
                    throw TranslationEngineError.invalidConfiguration(
                        Self.rejectedConfigurationMessage
                    )
                }
                throw retryError
            }
        }
    }

    private func perform(
        messages: [LLMChatMessage],
        options: LLMRequestOptions,
        onRetry: (@Sendable (RetryProgress) -> Void)?
    ) async throws -> String {
        let request = try makeRequest(messages: messages, options: options)
        do {
            return try await ladder.run({
                let data = try await transport.send(request, classify: classifier)
                return try LLMTranslationPrompt.parse(Self.content(of: data))
            }, onRetry: onRetry)
        } catch let failure as HTTPTranslationTransport.Failure {
            throw failure.engineError
        }
    }

    private var classifier: @Sendable (Int, Data) -> TranslationEngineError? {
        config.treatClientErrorsAsConfiguration ? Self.classifyLLM : Self.classify
    }

    private func makeRequest(
        messages: [LLMChatMessage], options: LLMRequestOptions
    ) throws -> URLRequest {
        var request = URLRequest(url: config.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (name, value) in config.headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.httpBody = try JSONEncoder().encode(
            ChatCompletionsRequestBody(
                model: config.model,
                messages: messages,
                options: options
            )
        )
        return request
    }

    // MARK: - Response decoding

    /// Extracts the assistant message content from the chat-completions
    /// envelope before the shared lenient parse runs.
    static func content(of data: Data) throws -> String {
        do {
            let response = try JSONDecoder().decode(ChatCompletionsResponse.self, from: data)
            guard !response.choices.isEmpty else {
                throw TranslationEngineError.badResponse("Response contained no choices")
            }
            guard let content = response.choices[0].message.content else {
                throw TranslationEngineError.badResponse(
                    "Response contained no message content"
                )
            }
            return content
        } catch let error as TranslationEngineError {
            throw error
        } catch {
            throw TranslationEngineError.badResponse("Unparseable response body")
        }
    }

    // MARK: - Error mapping

    /// Error mapping shared by every OpenAI-compatible variant: 401 invalid
    /// key, 402 quota, 429 rate limit, everything else a server error.
    /// OpenRouter keeps this mapping unchanged.
    static func classify(_ status: Int, _ body: Data) -> TranslationEngineError? {
        switch status {
        case 200 ... 299: nil
        case 401: .invalidKey
        case 402: .quotaExceeded
        case 429: .rateLimited
        default: .serverError(status)
        }
    }

    /// Mapping for the OpenAI-compatible providers that surface a rejected
    /// model or fast-mode field as a client error.
    static func classifyLLM(_ status: Int, _ body: Data) -> TranslationEngineError? {
        switch status {
        case 200 ... 299: nil
        case 401: .invalidKey
        case 402: .quotaExceeded
        case 429: .rateLimited
        case 400, 404, 422: .invalidConfiguration(rejectedConfigurationMessage)
        default: .serverError(status)
        }
    }
}

private struct ChatCompletionsRequestBody: Encodable {
    let model: String
    let messages: [LLMChatMessage]
    let reasoningEffort: String?
    let thinking: Thinking?
    let outputConfig: OutputConfig?
    let maxTokens: Int?

    struct Thinking: Encodable {
        let type: String
        let keep: String?
    }

    struct OutputConfig: Encodable {
        let effort: String
    }

    init(model: String, messages: [LLMChatMessage], options: LLMRequestOptions) {
        self.model = model
        self.messages = messages
        reasoningEffort = options.reasoningEffort
        thinking = options.thinking.map { option in
            Thinking(type: option.type, keep: option.keep)
        }
        outputConfig = options.outputConfig.map { option in
            OutputConfig(effort: option.effort)
        }
        maxTokens = options.maxTokens
    }

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case reasoningEffort = "reasoning_effort"
        case thinking
        case outputConfig = "output_config"
        case maxTokens = "max_tokens"
    }
}

private struct ChatCompletionsMessage: Decodable {
    let content: String?
}

private struct ChatCompletionsChoice: Decodable {
    let message: ChatCompletionsMessage
}

private struct ChatCompletionsResponse: Decodable {
    let choices: [ChatCompletionsChoice]
}
