import Foundation
@testable import Mimidasu
import Testing

/// Tests the shared engine-tier vocabulary: the one table every provider
/// and tier name derives from, the tier-aware provider mapping, and the
/// guarantee that the engine kinds and the re-translate selections read the
/// same table instead of keeping parallel copies of it.
@MainActor
@Suite("Translation tier vocabulary")
struct TierVocabularyTests {

    // MARK: - The canonical table

    @Test("the canonical names are the vocabulary's only spellings")
    func canonicalNames() {
        #expect(TranslationTier.appleOnDevice.name == "Apple (NMT)")
        #expect(TranslationTier.appleHighFidelity.name == "Apple Intelligence")
        #expect(TranslationTier.google.name == "Google Translate")
        #expect(TranslationTier.deepL(.unknown).name == "DeepL")
        #expect(TranslationTier.deepL(.free).name == "DeepL (Free)")
        #expect(TranslationTier.deepL(.pro).name == "DeepL (Pro)")
        #expect(TranslationTier.openRouter.name == "OpenRouter")
    }

    @Test("every tier has a distinct name")
    func tierNamesAreDistinct() {
        let names = [
            TranslationTier.appleOnDevice.name,
            TranslationTier.appleHighFidelity.name,
            TranslationTier.google.name,
            TranslationTier.deepL(.unknown).name,
            TranslationTier.deepL(.free).name,
            TranslationTier.deepL(.pro).name,
            TranslationTier.openRouter.name
        ]

        #expect(Set(names).count == names.count)
    }

    // MARK: - Provider → tier

    @Test("the provider mapping picks the tier the facts describe")
    func providerTierMapping() {
        #expect(TranslationProvider.apple.tier() == .appleOnDevice)
        #expect(TranslationProvider.apple.tier(appleHighFidelity: true) == .appleHighFidelity)
        #expect(TranslationProvider.google.tier() == .google)
        #expect(TranslationProvider.openrouter.tier() == .openRouter)

        #expect(TranslationProvider.deepl.tier() == .deepL(.unknown))
        #expect(TranslationProvider.deepl.tier(deepLTier: .free) == .deepL(.free))
        #expect(TranslationProvider.deepl.tier(deepLTier: .pro) == .deepL(.pro))
    }

    @Test("the provider row names the DeepL tier only once it is known")
    func providerRowDeepLTier() {
        #expect(TranslationProvider.deepl.settingsName(deepLTier: .unknown) == "DeepL")
        #expect(TranslationProvider.deepl.settingsName(deepLTier: .free) == "DeepL (Free)")
        #expect(TranslationProvider.deepl.settingsName(deepLTier: .pro) == "DeepL (Pro)")
    }

    @Test("the provider row names the Apple tier the probe reported")
    func providerRowAppleTier() {
        #expect(TranslationProvider.apple.settingsName(deepLTier: .unknown) == "Apple (NMT)")
        #expect(
            TranslationProvider.apple.settingsName(deepLTier: .unknown, appleHighFidelity: true)
                == "Apple Intelligence"
        )
    }

    // MARK: - The DeepL tier fact

    @Test("the DeepL tier is unknown without a key and known with one")
    func deepLTierFollowsTheStoredKey() throws {
        let suiteName = "test.TierVocabulary.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        let settings = TranslationSettings(defaults: defaults, keys: InMemoryKeyStore())

        #expect(settings.deepLTier == .unknown)

        try settings.saveKey("abc123:fx", for: .deepl)
        #expect(settings.deepLTier == .free)

        try settings.saveKey("abc123", for: .deepl)
        #expect(settings.deepLTier == .pro)

        settings.removeKey(for: .deepl)
        #expect(settings.deepLTier == .unknown)
    }

    // MARK: - One table, two consumers

    @Test("the engine kinds and the re-translate selections read one table")
    func engineKindsAndSelectionsAgree() {
        #expect(TranslationEngineKind.appleFast.tier == .appleOnDevice)
        #expect(TranslationEngineKind.appleHighFidelity.tier == .appleHighFidelity)
        #expect(TranslationEngineKind.google.tier == .google)
        #expect(TranslationEngineKind.deepl.tier == .deepL(.unknown))
        #expect(TranslationEngineKind.openrouter.tier == .openRouter)

        #expect(RetranslateEngine.appleFast.displayName == TranslationEngineKind.appleFast.tier.name)
        #expect(
            RetranslateEngine.appleHighFidelity.displayName
                == TranslationEngineKind.appleHighFidelity.tier.name
        )
        #expect(RetranslateEngine.google.displayName == TranslationEngineKind.google.tier.name)
        #expect(RetranslateEngine.deepl.displayName == TranslationEngineKind.deepl.tier.name)
        #expect(RetranslateEngine.openrouter.displayName == TranslationEngineKind.openrouter.tier.name)
    }

    @Test("the marker suffix is the tier's canonical name")
    func markerNamesAreCanonical() {
        #expect(TranslationEngineKind.appleFast.markerName == "Apple (NMT)")
        #expect(TranslationEngineKind.appleHighFidelity.markerName == "Apple Intelligence")
        #expect(TranslationEngineKind.google.markerName == "Google Translate")
        #expect(TranslationEngineKind.deepl.markerName == "DeepL")
        #expect(TranslationEngineKind.openrouter.markerName == "OpenRouter")
    }
}
