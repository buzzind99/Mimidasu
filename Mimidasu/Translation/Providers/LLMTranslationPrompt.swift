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
    /// is the translation. Quotes and fences are removed in both orders
    /// because models wrap a whole fenced block in quotes just as often as
    /// they quote only the text inside it.
    static func parse(_ content: String) throws -> String {
        var text = content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        for _ in 0 ..< 2 {
            let before = text
            text = strippedQuotes(text).trimmingCharacters(in: .whitespacesAndNewlines)
            text = strippedFences(text).trimmingCharacters(in: .whitespacesAndNewlines)
            text = strippedQuotes(text).trimmingCharacters(in: .whitespacesAndNewlines)
            if text == before {
                break
            }
        }
        // A reply made only of wrappers (`"""`, ``` ``` ```) has no content
        // to translate even though its characters are non-empty.
        let hasContent = text.contains { character in
            !character.isWhitespace && !wrapperCharacters.contains(character)
        }
        guard hasContent else {
            throw TranslationEngineError.badResponse("Model returned an empty translation")
        }
        return text
    }

    private static let wrapperCharacters: Set<Character> = [
        "\"", "\u{201C}", "\u{201D}", "\u{300C}", "\u{300D}", "`"
    ]

    /// Tags models put on the opening fence line. Known formats and
    /// languages are dropped so a tagged fence never leaks its label into
    /// the translation; an unrecognized opening line is treated as content,
    /// because an inline fence can carry the translation itself.
    private static let fenceFormatTags: Set<String> = [
        "json", "jsonl", "text", "plaintext", "plain", "txt", "markdown", "md",
        "yaml", "yml", "html", "xml", "csv", "tsv", "sql", "python", "py",
        "ruby", "rb", "javascript", "js", "typescript", "ts", "swift", "bash",
        "sh", "zsh", "shell", "console", "diff", "ini", "toml", "css", "scss",
        "php", "java", "c", "cpp", "c++", "c#", "go", "rust", "rs", "kotlin",
        "kt", "translation", "output", "result"
    ]

    /// The target catalog's names and codes, plus the fixed Japanese source.
    private static let fenceLanguageTags: Set<String> = {
        var tags = Set(TargetLanguage.known.map { language in
            language.englishName.lowercased()
        })
        tags.formUnion(TargetLanguage.known.map { language in
            language.code.lowercased()
        })
        tags.insert("japanese")
        tags.insert("ja")
        return tags
    }()

    /// Removes ```-fenced wrappers some models emit around the translation.
    /// The entire opening backtick run is removed first; the rest of that
    /// line is dropped when it is empty or a whole-line fence tag, and only
    /// the leading tag token is dropped when the translation shares the
    /// line — under the narrower `isSharedLineTag` rule, not the whole-line
    /// `isFenceTag` check. A translation that starts on the fence line is
    /// preserved.
    private static func strippedFences(_ content: String) -> String {
        var text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("```") else { return text }

        let openingRun = text.prefix(while: { character in character == "`" })
        text = String(text.dropFirst(openingRun.count))
        guard !text.isEmpty else { return "" }
        return strippedClosingFence(strippedOpeningLine(text))
    }

    /// Drops the opening fence's tag line or tag token while preserving a
    /// translation that starts on the same line. A tag that owns the whole
    /// line is matched by `isFenceTag` (format/language sets plus the
    /// BCP-47 shape heuristic); a token sharing the line with the
    /// translation must match `isSharedLineTag` instead — set membership
    /// only, no shape heuristic — so ordinary capitalized first words stay
    /// content.
    private static func strippedOpeningLine(_ content: String) -> String {
        var text = content
        if let firstNewline = text.firstIndex(where: { character in
            character == "\n" || character == "\r"
        }) {
            let firstLine = text[..<firstNewline]
            let tag = firstLine.trimmingCharacters(in: .whitespaces)
            if tag.isEmpty || isFenceTag(tag) {
                text = String(text[text.index(after: firstNewline)...])
                // `\r\n`: the index sits on `\r`; drop the following `\n` too.
                if text.hasPrefix("\n") {
                    text = String(text.dropFirst())
                }
            } else if let tokenStart = firstLine.firstIndex(where: { character in
                !character.isWhitespace
            }), let separator = firstLine[tokenStart...].firstIndex(where: { character in
                character.isWhitespace
            }) {
                let leadingToken = firstLine[tokenStart ..< separator]
                if isSharedLineTag(String(leadingToken)) {
                    text = String(text[separator...])
                }
            }
            return text
        }

        let tag = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if isFenceTag(tag) {
            return ""
        }
        if let tokenStart = text.firstIndex(where: { character in
            !character.isWhitespace
        }), let separator = text[tokenStart...].firstIndex(where: { character in
            character.isWhitespace
        }) {
            let leadingToken = text[tokenStart ..< separator]
            if isSharedLineTag(String(leadingToken)) {
                text = String(text[separator...])
            }
        }
        return text
    }

    /// Four-backtick fences leave one marker behind with a three-marker
    /// strip; drop the whole trailing run. Otherwise keep the last-fence
    /// search for a closing marker followed by stray prose.
    private static func strippedClosingFence(_ content: String) -> String {
        var text = content
        let trailingRun = text.reversed().prefix(while: { character in
            character == "`"
        }).count
        if trailingRun >= 3 {
            text = String(text.dropLast(trailingRun))
        } else if let fenceEnd = text.range(of: "```", options: .backwards) {
            text = String(text[..<fenceEnd.lowerBound])
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isFenceTag(_ raw: String) -> Bool {
        let tag = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard !tag.isEmpty else { return true }
        return fenceFormatTags.contains(tag)
            || fenceLanguageTags.contains(tag)
            || isLanguageCode(tag)
    }

    /// A tag token sharing the fence line with the translation: format tags
    /// match case-insensitively; language names and codes only when written
    /// all-lowercase, so a capitalized first word (`It`, `Hi`) stays content.
    /// The shape heuristic is absent here — it only applies when the tag owns
    /// the whole opening line.
    private static func isSharedLineTag(_ raw: String) -> Bool {
        if fenceFormatTags.contains(raw.lowercased()) {
            return true
        }
        guard raw == raw.lowercased() else { return false }
        return fenceLanguageTags.contains(raw)
    }

    /// A two-letter primary subtag with optional region/script subtags
    /// (`ja`, `en-US`, `zh-Hans`). Three-letter words are deliberately not
    /// treated as codes so an inline translation line like `The …` survives.
    private static func isLanguageCode(_ tag: String) -> Bool {
        let parts = tag.split(whereSeparator: { character in
            character == "-" || character == "_"
        })
        guard let primary = parts.first,
              primary.count == 2,
              primary.allSatisfy({ character in
                  character.isASCII && character.isLetter
              })
        else { return false }
        return parts.dropFirst().allSatisfy { part in
            (2 ... 8).contains(part.count)
                && part.allSatisfy { character in
                    character.isASCII && (character.isLetter || character.isNumber)
                }
        }
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
