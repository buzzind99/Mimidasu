import Foundation
@testable import Mimidasu
import Testing

/// Covers the shared LLM reply parser's wrapper handling: fences, quotes,
/// language tags, and empty replies.
@Suite("LLMTranslationPrompt")
struct LLMTranslationPromptTests {
    @Test("strips a fenced block")
    func stripsFence() throws {
        #expect(try LLMTranslationPrompt.parse("```\nhello\n```") == "hello")
    }

    @Test("strips a fence whose language tag shares the opening line")
    func stripsLanguageTag() throws {
        #expect(try LLMTranslationPrompt.parse("```json\nhello\n```") == "hello")
        #expect(try LLMTranslationPrompt.parse("```json hello```") == "hello")
        #expect(try LLMTranslationPrompt.parse("```text hello\nworld```") == "hello\nworld")
    }

    @Test("strips language-name and language-code tags")
    func stripsNonFormatTags() throws {
        #expect(try LLMTranslationPrompt.parse("```ja\nこんにちは\n```") == "こんにちは")
        #expect(try LLMTranslationPrompt.parse("```Japanese\nこんにちは\n```") == "こんにちは")
        #expect(try LLMTranslationPrompt.parse("```en-US\nhello\n```") == "hello")
        #expect(try LLMTranslationPrompt.parse("```zh-Hans\n你好\n```") == "你好")
        #expect(try LLMTranslationPrompt.parse("```ja こんにちは```") == "こんにちは")
    }

    @Test("strips a tag token that follows leading whitespace on the fence line")
    func stripsSpacedTag() throws {
        #expect(try LLMTranslationPrompt.parse("``` ja こんにちは```") == "こんにちは")
        #expect(try LLMTranslationPrompt.parse("``` ja hello\nworld```") == "hello\nworld")
    }

    @Test("strips an uppercase format tag on a shared line and an uppercase whole-line code")
    func stripsUppercaseTags() throws {
        #expect(try LLMTranslationPrompt.parse("```JSON hello```") == "hello")
        #expect(try LLMTranslationPrompt.parse("```EN\nhello\n```") == "hello")
    }

    @Test("keeps a capitalized language name that shares the fence line")
    func keepsCapitalizedLanguageNameOnSharedLine() throws {
        #expect(try LLMTranslationPrompt.parse("```Japanese hello```") == "Japanese hello")
    }

    @Test("strips CRLF fences, with and without a tag")
    func stripsCRLFFence() throws {
        #expect(try LLMTranslationPrompt.parse("```\r\nhello\r\n```") == "hello")
        #expect(try LLMTranslationPrompt.parse("```json\r\nhello\r\n```") == "hello")
        #expect(try LLMTranslationPrompt.parse("```ja\r\nこんにちは\r\n```") == "こんにちは")
    }

    @Test("normalizes CRLF content to bare newlines")
    func normalizesCRLFContent() throws {
        #expect(try LLMTranslationPrompt.parse("```\r\nhello\r\nworld\r\n```") == "hello\nworld")
    }

    @Test("keeps a translation that starts on the fence line")
    func keepsFirstLineTranslation() throws {
        #expect(try LLMTranslationPrompt.parse("```hello world```") == "hello world")
        #expect(try LLMTranslationPrompt.parse("```hello\nworld```") == "hello\nworld")
        // "The" is not a language code: the first word is content.
        #expect(try LLMTranslationPrompt.parse("```The cat\nsat```") == "The cat\nsat")
    }

    @Test("keeps a capitalized first word that shares the fence line")
    func keepsCapitalizedSharedLineWords() throws {
        #expect(try LLMTranslationPrompt.parse("```It is fine```") == "It is fine")
        #expect(try LLMTranslationPrompt.parse("```No way```") == "No way")
        #expect(try LLMTranslationPrompt.parse("```Hi there\nfriend```") == "Hi there\nfriend")
    }

    @Test("keeps a lowercase first word that is not a tag")
    func keepsUnknownLowercaseWord() throws {
        #expect(try LLMTranslationPrompt.parse("```no way```") == "no way")
    }

    @Test("a lowercase catalog code still strips when it shares the fence line")
    func stripsLowercaseCatalogCodeOnSharedLine() throws {
        // Ruling: `it` is Italian's lowercase BCP-47 code, so the shared-line
        // rule accepts it and drops the token.
        #expect(try LLMTranslationPrompt.parse("```it is fine```") == "is fine")
    }

    @Test("strips a fence wrapped in quotes")
    func stripsQuotedFence() throws {
        #expect(try LLMTranslationPrompt.parse("\"```\nhello\n```\"") == "hello")
        #expect(try LLMTranslationPrompt.parse("\u{201C}```json\nhello\n```\u{201D}") == "hello")
    }

    @Test("strips a four-backtick fence without leaving a marker")
    func stripsLongFenceRun() throws {
        #expect(try LLMTranslationPrompt.parse("````\nhello\n````") == "hello")
        #expect(try LLMTranslationPrompt.parse("````hello````") == "hello")
    }

    @Test("strips one pair of wrapping quotes")
    func stripsQuotes() throws {
        #expect(try LLMTranslationPrompt.parse("\"hello\"") == "hello")
        #expect(try LLMTranslationPrompt.parse("\u{201C}hello\u{201D}") == "hello")
        #expect(try LLMTranslationPrompt.parse("\u{300C}hello\u{300D}") == "hello")
    }

    @Test("leaves a plain reply untouched")
    func leavesPlainReply() throws {
        #expect(try LLMTranslationPrompt.parse("hello there") == "hello there")
    }

    @Test("an empty wrapped reply still fails")
    func emptyReplyThrows() {
        #expect(
            throws: TranslationEngineError.badResponse(
                "Model returned an empty translation"
            )
        ) {
            try LLMTranslationPrompt.parse("\"```\n\n```\"")
        }
    }

    @Test(
        "tag-only and wrapper-only replies fail instead of becoming translations",
        arguments: [
            "```json", "```ja", "```json\n", "```ja\n```", "\"\"\"", "```"
        ]
    )
    func wrapperOnlyReplyThrows(reply: String) {
        #expect(
            throws: TranslationEngineError.badResponse(
                "Model returned an empty translation"
            )
        ) {
            try LLMTranslationPrompt.parse(reply)
        }
    }
}
