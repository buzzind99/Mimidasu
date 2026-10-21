import Foundation
@testable import Mimidasu
import Testing

/// The Settings "Currently using" row's description: which engine the app
/// names, and — for the cloud providers — which subscription tier it is
/// standing on.
///
/// The DeepL tier is a **provider** fact: it is unknown while no key is
/// stored, so the row must never claim a tier the app cannot know. And the
/// base label follows the *attached* engine, not the picker, so the row never
/// names an engine that is not running.
@MainActor
@Suite("Translation settings — engine description")
struct TranslationSettingsDescriptionTests {

    private func makeSUT() -> TranslationSettings {
        let suiteName = "test.TranslationSettingsDescription.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        return TranslationSettings(defaults: defaults, keys: InMemoryKeyStore())
    }

    @Test("the DeepL description names the subscription tier only once a key is stored")
    func deeplDescriptionNamesTheTierOnlyWithAKey() throws {
        let settings = makeSUT()
        let target = TargetLanguage.english.displayName

        // No key: the tier is unknown, and the row must not claim one.
        settings.select(.deepl)
        #expect(settings.activeEngineDescription(fallbackActive: false) == "DeepL → \(target)")

        try settings.saveKey("abc123", for: .deepl)
        #expect(settings.activeEngineDescription(fallbackActive: false) == "DeepL (Pro) → \(target)")

        try settings.saveKey("abc123:fx", for: .deepl)
        #expect(settings.activeEngineDescription(fallbackActive: false) == "DeepL (Free) → \(target)")

        settings.removeKey(for: .deepl)
        #expect(
            settings.activeEngineDescription(fallbackActive: false) == "Apple (NMT) → \(target)",
            "removing the selected provider's key falls the selection back to Apple"
        )
    }

    @Test("the description names the attached engine, not the picker")
    func descriptionPrefersTheAttachedProvider() throws {
        let settings = makeSUT()
        let target = TargetLanguage.english.displayName
        try settings.saveKey("sk-google", for: .google)

        // The picker says Google; the running engine is DeepL (attached).
        settings.select(.google)
        #expect(settings.activeEngineDescription(fallbackActive: false) == "Google Translate → \(target)")
        #expect(
            settings.activeEngineDescription(fallbackActive: false, attachedProvider: .deepl)
                == "DeepL → \(target)",
            "the attached engine wins over the picker — the row must not name an engine that is not running"
        )
    }
}
