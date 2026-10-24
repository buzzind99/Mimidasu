import Foundation

/// The shared one-sentence LLM translation contract: prompt and lenient
/// parse. Clients only transport messages and reply text; this type owns the
/// wording and the fence/quote cleanup so every LLM provider behaves alike.
enum LLMTranslationPrompt {
    /// System prompt names the target in three places ("Japanese-to-Spanish",
    /// "casual Spanish", "the Spanish translation") and keeps the ASR caveat:
    /// the model must infer intent past recognition errors.
    static func messages(
        for text: String, target: TargetLanguage = .english
    ) -> [LLMChatMessage] {
        let system = """
        You are a Japanese-to-\(target.englishName) translation engine. Input is ASR output \
        and may contain recognition errors or fragments — infer the intended meaning in \
        casual \(target.englishName). Reply with only the \(target.englishName) translation: \
        no quotes, no explanations, no romaji, nothing else.
        """
        return [
            LLMChatMessage(role: "system", content: system),
            LLMChatMessage(role: "user", content: text)
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
