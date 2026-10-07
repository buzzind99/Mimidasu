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

        #expect(TranslationEngineKind.appleHighFidelity.rawValue == "appleHighFidelity")
        #expect(TranslationEngineKind.appleFast.rawValue == "appleFast")
        #expect(TranslationEngineKind.google.rawValue == "google")
        #expect(TranslationEngineKind.deepl.rawValue == "deepl")
        #expect(TranslationEngineKind.openrouter.rawValue == "openrouter")
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

        #expect(RetranslateEngine(provider: .apple) == nil)
        #expect(RetranslateEngine(provider: .google) == .google)
        #expect(RetranslateEngine(provider: .deepl) == .deepl)
        #expect(RetranslateEngine(provider: .openrouter) == .openrouter)
    }

    @Test("kind mapping names no kind for Apple — the live Apple identity is probed")
    func kindMappingSkipsApple() {
        #expect(TranslationEngineKind(provider: .apple) == nil)
        #expect(TranslationEngineKind(provider: .google) == .google)
        #expect(TranslationEngineKind(provider: .deepl) == .deepl)
        #expect(TranslationEngineKind(provider: .openrouter) == .openrouter)
    }

    @Test("marker names match the labels shown on retried rows")
    func markerNamesMatchRowLabels() {
        #expect(TranslationEngineKind.appleHighFidelity.markerName == "Apple Intelligence")
        #expect(TranslationEngineKind.appleFast.markerName == "Apple (MTL)")
        #expect(TranslationEngineKind.google.markerName == "Google Translate")
        #expect(TranslationEngineKind.deepl.markerName == "DeepL")
        #expect(TranslationEngineKind.openrouter.markerName == "OpenRouter")
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
