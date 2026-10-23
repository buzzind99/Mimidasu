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

    /// The date text the auto-title is expected to carry: the localized
    /// month + day, plus the localized year when outside the current year.
    private func expectedDateText(of date: Date) -> String {
        let style: Date.FormatStyle =
            if Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year) {
                .dateTime.month(.abbreviated).day()
            } else {
                .dateTime.month(.abbreviated).day().year()
            }
        return date.formatted(style)
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

    // MARK: - Row title and excerpt

    @Test("the row title is the trimmed user name when the session is renamed")
    func rowTitleUsesTheUserName() {
        let sut = makeSummary(name: "  Evening study  ", firstSentence: "こんにちは")

        #expect(sut.rowTitle == "Evening study")
        #expect(sut.hasUserName)
    }

    @Test("an unnamed row title is the bracketed first sentence")
    func rowTitleUsesTheQuotedFirstSentence() {
        let sut = makeSummary(firstSentence: "こんにちは")

        #expect(sut.rowTitle == "「こんにちは」")
        #expect(!sut.hasUserName)
    }

    @Test("a nameless session without a first sentence falls back to a placeholder")
    func rowTitleFallsBackToPlaceholder() {
        #expect(makeSummary(firstSentence: nil).rowTitle == "Untitled session")
        #expect(makeSummary(firstSentence: "  \n ").rowTitle == "Untitled session")
    }

    @Test("the excerpt is shown only under a renamed session")
    func rowExcerptOnlyForNamedSessions() {
        #expect(
            makeSummary(name: "Evening study", firstSentence: "こんにちは").rowExcerpt
                == "「こんにちは」"
        )
        #expect(makeSummary(firstSentence: "こんにちは").rowExcerpt == nil)
        #expect(makeSummary(name: "Evening study", firstSentence: nil).rowExcerpt == nil)
    }

    @Test("the row title collapses every newline form")
    func rowTitleCollapsesNewlines() {
        #expect(makeSummary(firstSentence: "こんにちは\r\n世界").rowTitle == "「こんにちは 世界」")
    }

    // MARK: - Row meta line (time first)

    @Test("the row meta line starts with the time and omits the date")
    func rowMetaLineUsesTimeNotDate() {
        let startedAt = fixedDate
        let sut = makeSummary(durationS: 90, startedAt: startedAt, sentenceCount: 3)

        let line = sut.rowMetaLine

        #expect(line == "\(expectedTime(of: startedAt)) · 1:30 · 3 sentences")
        #expect(!line.contains(ArchivedSessionSummary.dateTimeText(startedAt)))
    }

    @Test("the row meta line omits an unknown duration")
    func rowMetaLineWithoutDuration() {
        let startedAt = fixedDate
        let sut = makeSummary(durationS: nil, startedAt: startedAt, sentenceCount: 3)

        #expect(sut.rowMetaLine == "\(expectedTime(of: startedAt)) · 3 sentences")
    }

    // MARK: - Auto title

    @Test("the auto-title falls back to the date when the session has no first sentence")
    func autoTitleWithoutFirstSentence() {
        let startedAt = fixedDate
        let sut = makeSummary(startedAt: startedAt, firstSentence: nil)

        let title = sut.autoTitle

        #expect(title == expectedDateText(of: startedAt))
        #expect(!title.contains("「"), "the fallback carries no first-sentence snippet")
    }

    @Test("the auto-title falls back to the date when the first sentence is blank")
    func autoTitleWithBlankFirstSentence() {
        let startedAt = fixedDate
        let sut = makeSummary(startedAt: startedAt, firstSentence: "")

        let title = sut.autoTitle

        #expect(title == expectedDateText(of: startedAt))
        #expect(!title.contains("「"), "a blank first sentence is no snippet")
    }

    @Test("the auto-title falls back to the date when the first sentence is only whitespace")
    func autoTitleWithWhitespaceOnlyFirstSentence() {
        let startedAt = fixedDate
        let sut = makeSummary(startedAt: startedAt, firstSentence: "  \n ")

        #expect(sut.autoTitle == expectedDateText(of: startedAt))
    }

    @Test("a same-year auto-title fallback omits the year")
    func autoTitleSameYearFallbackOmitsYear() throws {
        let date = try #require(sameYearDate())
        let sut = makeSummary(startedAt: date, firstSentence: nil)

        #expect(sut.autoTitle == date.formatted(.dateTime.month(.abbreviated).day()))
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

    @Test("a same-year session omits the year in its stamp")
    func dateTimeTextOmitsYearWhenCurrentYear() throws {
        let date = try #require(sameYearDate())
        let year = Calendar.current.component(.year, from: date)
        let monthDay = date.formatted(.dateTime.month(.abbreviated).day())

        let stamp = ArchivedSessionSummary.dateTimeText(date)

        #expect(stamp.hasPrefix(monthDay))
        #expect(!stamp.contains(", \(year)"))
        #expect(!stamp.contains("Today"))
        #expect(stamp.hasSuffix(" · \(expectedTime(of: date))"))
    }

    @Test("a prior-year session carries its year in its stamp")
    func dateTimeTextIncludesYearWhenPriorYear() throws {
        let date = try #require(priorYearDate())
        let localDate = date.formatted(.dateTime.month(.abbreviated).day().year())

        let stamp = ArchivedSessionSummary.dateTimeText(date)

        #expect(stamp == "\(localDate) · \(expectedTime(of: date))")
    }

    @Test("the date rail kicker is TODAY for today's session")
    func rowDateLabelForToday() {
        #expect(makeSummary(startedAt: Date()).rowDateLabel == "TODAY")
    }

    @Test("the date rail kicker omits the year in the current year")
    func rowDateLabelOmitsYearWhenCurrentYear() throws {
        let date = try #require(sameYearDate())
        let month = date.formatted(.dateTime.month(.abbreviated)).uppercased()

        #expect(makeSummary(startedAt: date).rowDateLabel == month)
    }

    @Test("the date rail kicker carries a short year outside the current year")
    func rowDateLabelIncludesShortYearWhenPriorYear() throws {
        let date = try #require(priorYearDate())
        let month = date.formatted(.dateTime.month(.abbreviated)).uppercased()
        let shortYear = String(format: "’%02d", Calendar.current.component(.year, from: date) % 100)

        #expect(makeSummary(startedAt: date).rowDateLabel == "\(month) \(shortYear)".uppercased())
    }

    @Test("the auto-title carries the year for a prior-year session")
    func autoTitleIncludesYearWhenPriorYear() throws {
        let date = try #require(priorYearDate())
        let localDate = date.formatted(.dateTime.month(.abbreviated).day().year())

        let title = makeSummary(startedAt: date, firstSentence: "こんにちは").autoTitle

        #expect(title.hasPrefix(localDate))
        #expect(title.contains("「こんにちは」"))
    }

    /// A mid-year date in the current year that is never today, so the
    /// same-year branch is exercised deterministically.
    private func sameYearDate() -> Date? {
        let currentYear = Calendar.current.component(.year, from: Date())
        let todayMonth = Calendar.current.component(.month, from: Date())
        let todayDay = Calendar.current.component(.day, from: Date())
        var month = 6, day = 15
        if todayMonth == month, todayDay == day {
            month = 7
        }
        var components = DateComponents()
        components.year = currentYear
        components.month = month
        components.day = day
        components.hour = 9
        components.minute = 11
        return Calendar.current.date(from: components)
    }

    /// The same month and day one year earlier — the Oct 14 2026 vs Oct 14
    /// 2025 collision the year suffix exists to disambiguate.
    private func priorYearDate() -> Date? {
        guard let base = sameYearDate() else { return nil }
        return Calendar.current.date(byAdding: .year, value: -1, to: base)
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

    // MARK: - Banner character tally

    @Test("the character count sums the sentence text")
    func characterCountSumsTheSentenceText() {
        let session = ArchivedSession(
            summary: makeSummary(sentenceCount: 2),
            entries: [
                makeEntry(index: 0, text: "あい"),
                makeEntry(index: 1, text: "う")
            ]
        )

        #expect(session.characterCount == 3)
    }
}
