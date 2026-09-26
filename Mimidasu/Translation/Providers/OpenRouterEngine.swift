import Foundation

/// OpenRouter engine: chat-completions with an arbitrary user-supplied model.
///
/// One sentence per request (`preferredBatchSize == 1`): the reply *is* the
/// translation, so the model faces a natural "reply with only the
/// translation" contract instead of a strict multi-item JSON shape, and a
/// malformed reply fails one sentence rather than a batch. Input is ASR
/// output, so the prompt tells the model to infer intent past recognition
/// errors. Parsing is defensive (code fences and one pair of wrapping quotes
/// stripped, non-empty validated); malformed output surfaces as
/// `badResponse`, which the engine's ladder retries — LLM replies are
/// nondeterministic and usually improve on re-ask. No `response_format`
/// is sent: arbitrary user models may 400 on it.
struct OpenRouterEngine: TranslationEngine {
    /// Long numbered lists degrade JSON adherence and translation quality on
    /// small models, and single-sentence requests keep failures isolated —
    /// the queue slices every batch to one sentence.
    let preferredBatchSize = 1

    /// LLM replies are nondeterministic: a `.badResponse` is a transient
    /// (retryable, yellow-toast) failure, matching the ladder's
    /// `retriesBadResponse: true`.
    let transientBadResponse = true

    var onRetry: (@Sendable (RetryProgress) -> Void)?

    /// Selected target language; names the language in the system prompt.
    private let target: TargetLanguage

    private let client: ChatCompletionsClient

    static let endpoint = URL(string: "https://openrouter.ai/api/v1/chat/completions")!
    static let defaultModel = "tencent/hy-mt2-30b-a3b"

    init(
        apiKey: String,
        model: String,
        target: TargetLanguage = .english,
        transport: HTTPTranslationTransport? = nil,
        ladder: TransientRetryLadder = TransientRetryLadder(retriesBadResponse: true)
    ) {
        self.target = target
        // An empty model string (placeholder-only Settings field) would be
        // sent verbatim and rejected by the API; fall back to the default.
        client = ChatCompletionsClient(
            config: ChatCompletionsClient.Config(
                endpoint: Self.endpoint,
                headers: ["Authorization": "Bearer \(apiKey)"],
                model: model.isEmpty ? Self.defaultModel : model
            ),
            transport: transport,
            ladder: ladder
        )
    }

    func translate(_ texts: [String]) async throws -> [String] {
        guard !texts.isEmpty else { return [] }

        // The queue slices batches to `preferredBatchSize == 1`, but stay
        // correct for any caller: one request per sentence, order preserved.
        // Parse runs inside the client's ladder, so a malformed reply is
        // retried before it can fail the sentence.
        var results: [String] = []
        results.reserveCapacity(texts.count)
        for text in texts {
            try await results.append(client.complete(
                Self.messages(for: text, target: target),
                decode: { data in try Self.parse(ChatCompletionsClient.content(of: data)) },
                onRetry: onRetry
            ))
        }
        return results
    }

    // MARK: - Prompt + parsing

    /// System prompt names the target in three places ("Japanese-to-Spanish",
    /// "casual Spanish", "the Spanish translation") and keeps the ASR caveat:
    /// the model must infer intent past recognition errors.
    static func messages(for text: String, target: TargetLanguage = .english) -> [ChatCompletionsClient.Message] {
        let system = """
        You are a Japanese-to-\(target.englishName) translation engine. Input is ASR output \
        and may contain recognition errors or fragments — infer the intended meaning in \
        casual \(target.englishName). Reply with only the \(target.englishName) translation: \
        no quotes, no explanations, no romaji, nothing else.
        """
        return [
            ChatCompletionsClient.Message(role: "system", content: system),
            ChatCompletionsClient.Message(role: "user", content: text)
        ]
    }

    /// Lenient parse of a single-sentence reply: strips code fences and one
    /// pair of wrapping quotes, then requires non-empty output. What remains
    /// is the translation.
    static func parse(_ content: String) throws -> String {
        var text = strippedFences(content)
        text = strippedQuotes(text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw TranslationEngineError.badResponse("Model returned an empty translation")
        }
        return text
    }

    /// Removes ```-fenced wrappers some models emit around the translation.
    private static func strippedFences(_ content: String) -> String {
        var text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("```") else { return text }
        // Drop the first line (the fence + optional language tag).
        if let firstNewline = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: firstNewline)...])
        } else {
            // A fence with no newline: strip the bare markers.
            text = String(text.dropFirst(3))
            if text.hasSuffix("```") {
                text = String(text.dropLast(3))
            }
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let fenceEnd = text.range(of: "```", options: .backwards) {
            text = String(text[..<fenceEnd.lowerBound])
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Removes one pair of wrapping straight/curly double quotes or Japanese
    /// corner brackets some models add despite the prompt.
    private static func strippedQuotes(_ content: String) -> String {
        let pairs = [("\"", "\""), ("\u{201C}", "\u{201D}"), ("\u{300C}", "\u{300D}")]
        for (open, close) in pairs
            where content.count >= 2 && content.hasPrefix(open) && content.hasSuffix(close)
        {
            return String(content.dropFirst().dropLast())
        }
        return content
    }
}
