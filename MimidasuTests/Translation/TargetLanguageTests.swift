import Foundation
@testable import Mimidasu
import Testing

/// Tests `TargetLanguage`: metadata-table integrity (unique codes, `ja`
/// absent), the per-engine code mappings (Google's Chinese variants, DeepL's
/// uppercase catalog), the unknown-code fallback, and the code-only Codable
/// payload.
@Suite("TargetLanguage")
struct TargetLanguageTests {

    // MARK: - Catalog integrity

    @Test("every catalog entry has a unique code and carries both engine codes")
    func catalogIntegrity() {
        let codes = TargetLanguage.known.map(\.code)
        #expect(Set(codes).count == codes.count, "codes are unique")
        #expect(!codes.contains("ja"), "the fixed source language is never a target")
        #expect(TargetLanguage.english.id == "en", "Identifiable keys on the code")
        for target in TargetLanguage.known {
            #expect(!target.englishName.isEmpty, "\(target.code) needs an English name")
            #expect(!target.googleCode.isEmpty, "\(target.code) needs a Google code")
            #expect(target.deeplCode != nil, "\(target.code) needs a DeepL code")
            #expect(
                target.deeplCode == target.deeplCode?.uppercased(),
                "\(target.code): DeepL codes are uppercase"
            )
        }
    }

    /// The set Apple's Translation framework has been observed to report on
    /// macOS (regional variants already normalized). Every language the
    /// runtime can discover must land in the table, or the picker would
    /// silently drop it.
    @Test("the runtime-discoverable Apple set is fully covered by the table")
    func appleSetIsCovered() {
        let discovered = [
            "ar", "de", "en", "es", "fr", "hi", "id", "it", "ko", "nl",
            "pl", "pt", "ru", "th", "tr", "uk", "vi", "zh-Hans", "zh-Hant"
        ]
        let covered = Set(TargetLanguage.known.map(\.code))
        for code in discovered {
            #expect(covered.contains(code), "\(code) must have a metadata entry")
        }
    }

    // MARK: - Engine code mappings

    @Test("Google codes default to the BCP-47 code; Chinese variants map to zh-CN/zh-TW")
    func googleCodeMapping() {
        #expect(TargetLanguage.english.googleCode == "en")
        #expect(TargetLanguage(code: "th").googleCode == "th")
        #expect(TargetLanguage(code: "pt").googleCode == "pt")
        #expect(TargetLanguage(code: "zh-Hans").googleCode == "zh-CN")
        #expect(TargetLanguage(code: "zh-Hant").googleCode == "zh-TW")
    }

    @Test("DeepL codes cover the catalog, including th and both Chinese variants")
    func deeplCodeMapping() {
        #expect(TargetLanguage.english.deeplCode == "EN")
        #expect(TargetLanguage(code: "th").deeplCode == "TH")
        #expect(TargetLanguage(code: "hi").deeplCode == "HI")
        #expect(TargetLanguage(code: "vi").deeplCode == "VI")
        #expect(TargetLanguage(code: "pt").deeplCode == "PT")
        #expect(TargetLanguage(code: "zh-Hans").deeplCode == "ZH-HANS")
        #expect(TargetLanguage(code: "zh-Hant").deeplCode == "ZH-HANT")
    }

    // MARK: - Native names

    @Test("the native name resolves in the language itself with an initial capital")
    func nativeNameResolvesSelfLocale() {
        #expect(TargetLanguage(code: "de").nativeName == "Deutsch")
        // CLDR spells the French endonym lowercase; the picker capitalizes it.
        #expect(TargetLanguage(code: "fr").nativeName == "Français")
    }

    @Test("the Indonesian endonym uses the conventional native name")
    func nativeNameOverride() {
        #expect(TargetLanguage(code: "id").nativeName == "Bahasa Indonesia")
    }

    @Test("a compound-code endonym resolves through the scripted variant")
    func nativeNameCompoundCode() {
        #expect(TargetLanguage(code: "zh-Hans").nativeName == "简体中文")
    }

    // MARK: - Unknown-code fallback

    @Test("an unknown code falls back to English")
    func unknownCodeFallsBackToEnglish() {
        let fallback = TargetLanguage(code: "xx-Unknown")
        #expect(fallback == .english)
        #expect(fallback.englishName == "English")
        #expect(fallback.googleCode == "en")
        #expect(fallback.deeplCode == "EN")
    }

    @Test("an unscripted Chinese code has no entry of its own and falls back")
    func bareChineseFallsBack() {
        // The picker normalizes to the scripted variants; a bare "zh" only
        // arises from foreign persistence, where English is the safe landing.
        #expect(TargetLanguage(code: "zh") == .english)
    }

    // MARK: - Codable (code-only payload)

    @Test("Codable round-trips the code alone")
    func codableRoundTrip() throws {
        let target = TargetLanguage(code: "zh-Hans")
        let data = try JSONEncoder().encode(target)
        #expect(data == Data("\"zh-Hans\"".utf8))
        #expect(try JSONDecoder().decode(TargetLanguage.self, from: data) == target)
    }

    @Test("decoding an unknown persisted code lands on English")
    func decodingUnknownCodeLandsOnEnglish() throws {
        let decoded = try JSONDecoder().decode(TargetLanguage.self, from: Data("\"xx-Unknown\"".utf8))
        #expect(decoded == .english)
    }
}
