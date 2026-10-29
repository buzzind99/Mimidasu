import Foundation

/// One archive session's language rules: the ordered counts, the sentence
/// total, the stored target, and the runtime target catalog. Every surface
/// that asks "how many are translated", "is this complete", "how many would
/// a run send", or "may I add a language" asks this value.
struct ArchiveLanguageSet: Equatable, Sendable {
    /// The stored language set in its canonical order: target first, then
    /// membership order, then translation-only languages.
    let counts: [ArchiveLanguageCount]
    let sentenceCount: Int
    let targetLang: String?
    /// The runtime OS catalog; empty until the probe lands.
    let targets: [TargetLanguage]
    let targetsLoaded: Bool

    init(
        summary: ArchivedSessionSummary,
        targets: [TargetLanguage] = [],
        targetsLoaded: Bool = false
    ) {
        counts = summary.langs
        sentenceCount = summary.sentenceCount
        targetLang = summary.targetLang
        self.targets = targets
        self.targetsLoaded = targetsLoaded
    }

    /// The count entry for `lang`, or nil when the language isn't held.
    func count(for lang: String) -> ArchiveLanguageCount? {
        counts.first { count in count.lang == lang }
    }

    /// The translated-sentence count for `lang`; 0 when the language isn't
    /// held.
    func translatedCount(for lang: String) -> Int {
        count(for: lang)?.translated ?? 0
    }

    /// True when `lang` has a translation on every sentence of a non-empty
    /// session.
    func isComplete(_ lang: String) -> Bool {
        sentenceCount > 0 && translatedCount(for: lang) >= sentenceCount
    }

    /// The sentences still missing a translation, never negative.
    func missingCount(_ lang: String) -> Int {
        max(sentenceCount - translatedCount(for: lang), 0)
    }

    /// The sentences a run for `lang` would send: the missing count for a
    /// partial language, or the full sentence count when the language is
    /// complete (a Re-translate re-sends every sentence).
    func sendCount(_ lang: String) -> Int {
        isComplete(lang) ? sentenceCount : missingCount(lang)
    }

    /// Targets the session does not hold, or nil while the OS catalog has not
    /// loaded. An empty array means "loaded, nothing to add".
    func addableTargets() -> [TargetLanguage]? {
        guard targetsLoaded else { return nil }
        let held = Set(counts.map(\.lang))
        var seen = Set<String>()
        return targets.filter { target in
            guard !held.contains(target.code) else { return false }
            return seen.insert(target.code).inserted
        }
    }

    /// The add affordance's single gate: false while loading and when there
    /// is nothing to add.
    var canAddLanguage: Bool {
        addableTargets()?.isEmpty == false
    }
}
