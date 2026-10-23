import Foundation

/// Stored session lifecycle status (`sessions.status`).
enum ArchiveStatus: String, Sendable {
    /// A session still running, or one abandoned by an unclean exit until
    /// the launch sweep flips it. Never listed.
    case recording
    /// A session finalized by a stop.
    case complete
    /// A `recording` row recovered on launch after an unclean exit; behaves
    /// like any other recent, shown with an "Interrupted" badge.
    case interrupted
}

/// The uppercase primary subtag of a language code — the badge an archive
/// chip and the target-language picker show ("en" → "EN", "zh-Hans" → "ZH").
///
/// The raw code, never a `TargetLanguage`: an unknown code falls back to
/// English there, and a badge reading "EN" for an unknown language would
/// name the wrong one.
enum LanguageBadge {
    static func code(for rawCode: String) -> String {
        guard let primary = rawCode.split(separator: "-").first else {
            return rawCode.uppercased()
        }
        return primary.uppercased()
    }
}

/// One language an archive holds with its translated-sentence count — the
/// data behind a language chip (`FR 40/183`, badge = uppercase primary
/// subtag). Membership languages with nothing translated yet appear at
/// `0/N`; `N` is the summary's sentence count.
struct ArchiveLanguageCount: Equatable, Sendable, Identifiable {
    let lang: String
    let translated: Int

    var id: String {
        lang
    }

    /// Uppercase primary subtag for the chip badge ("en" → "EN",
    /// "zh-Hans" → "ZH"), matching the target-language picker's rows.
    var badgeCode: String {
        LanguageBadge.code(for: lang)
    }

    /// The chip label for a session of `total` sentences: `FR 40/183`.
    func chipText(of total: Int) -> String {
        "\(badgeCode) \(translated)/\(total)"
    }

    /// The chip's VoiceOver text: the counts, plus the "translating" note
    /// while a bulk run claims this language.
    func accessibilityText(of total: Int, busy: Bool) -> String {
        let chip = chipText(of: total)
        return busy ? "\(chip), translating" : chip
    }

    /// True when this language's chip reads as complete (`N/N` with a
    /// non-empty session) — the engine picker's Retranslate mode.
    func isComplete(of total: Int) -> Bool {
        total > 0 && translated >= total
    }
}

/// A stored session's list-row summary — everything the archive window and
/// the opened banner need without loading sentences.
struct ArchivedSessionSummary: Identifiable, Equatable, Sendable {
    let id: Int64
    let status: ArchiveStatus
    /// Whether the user promoted the session to the permanent tier. Mutable:
    /// a promote while the session is open updates the banner in place.
    var saved: Bool
    let startedAt: Date
    /// Active duration in seconds, pause-excluded; nil while unknown
    /// (a recovered interruption that never recorded a duration).
    let durationS: Int?
    /// Accumulated paused time in milliseconds (excluded from `durationS`).
    let pausedMS: Int
    let sentenceCount: Int
    let targetLang: String?
    let model: String?
    let chunkMS: Int?
    /// The user-editable name; nil = display the auto-title. Mutable: a
    /// rename while the session is open updates the banner in place.
    var name: String?
    /// The first sentence's text, for the auto-title snippet.
    let firstSentence: String?
    /// Every language the archive holds with its translated count, in the
    /// language set's order: stored target first, then membership order,
    /// then translation-only languages. Mutable: a landed bulk-job result
    /// refreshes the counts in place on the opened banner.
    var langs: [ArchiveLanguageCount] = []

    /// The count entry for `lang`, or nil when the language isn't held.
    func languageCount(for lang: String) -> ArchiveLanguageCount? {
        langs.first { count in count.lang == lang }
    }

    /// True when the session already holds every language the app can
    /// target — the add-language affordance has nothing left to offer.
    var holdsEveryTargetLanguage: Bool {
        let held = Set(langs.map(\.lang))
        return TargetLanguage.known.allSatisfy { known in held.contains(known.code) }
    }

    /// The language the pane shows when nothing overrides it.
    var defaultViewingLang: String? {
        targetLang
    }
}

/// A stored session opened read-only into the transcript pane: its summary
/// plus the reconstructed rows.
struct ArchivedSession: Identifiable, Equatable, Sendable {
    var summary: ArchivedSessionSummary
    let entries: [SessionEntry]

    var id: Int64 {
        summary.id
    }

    /// Σ sentence text lengths (translations excluded) — the banner's
    /// CHARACTERS stat.
    var characterCount: Int {
        entries.reduce(0) { total, entry in total + entry.sentence.text.count }
    }
}

// MARK: - Display formatting

