import Foundation
import Translation

/// Runtime discovery of the translation-target catalog: probes Apple's
/// Translation framework for every language this OS supports, drops the
/// fixed `ja` source, normalizes regional variants, keeps only entries with
/// metadata, and orders the picker alphabetically by localized display name.
/// The OS-dependent set is the app's only source of truth — no
/// static language list ships in the picker.
@MainActor
@Observable
final class AppleTranslationAvailability {
    /// Picker rows; empty until the first `refresh` lands.
    private(set) var targets: [TargetLanguage] = []
    /// True once the probe has landed (the picker shows a placeholder before).
    private(set) var isLoaded = false

    private let probe: @Sendable () async -> [Locale.Language]

    /// - Parameters:
    ///   - probe: injectable for tests; the default drives the real
    ///     `LanguageAvailability.supportedLanguages` getter.
    init(probe: @escaping @Sendable () async -> [Locale.Language] = {
        await LanguageAvailability().supportedLanguages
    }) {
        self.probe = probe
    }

    /// Re-probes the OS and rebuilds `targets`. Cheap enough to run on every
    /// Settings open.
    func refresh() async {
        targets = await Self.normalize(probe())
        isLoaded = true
    }

    /// Refreshes only when nothing has been loaded yet — the reopen path of
    /// a cached Settings window skips the redundant probe.
    func refreshIfNeeded() async {
        guard !isLoaded else { return }
        await refresh()
    }

    /// `ja` (the fixed source) is dropped; regional variants collapse onto
    /// their base entry (`en-US` → `en`, `zh-Hans-CN` → `zh-Hans`); codes
    /// with no metadata entry fall away. The catalog sorts alphabetically
    /// by localized display name (A first); duplicates from the variant
    /// collapse are removed.
    static func normalize(_ languages: [Locale.Language]) -> [TargetLanguage] {
        var picked: [TargetLanguage] = []
        for language in languages {
            guard let languageCode = language.languageCode?.identifier, languageCode != "ja",
                  let target = match(languageCode: languageCode, script: language.script?.identifier),
                  !picked.contains(target)
            else { continue }
            picked.append(target)
        }
        return picked.sorted { first, second in first.displayName < second.displayName }
    }

    /// Matches a probed language against the metadata table. `Locale.Language`
    /// materializes a script even for bare codes ("en" → Latn, "zh" → Hans),
    /// so the explicit "language-script" pair is tried first — that's what
    /// keeps `zh-Hans` and `zh-Hant` distinct — and the bare language code
    /// second, which is what makes regional variants (`en-US`, `pt-BR`)
    /// collapse onto their base entry.
    private static func match(languageCode: String, script: String?) -> TargetLanguage? {
        if let script {
            let scripted = TargetLanguage.known.first { known in
                known.code == "\(languageCode)-\(script)"
            }
            if let scripted {
                return scripted
            }
        }
        return TargetLanguage.known.first { known in
            known.code == languageCode
        }
    }
}
