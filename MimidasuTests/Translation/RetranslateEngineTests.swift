import Foundation
@testable import Mimidasu
import Testing

/// Tests the engine-identity types behind the re-translate lane: the
/// selection↔provider mapping, the canonical kind mapping, the marker
/// names, and the raw values that are load-bearing (persisted selection and
/// JSON export).
@Suite("Retranslate engine identity")
struct RetranslateEngineTests {

    @Test("raw values are stable — they are the persisted selection and the JSON export")
    func rawValuesAreStable() {
        #expect(RetranslateEngine.session.rawValue == "session")
        #expect(RetranslateEngine.appleFast.rawValue == "appleFast")
        #expect(RetranslateEngine.appleHighFidelity.rawValue == "appleHighFidelity")
        #expect(RetranslateEngine.google.rawValue == "google")
        #expect(RetranslateEngine.deepl.rawValue == "deepl")
        #expect(RetranslateEngine.openrouter.rawValue == "openrouter")
        #expect(RetranslateEngine.openai.rawValue == "openai")
        #expect(RetranslateEngine.anthropic.rawValue == "anthropic")
        #expect(RetranslateEngine.moonshot.rawValue == "moonshot")
        #expect(RetranslateEngine.zai.rawValue == "zai")
        #expect(RetranslateEngine.deepseek.rawValue == "deepseek")
        #expect(RetranslateEngine.xai.rawValue == "xai")

        #expect(TranslationEngineKind.appleHighFidelity.rawValue == "appleHighFidelity")
        #expect(TranslationEngineKind.appleFast.rawValue == "appleFast")
        #expect(TranslationEngineKind.google.rawValue == "google")
        #expect(TranslationEngineKind.deepl.rawValue == "deepl")
        #expect(TranslationEngineKind.openrouter.rawValue == "openrouter")
        #expect(TranslationEngineKind.openai.rawValue == "openai")
        #expect(TranslationEngineKind.anthropic.rawValue == "anthropic")
        #expect(TranslationEngineKind.moonshot.rawValue == "moonshot")
        #expect(TranslationEngineKind.zai.rawValue == "zai")
        #expect(TranslationEngineKind.deepseek.rawValue == "deepseek")
        #expect(TranslationEngineKind.xai.rawValue == "xai")
    }

    @Test("the on-device selections name no provider")
    func onDeviceSelectionsNameNoProvider() {
        #expect(RetranslateEngine.session.provider == nil)
        #expect(RetranslateEngine.appleFast.provider == nil)
        #expect(RetranslateEngine.appleHighFidelity.provider == nil)
    }

    @Test("external selections map to their provider and back")
    func externalSelectionsMapToProviders() {
        #expect(RetranslateEngine.google.provider == .google)
        #expect(RetranslateEngine.deepl.provider == .deepl)
        #expect(RetranslateEngine.openrouter.provider == .openrouter)
        #expect(RetranslateEngine.openai.provider == .openai)
        #expect(RetranslateEngine.anthropic.provider == .anthropic)
        #expect(RetranslateEngine.moonshot.provider == .moonshot)
        #expect(RetranslateEngine.zai.provider == .zai)
        #expect(RetranslateEngine.deepseek.provider == .deepseek)
        #expect(RetranslateEngine.xai.provider == .xai)

        #expect(RetranslateEngine(provider: .apple) == nil)
        #expect(RetranslateEngine(provider: .google) == .google)
        #expect(RetranslateEngine(provider: .deepl) == .deepl)
        #expect(RetranslateEngine(provider: .openrouter) == .openrouter)
        #expect(RetranslateEngine(provider: .openai) == .openai)
        #expect(RetranslateEngine(provider: .anthropic) == .anthropic)
        #expect(RetranslateEngine(provider: .moonshot) == .moonshot)
        #expect(RetranslateEngine(provider: .zai) == .zai)
        #expect(RetranslateEngine(provider: .deepseek) == .deepseek)
        #expect(RetranslateEngine(provider: .xai) == .xai)
    }