extension ArchivedSessionSummary {
    /// The user's name without surrounding whitespace; empty when the
    /// session has no usable name.
    private var trimmedName: String {
        (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The label the language popover shows: the user's name when set, else
    /// the auto-title.
    var displayTitle: String {
        trimmedName.isEmpty ? autoTitle : trimmedName
    }

    /// Date + first-sentence snippet, for a session that was never renamed.
    var autoTitle: String {
        guard let quoted = quotedFirstSentence else { return dateText }
        return "\(dateText) · \(quoted)"
    }

    /// Whether the user gave the session a non-blank name.
    var hasUserName: Bool {
        !trimmedName.isEmpty
    }

    /// The archive row and opened banner title: the user's name, else the
    /// first sentence as a bracketed snippet, else a placeholder.
    var rowTitle: String {
        if !trimmedName.isEmpty {
            return trimmedName
        }
        return quotedFirstSentence ?? "Untitled session"
    }

    /// The first sentence as a bracketed snippet, or nil when the session has
    /// no readable first sentence.
    var quotedFirstSentence: String? {
        guard let firstSentence else { return nil }
        let snippet = Self.snippet(firstSentence)
        guard !snippet.isEmpty else { return nil }
        return "「\(snippet)」"
    }

    /// The excerpt under a renamed row: the first sentence, or nil for an
    /// unnamed session (its title already is that sentence).
    var rowExcerpt: String? {
        guard hasUserName else { return nil }
        return quotedFirstSentence
    }

    /// The archive row's meta line: time, duration, and sentence count. The
    /// date lives in the row's date rail.
    var rowMetaLine: String {
        var parts = [Self.timeText(startedAt)]
        if let durationText {
            parts.append(durationText)
        }
        parts.append(sentenceCountText)
        return parts.joined(separator: " · ")
    }

    var sentenceCountText: String {
        Self.sentenceCountText(sentenceCount)
    }

    /// The shared phrasing for a sentence count ("1 sentence" / "3
    /// sentences"), reused by copy that reports a scope's sentence total.
    static func sentenceCountText(_ count: Int) -> String {
        count == 1 ? "1 sentence" : "\(count) sentences"
    }

    /// Active duration as `h:mm:ss` (or `m:ss`), matching the SESSION
    /// card's formatting; nil when the duration is unknown.
    var durationText: String? {
        guard let durationS else { return nil }
        return Self.durationText(seconds: durationS)
    }

    /// Localized month + day, plus the localized year when the session is
    /// not from the current year. Same-year sessions keep the compact form.
    private var dateText: String {
        Self.monthDayYear(startedAt)
    }

    /// The date rail's kicker: "TODAY" for today's session, else the
    /// uppercased abbreviated month ("OCT"), plus a short year (" ’25")
    /// when the session is not from the current year. Only "TODAY" ever
    /// uses the accent color — an old year stays in the neutral style.
    var rowDateLabel: String {
        if Calendar.current.isDateInToday(startedAt) {
            return "TODAY"
        }
        let month = startedAt.formatted(.dateTime.month(.abbreviated)).uppercased()
        guard !Self.isCurrentYear(startedAt) else { return month }
        return month + Self.shortYearSuffix(startedAt)
    }

    /// True when `date` falls in the current calendar year.
    static func isCurrentYear(_ date: Date) -> Bool {
        Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year)
    }

    /// The two-digit year suffix for the date rail (" ’25"), from the
    /// current calendar.
    private static func shortYearSuffix(_ date: Date) -> String {
        let year = Calendar.current.component(.year, from: date)
        return String(format: " ’%02d", year % 100)
    }

    /// The localized month/day, with the localized year when `date` is
    /// outside the current year.
    private static func monthDayYear(_ date: Date) -> String {
        let style: Date.FormatStyle = if isCurrentYear(date) {
            .dateTime.month(.abbreviated).day()
        } else {
            .dateTime.month(.abbreviated).day().year()
        }
        return date.formatted(style)
    }

    /// "Today · 14:32", "Oct 14 · 09:11", or "Oct 14, 2025 · 09:11" when
    /// the date is not from the current year. Fixed 24-hour clock, matching
    /// the app's timestamp columns rather than the locale's AM/PM habit.
    static func dateTimeText(_ date: Date) -> String {
        let day: String = if Calendar.current.isDateInToday(date) {
            "Today"
        } else {
            monthDayYear(date)
        }
        return "\(day) · \(timeText(date))"
    }

    static func timeText(_ date: Date) -> String {
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", components.hour ?? 0, components.minute ?? 0)
    }

    static func durationText(seconds: Int) -> String {
        let h = seconds / 3600, m = seconds / 60 % 60, s = seconds % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// First sentence collapsed and clipped for the auto-title.
    private static func snippet(_ text: String) -> String {
        let collapsed = collapsedText(text)
        guard collapsed.count > snippetLimit else { return collapsed }
        return collapsed.prefix(snippetLimit) + "…"
    }

    /// Collapses every newline form to one space and trims the edges.
    private static func collapsedText(_ text: String) -> String {
        text.split(whereSeparator: { character in character.isNewline })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let snippetLimit = 30
}
