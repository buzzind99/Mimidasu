import Foundation
@testable import Mimidasu
import Testing

/// Pins the archive models' display-formatting surface that the list rows
/// and the opened banner read: the badge fallback, the chip's identity, the
/// default viewing language, the auto-title fallback, the row meta line, the
/// sentence-count and duration text, the date/time stamps, and the banner's
/// character tally.
@Suite("Archive models formatting")
struct ArchiveModelsFormattingTests {

    // MARK: - Helpers

    private let fixedDate = Date(timeIntervalSince1970: 1_000_000)

    private func makeSummary(
        durationS: Int? = 90,
        targetLang: String? = "en",
        startedAt: Date? = nil,
        name: String? = nil,
        firstSentence: String? = nil,
        sentenceCount: Int = 3
    ) -> ArchivedSessionSummary {
        ArchivedSessionSummary(
            id: 1,
            status: .complete,
            saved: false,
            startedAt: startedAt ?? fixedDate,
            durationS: durationS,
            pausedMS: 0,
            sentenceCount: sentenceCount,
            targetLang: targetLang,
            model: "test-model",
            chunkMS: 160,
            name: name,
            firstSentence: firstSentence
        )
    }

    private func makeEntry(index: Int, text: String) -> SessionEntry {
        SessionEntry(
            sentence: Sentence(index: index, startS: 0, endS: 1, lang: "ja", text: text)
        )
    }

    /// The wall-clock time the production stamp is expected to carry, built
    /// independently of the code under test.
    private func expectedTime(of date: Date) -> String {
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", components.hour ?? 0, components.minute ?? 0)
    }

    // MARK: - Badge and chip identity

    @Test("an empty language code yields an empty badge")
    func badgeCodeForEmptyCode() {
        #expect(LanguageBadge.code(for: "") == "")
    }

    @Test("a language chip is identified by its language code")
    func languageCountIdentity() {
        let count = ArchiveLanguageCount(lang: "zh-Hans", translated: 3)

        #expect(count.id == "zh-Hans")
    }

    // MARK: - Default viewing language

    @Test("the default viewing language is the session's target language")
    func defaultViewingLang() {
        #expect(makeSummary(targetLang: "ja").defaultViewingLang == "ja")
    }

    @Test("a session without a target language has no default viewing language")
    func defaultViewingLangIsAbsent() {
        #expect(makeSummary(targetLang: nil).defaultViewingLang == nil)
    }

    // MARK: - Display title

    @Test("the display title is the user's name when the session is renamed")
    func displayTitleUsesTheUserName() {
        let sut = makeSummary(name: "  Evening study  ")

        let title = sut.displayTitle

        #expect(title == "Evening study", "the user's name is trimmed")
    }

    @Test("the display title falls back to the auto-title when the session has no name")
    func displayTitleFallsBackToAutoTitle() {
        let sut = makeSummary(name: nil, firstSentence: "こんにちは")

        let title = sut.displayTitle

        #expect(title == sut.autoTitle)
        #expect(title.contains("「こんにちは」"), "the fallback carries the first-sentence snippet")
    }

    // MARK: - Auto title

    @Test("the auto-title falls back to the date when the session has no first sentence")
    func autoTitleWithoutFirstSentence() {
        let startedAt = fixedDate
        let sut = makeSummary(startedAt: startedAt, firstSentence: nil)

        let title = sut.autoTitle

        #expect(title == startedAt.formatted(.dateTime.month(.abbreviated).day()))
        #expect(!title.contains("「"), "the fallback carries no first-sentence snippet")
    }

    @Test("the auto-title falls back to the date when the first sentence is blank")
    func autoTitleWithBlankFirstSentence() {
        let startedAt = fixedDate
        let sut = makeSummary(startedAt: startedAt, firstSentence: "")

        let title = sut.autoTitle

        #expect(title == startedAt.formatted(.dateTime.month(.abbreviated).day()))
        #expect(!title.contains("「"), "a blank first sentence is no snippet")
    }