    @Test("kind mapping names no kind for Apple — the live Apple identity is probed")
    func kindMappingSkipsApple() {
        #expect(TranslationEngineKind(provider: .apple) == nil)
        #expect(TranslationEngineKind(provider: .google) == .google)
        #expect(TranslationEngineKind(provider: .deepl) == .deepl)
        #expect(TranslationEngineKind(provider: .openrouter) == .openrouter)
        #expect(TranslationEngineKind(provider: .openai) == .openai)
        #expect(TranslationEngineKind(provider: .anthropic) == .anthropic)
        #expect(TranslationEngineKind(provider: .moonshot) == .moonshot)
        #expect(TranslationEngineKind(provider: .zai) == .zai)
        #expect(TranslationEngineKind(provider: .deepseek) == .deepseek)
        #expect(TranslationEngineKind(provider: .xai) == .xai)
    }

    @Test("marker names match the labels shown on retried rows")
    func markerNamesMatchRowLabels() {
        #expect(TranslationEngineKind.appleHighFidelity.markerName == "Apple Intelligence")
        #expect(TranslationEngineKind.appleFast.markerName == "Apple (NMT)")
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

    @Test("engine display names match the picker labels")
    func displayNamesMatchPickerLabels() {
        #expect(RetranslateEngine.session.displayName == "Session engine")
        #expect(RetranslateEngine.appleFast.displayName == "Apple (NMT)")
        #expect(RetranslateEngine.appleHighFidelity.displayName == "Apple Intelligence")
        #expect(RetranslateEngine.google.displayName == "Google Translate")
        #expect(RetranslateEngine.deepl.displayName == "DeepL")
        #expect(RetranslateEngine.openrouter.displayName == "OpenRouter")
        #expect(RetranslateEngine.openai.displayName == "OpenAI")
        #expect(RetranslateEngine.anthropic.displayName == "Anthropic")
        #expect(RetranslateEngine.moonshot.displayName == "Moonshot")
        #expect(RetranslateEngine.zai.displayName == "Z.ai")
        #expect(RetranslateEngine.deepseek.displayName == "DeepSeek")
        #expect(RetranslateEngine.xai.displayName == "xAI")
    }

    @Test("the new re-translate selections name their engine kinds")
    func newSelectionsNameTheirKinds() {
        #expect(RetranslateEngine.openai.kind == .openai)
        #expect(RetranslateEngine.anthropic.kind == .anthropic)
        #expect(RetranslateEngine.moonshot.kind == .moonshot)
        #expect(RetranslateEngine.zai.kind == .zai)
        #expect(RetranslateEngine.deepseek.kind == .deepseek)
        #expect(RetranslateEngine.xai.kind == .xai)
    }

    @Test("the new engine kinds name their tiers")
    func newKindsNameTheirTiers() {
        #expect(TranslationEngineKind.openai.tier == .openAI)
        #expect(TranslationEngineKind.anthropic.tier == .anthropic)
        #expect(TranslationEngineKind.moonshot.tier == .moonshot)
        #expect(TranslationEngineKind.zai.tier == .zai)
        #expect(TranslationEngineKind.deepseek.tier == .deepSeek)
        #expect(TranslationEngineKind.xai.tier == .xAI)
    }

    @Test("disclosure intents identify themselves for the sheet and name their provider")
    func disclosureIntentsIdentifyThemselves() {
        #expect(PendingCloudDisclosure.providerSwitch(.deepl).id == "switch.deepl")
        #expect(PendingCloudDisclosure.retranslateEngine(.deepl).id == "retranslate.deepl")
        #expect(
            PendingCloudDisclosure.providerSwitch(.deepl).id
                != PendingCloudDisclosure.retranslateEngine(.deepl).id,
            "the two intents never collide as sheet identities"
        )

        #expect(PendingCloudDisclosure.providerSwitch(.openrouter).provider == .openrouter)
        #expect(PendingCloudDisclosure.retranslateEngine(.google).provider == .google)
    }
}
