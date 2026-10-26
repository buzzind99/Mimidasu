import Foundation
@testable import Mimidasu
import Testing

private let canonicalTierNames: [(tier: TranslationTier, name: String)] = [
    (.appleOnDevice, "Apple (NMT)"),
    (.appleHighFidelity, "Apple Intelligence"),
    (.google, "Google Translate"),
    (.deepL(.unknown), "DeepL"),
    (.deepL(.free), "DeepL (Free)"),
    (.deepL(.pro), "DeepL (Pro)"),
    (.openRouter, "OpenRouter"),
    (.openAI, "OpenAI"),
    (.anthropic, "Anthropic"),
    (.moonshot, "Moonshot"),
    (.zai, "Z.ai"),
    (.deepSeek, "DeepSeek"),
    (.xAI, "xAI")
]

struct EngineSurface: Sendable {
    let kind: TranslationEngineKind
    let selection: RetranslateEngine
    let name: String
}

private let engineSurfaceNames: [EngineSurface] = [
    EngineSurface(kind: .appleFast, selection: .appleFast, name: "Apple (NMT)"),
    EngineSurface(kind: .appleHighFidelity, selection: .appleHighFidelity, name: "Apple Intelligence"),
    EngineSurface(kind: .google, selection: .google, name: "Google Translate"),
    EngineSurface(kind: .deepl, selection: .deepl, name: "DeepL"),
    EngineSurface(kind: .openrouter, selection: .openrouter, name: "OpenRouter"),
    EngineSurface(kind: .openai, selection: .openai, name: "OpenAI"),
    EngineSurface(kind: .anthropic, selection: .anthropic, name: "Anthropic"),
    EngineSurface(kind: .moonshot, selection: .moonshot, name: "Moonshot"),
    EngineSurface(kind: .zai, selection: .zai, name: "Z.ai"),
    EngineSurface(kind: .deepseek, selection: .deepseek, name: "DeepSeek"),
    EngineSurface(kind: .xai, selection: .xai, name: "xAI")
]

/// Tests the shared engine-tier vocabulary: the one table every provider
/// and tier name derives from, the tier-aware provider mapping, and the
/// guarantee that the engine kinds and the re-translate selections read the
/// same table instead of keeping parallel copies of it.
@MainActor
@Suite("Translation tier vocabulary")
struct TierVocabularyTests {

    // MARK: - The canonical table

    @Test("the canonical names are the vocabulary's only spellings", arguments: canonicalTierNames)
    func canonicalNames(tier: TranslationTier, name: String) {
        #expect(tier.name == name)
    }

    @Test("every tier has a distinct name")
    func tierNamesAreDistinct() {
        let names = canonicalTierNames.map(\.name)
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

    @Test("markers and re-translate selections read the tier's canonical name", arguments: engineSurfaceNames)
    func engineSurfacesReadTheCanonicalName(surface: EngineSurface) {
        #expect(surface.kind.markerName == surface.name)
        #expect(surface.selection.displayName == surface.name)
    }
}
