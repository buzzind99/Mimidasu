import Foundation

/// Anthropic's native Messages API: the system prompt travels in its own
/// top-level field, `max_tokens` is always required, and reasoning fields are
/// sent only for the models the policy knows. A model that rejects those
/// fields is retried once without them, outside the transient ladder.
struct AnthropicMessagesClient: LLMChatClient {
    /// Everything that varies per provider call.
    struct Config: Sendable {
        let endpoint: URL
        let apiKey: String
        let model: String
        let options: LLMRequestOptions
    }

    static let rejectedConfigurationMessage =
        "The provider rejected the model or its fast-mode settings."

    private static let apiVersion = "2023-06-01"

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

    /// One Messages request with the provider's fast-mode posture, parsed
    /// leniently inside the retry ladder. A rejection of the reasoning fields
    /// is retried once without them; the reply reports the downgrade so the
    /// engine can remember it.
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

    /// One request whose body decode and reply parse both run *inside* the
    /// ladder, so malformed LLM output shares the transient budget with the
    /// transport round-trip.
    private func perform(
        messages: [LLMChatMessage],
        options: LLMRequestOptions,
        onRetry: (@Sendable (RetryProgress) -> Void)?
    ) async throws -> String {
        let request = try makeRequest(messages: messages, options: options)
        do {
            return try await ladder.run({
                let data = try await transport.send(request, classify: Self.classify)
                return try LLMTranslationPrompt.parse(Self.text(of: data))
            }, onRetry: onRetry)
        } catch let failure as HTTPTranslationTransport.Failure {
            throw failure.engineError
        }
    }

    private func makeRequest(
        messages: [LLMChatMessage], options: LLMRequestOptions
    ) throws -> URLRequest {
        var request = URLRequest(url: config.endpoint)
        request.httpMethod = "POST"
        request.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONEncoder().encode(
            MessagesRequestBody(model: config.model, messages: messages, options: options)
        )
        return request
    }

    // MARK: - Response decoding

    /// Concatenates the text blocks of the response envelope, ignoring
    /// thinking blocks. The caller runs the shared lenient parse on the
    /// result.
    static func text(of data: Data) throws -> String {
        do {
            let response = try JSONDecoder().decode(MessagesResponse.self, from: data)
            let text = (response.content ?? []).compactMap { block in
                block.type == "text" ? block.text : nil
            }.joined()
            guard !text.isEmpty else {
                throw TranslationEngineError.badResponse("Response contained no text")
            }
            return text
        } catch let error as TranslationEngineError {
            throw error
        } catch {
            throw TranslationEngineError.badResponse("Unparseable response body")
        }
    }

    // MARK: - Error mapping

    /// Maps an Anthropic error envelope into the engine taxonomy. The
    /// provider's `error.type` wins when recognizable; the HTTP status is the
    /// fallback. The provider's message is never surfaced.
    static func classify(_ status: Int, _ body: Data) -> TranslationEngineError? {
        guard !(200 ... 299).contains(status) else { return nil }
        if let error = classify(errorType: errorType(in: body)) {
            return error
        }
        return classify(status: status)
    }

    private static func classify(errorType: String?) -> TranslationEngineError? {
        switch errorType {
        case "authentication_error", "permission_error": .invalidKey
        case "billing_error": .quotaExceeded
        case "rate_limit_error": .rateLimited
        case "invalid_request_error", "not_found_error":
            .invalidConfiguration(rejectedConfigurationMessage)
        case "overloaded_error": .serverError(529)
        default: nil
        }
    }

    private static func classify(status: Int) -> TranslationEngineError? {
        switch status {
        case 401, 403: .invalidKey
        case 402: .quotaExceeded
        case 429: .rateLimited
        case 529: .serverError(529)
        case 400, 404, 422: .invalidConfiguration(rejectedConfigurationMessage)
        default: .serverError(status)
        }
    }

    private static func errorType(in body: Data) -> String? {
        guard let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: body) else {
            return nil
        }
        return envelope.error?.type
    }
}

private struct ErrorEnvelope: Decodable {
    let error: ErrorDetail?

    struct ErrorDetail: Decodable {
        let type: String?
    }
}

private struct MessagesResponse: Decodable {
    let content: [ContentBlock]?

    struct ContentBlock: Decodable {
        let type: String?
        let text: String?
    }
}

private struct MessagesRequestBody: Encodable {
    let model: String
    let system: String?
    let messages: [LLMChatMessage]
    let thinking: Thinking?
    let outputConfig: OutputConfig?
    let maxTokens: Int

    struct Thinking: Encodable {
        let type: String
        let keep: String?
    }

    struct OutputConfig: Encodable {
        let effort: String
    }

    init(model: String, messages: [LLMChatMessage], options: LLMRequestOptions) {
        self.model = model
        let joinedSystem = messages
            .filter { message in message.role == "system" }
            .map(\.content)
            .joined(separator: "\n\n")
        system = joinedSystem.isEmpty ? nil : joinedSystem
        self.messages = messages.filter { message in message.role != "system" }
        thinking = options.thinking.map { option in
            Thinking(type: option.type, keep: option.keep)
        }
        outputConfig = options.outputConfig.map { option in
            OutputConfig(effort: option.effort)
        }
        maxTokens = options.maxTokens ?? LLMRequestOptions.anthropicDefaultMaxTokens
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
