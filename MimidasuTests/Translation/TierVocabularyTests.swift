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
        #expect(TranslationTier.openAI.name == "OpenAI")
        #expect(TranslationTier.anthropic.name == "Anthropic")
        #expect(TranslationTier.moonshot.name == "Moonshot")
        #expect(TranslationTier.zai.name == "Z.ai")
        #expect(TranslationTier.deepSeek.name == "DeepSeek")
        #expect(TranslationTier.xAI.name == "xAI")
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
            TranslationTier.openRouter.name,
            TranslationTier.openAI.name,
            TranslationTier.anthropic.name,
            TranslationTier.moonshot.name,
            TranslationTier.zai.name,
            TranslationTier.deepSeek.name,
            TranslationTier.xAI.name
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
        #expect(TranslationProvider.openai.tier() == .openAI)
        #expect(TranslationProvider.anthropic.tier() == .anthropic)
        #expect(TranslationProvider.moonshot.tier() == .moonshot)
        #expect(TranslationProvider.zai.tier() == .zai)
        #expect(TranslationProvider.deepseek.tier() == .deepSeek)
        #expect(TranslationProvider.xai.tier() == .xAI)

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
        #expect(TranslationEngineKind.openai.tier == .openAI)
        #expect(TranslationEngineKind.anthropic.tier == .anthropic)
        #expect(TranslationEngineKind.moonshot.tier == .moonshot)
        #expect(TranslationEngineKind.zai.tier == .zai)
        #expect(TranslationEngineKind.deepseek.tier == .deepSeek)
        #expect(TranslationEngineKind.xai.tier == .xAI)
    }

    @Test("the new re-translate selections name their tiers")
    func newRetranslateSelectionsNameTheirTiers() {
        #expect(RetranslateEngine.openai.displayName == "OpenAI")
        #expect(RetranslateEngine.anthropic.displayName == "Anthropic")
        #expect(RetranslateEngine.moonshot.displayName == "Moonshot")
        #expect(RetranslateEngine.zai.displayName == "Z.ai")
        #expect(RetranslateEngine.deepseek.displayName == "DeepSeek")
        #expect(RetranslateEngine.xai.displayName == "xAI")
    }

    @Test("an engine's name never wears a provider's subscription tier")
    func engineNamesCarryNoProviderTier() {
        // The DeepL subscription tier is a **provider** fact. Every engine
        // surface — the archive engine picker, the re-translate card, the
        // transcript marker — names the engine "DeepL"; only the provider
        // rows name the tier.
        #expect(RetranslateEngine.deepl.displayName == "DeepL")
        #expect(TranslationEngineKind.deepl.markerName == "DeepL")
        #expect(TranslationProvider.deepl.settingsName(deepLTier: .pro) == "DeepL (Pro)")
    }

    @Test("the marker suffix is the tier's canonical name")
    func markerNamesAreCanonical() {
        #expect(TranslationEngineKind.appleFast.markerName == "Apple (NMT)")
        #expect(TranslationEngineKind.appleHighFidelity.markerName == "Apple Intelligence")
        #expect(TranslationEngineKind.google.markerName == "Google Translate")
        #expect(TranslationEngineKind.deepl.markerName == "DeepL")
        #expect(TranslationEngineKind.openrouter.markerName == "OpenRouter")
        #expect(TranslationEngineKind.openai.markerName == "OpenAI")
        #expect(TranslationEngineKind.anthropic.markerName == "Anthropic")
        #expect(TranslationEngineKind.moonshot.markerName == "Moonshot")
        #expect(TranslationEngineKind.zai.markerName == "Z.ai")
        #expect(TranslationEngineKind.deepseek.markerName == "DeepSeek")
        #expect(TranslationEngineKind.xai.markerName == "xAI")
    }
}
