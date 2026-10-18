import Foundation
@testable import Mimidasu
import Testing

/// The pure display-formatting surface of the archive models: duration and
/// sentence-count text, chip labels and badge codes, completeness, and the
/// auto-title snippet.
@Suite("Archive models")
struct ArchiveModelsTests {

    private func summary(
        firstSentence: String? = nil, name: String? = nil, startedAt: Date? = nil
    ) -> ArchivedSessionSummary {
        ArchivedSessionSummary(
            id: 1,
            status: .complete,
            saved: false,
            startedAt: startedAt ?? Date(timeIntervalSince1970: 1_000_000),
            durationS: 90,
            pausedMS: 0,
            sentenceCount: 3,
            targetLang: "en",
            model: "test-model",
            chunkMS: 160,
            name: name,
            firstSentence: firstSentence
        )
    }

    // MARK: - Duration

    @Test("durationText formats seconds, minutes, and hours")
    func durationTextFormats() {
        #expect(ArchivedSessionSummary.durationText(seconds: 0) == "0:00")
        #expect(ArchivedSessionSummary.durationText(seconds: 59) == "0:59")
        #expect(ArchivedSessionSummary.durationText(seconds: 3599) == "59:59")
        #expect(ArchivedSessionSummary.durationText(seconds: 3600) == "1:00:00")
    }

    // MARK: - Sentence counts

    @Test("sentenceCountText is plural-aware")
    func sentenceCountTextIsPluralAware() {
        #expect(ArchivedSessionSummary.sentenceCountText(0) == "0 sentences")
        #expect(ArchivedSessionSummary.sentenceCountText(1) == "1 sentence")
        #expect(ArchivedSessionSummary.sentenceCountText(2) == "2 sentences")
    }

    // MARK: - Language chips

    @Test("chip labels carry the badge code and the counts")
    func chipLabels() {
        let english = ArchiveLanguageCount(lang: "en", translated: 40)
        let chinese = ArchiveLanguageCount(lang: "zh-Hans", translated: 0)

        #expect(english.badgeCode == "EN")
        #expect(chinese.badgeCode == "ZH", "the badge is the uppercase primary subtag")
        #expect(english.chipText(of: 183) == "EN 40/183")
        #expect(chinese.chipText(of: 3) == "ZH 0/3")
    }

    @Test("completeness needs a non-empty session")
    func completeness() {
        #expect(ArchiveLanguageCount(lang: "en", translated: 0).isComplete(of: 0) == false)
        #expect(ArchiveLanguageCount(lang: "en", translated: 0).isComplete(of: 3) == false)
        #expect(ArchiveLanguageCount(lang: "en", translated: 3).isComplete(of: 3))
    }

    // MARK: - Auto title

    @Test("the auto-title snippet clips past 30 characters and collapses newlines")
    func autoTitleSnippet() {
        let thirty = String(repeating: "あ", count: 30)
        let thirtyOne = String(repeating: "あ", count: 31)

        #expect(summary(firstSentence: thirty).autoTitle.contains("「\(thirty)」"))
        #expect(
            summary(firstSentence: thirtyOne).autoTitle.contains("「\(thirty)…」"),
            "a 31st character clips to the limit plus an ellipsis"
        )
        #expect(
            summary(firstSentence: "こんにちは\n世界").autoTitle.contains("「こんにちは 世界」"),
            "a newline collapses to a space"
        )
    }
}