    // MARK: - Row meta line

    @Test("the row meta line reads date, duration, and sentence count")
    func metaLineWithDuration() {
        let startedAt = fixedDate
        let sut = makeSummary(durationS: 90, startedAt: startedAt, sentenceCount: 3)

        let line = sut.metaLine

        #expect(line == "\(ArchivedSessionSummary.dateTimeText(startedAt)) · 1:30 · 3 sentences")
        #expect(line.contains("1:30"))
        #expect(line.contains("3 sentences"))
    }

    @Test("the row meta line omits the duration when the duration is unknown")
    func metaLineWithoutDuration() {
        let startedAt = fixedDate
        let sut = makeSummary(durationS: nil, startedAt: startedAt, sentenceCount: 3)

        let line = sut.metaLine

        #expect(line == "\(ArchivedSessionSummary.dateTimeText(startedAt)) · 3 sentences")
        #expect(!line.contains("1:30"))
    }

    // MARK: - Sentence count and duration text

    @Test("the sentence-count text is singular for a single sentence")
    func sentenceCountTextIsSingular() {
        #expect(makeSummary(sentenceCount: 1).sentenceCountText == "1 sentence")
    }

    @Test("the sentence-count text is plural for several sentences")
    func sentenceCountTextIsPlural() {
        #expect(makeSummary(sentenceCount: 3).sentenceCountText == "3 sentences")
    }

    @Test("the duration text reads minutes and seconds")
    func durationTextIsFormatted() {
        #expect(makeSummary(durationS: 90).durationText == "1:30")
    }

    @Test("the duration text is absent when the duration is unknown")
    func durationTextIsAbsent() {
        #expect(makeSummary(durationS: nil).durationText == nil)
    }

    // MARK: - Date and time stamps

    @Test("a session started today is stamped as today")
    func dateTimeTextForToday() throws {
        var components = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        components.hour = 12
        components.minute = 0
        let noon = try #require(Calendar.current.date(from: components))

        let stamp = ArchivedSessionSummary.dateTimeText(noon)

        #expect(stamp == "Today · 12:00")
        #expect(stamp.hasPrefix("Today · "))
    }

    @Test("a session started on an earlier day is stamped with its month and day")
    func dateTimeTextForEarlierDay() throws {
        let earlier = try #require(Calendar.current.date(byAdding: .day, value: -3, to: Date()))

        let stamp = ArchivedSessionSummary.dateTimeText(earlier)

        #expect(stamp.hasPrefix(earlier.formatted(.dateTime.month(.abbreviated).day())))
        #expect(stamp.hasSuffix(" · \(expectedTime(of: earlier))"))
        #expect(!stamp.contains("Today"))
    }

    @Test("the time text reads a fixed 24-hour clock")
    func timeTextIsFixedClock() throws {
        var components = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        components.year = 2024
        components.month = 1
        components.day = 15
        components.hour = 9
        components.minute = 5
        let date = try #require(Calendar.current.date(from: components))

        #expect(ArchivedSessionSummary.timeText(date) == "09:05")
    }

    // MARK: - Banner meta line

    @Test("the banner meta line counts a single character in the singular")
    func sessionMetaLineForOneCharacter() {
        let summary = makeSummary(durationS: 90, sentenceCount: 1)
        let session = ArchivedSession(
            summary: summary,
            entries: [makeEntry(index: 0, text: "あ")]
        )

        let line = session.metaLine

        #expect(session.characterCount == 1)
        #expect(line == "\(summary.metaLine) · 1 character")
    }

    @Test("the banner meta line counts several characters in the plural")
    func sessionMetaLineForSeveralCharacters() {
        let summary = makeSummary(durationS: 90, sentenceCount: 2)
        let session = ArchivedSession(
            summary: summary,
            entries: [makeEntry(index: 0, text: "あ"), makeEntry(index: 1, text: "い")]
        )

        let line = session.metaLine

        #expect(session.characterCount == 2)
        #expect(line == "\(summary.metaLine) · 2 characters")
    }
}
