import Foundation

/// A selectable translation target language (the source is fixed `ja`).
///
/// The picker catalog is discovered at runtime from Apple's Translation
/// framework; this type carries one entry's persisted payload — the BCP-47
/// `code` — plus the static per-engine metadata the cloud providers need
/// (Google's regional codes, DeepL's uppercase codes). `displayName` is
/// resolved in the user's locale at read time; no localized strings ship in
/// the table.
struct TargetLanguage: Hashable, Sendable, Identifiable, Codable {
    /// BCP-47 identifier, e.g. "en", "zh-Hans". The persisted representation.
    let code: String
    /// English name, used verbatim in the OpenRouter system prompt
    /// ("English", "Simplified Chinese").
    let englishName: String
    /// Google Translate v2 target code (defaults to `code`; the Chinese
    /// variants map to `zh-CN` / `zh-TW`).
    let googleCode: String
    /// DeepL target code (uppercase). Non-nil for every current catalog
    /// entry; nil would mean a language DeepL can't serve.
    let deeplCode: String?

    var id: String {
        code
    }

    /// Resolves `code` against the metadata table. Unknown codes fall back
    /// to English so a selection persisted by a future OS version still
    /// loads instead of failing.
    init(code: String) {
        if let known = TargetLanguage.known.first(where: { candidate in
            candidate.code == code
        }) {
            self = known
        } else {
            self = .english
        }
    }

    // MARK: Codable (the persisted payload is the code alone)

    init(from decoder: any Decoder) throws {
        try self.init(code: decoder.singleValueContainer().decode(String.self))
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(code)
    }

    /// Localized display name ("English", "简体中文") for the picker rows;
    /// falls back to the English name when the locale can't name the code.
    var displayName: String {
        (Locale.current as NSLocale).displayName(forKey: .identifier, value: code)
            ?? englishName
    }

    /// Endonym fixes for codes where the OS-resolved name isn't the
    /// conventional native name ("Indonesia" → "Bahasa Indonesia").
    private static let nativeNameOverrides = ["id": "Bahasa Indonesia"]

    /// The name in the language itself ("Deutsch", "简体中文"), resolved
    /// against a locale built from `code`; falls back to the English name
    /// when the OS can't name the code. CLDR spells endonyms as the language
    /// itself does ("français", "türkçe"); an initial capital is forced so
    /// the picker rows read uniformly.
    var nativeName: String {
        if let override = Self.nativeNameOverrides[code] {
            return override
        }
        let selfLocale = Locale(identifier: code)
        let name = (selfLocale as NSLocale).displayName(forKey: .identifier, value: code)
            ?? englishName
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    // MARK: - Metadata table

    /// The default target.
    static let english = TargetLanguage(entryCode: "en", englishName: "English", deeplCode: "EN")

    /// Every language Apple's Translation framework has shipped as a target
    /// (the fixed `ja` source excluded), with the per-engine code mappings.
    /// Codes Apple discovers at runtime that miss this table are dropped
    /// from the picker rather than degrading to English silently.
    static let known: [TargetLanguage] = [
        .english,
        TargetLanguage(entryCode: "ar", englishName: "Arabic", deeplCode: "AR"),
        TargetLanguage(entryCode: "de", englishName: "German", deeplCode: "DE"),
        TargetLanguage(entryCode: "es", englishName: "Spanish", deeplCode: "ES"),
        TargetLanguage(entryCode: "fr", englishName: "French", deeplCode: "FR"),
        TargetLanguage(entryCode: "hi", englishName: "Hindi", deeplCode: "HI"),
        TargetLanguage(entryCode: "id", englishName: "Indonesian", deeplCode: "ID"),
        TargetLanguage(entryCode: "it", englishName: "Italian", deeplCode: "IT"),
        TargetLanguage(entryCode: "ko", englishName: "Korean", deeplCode: "KO"),
        TargetLanguage(entryCode: "nl", englishName: "Dutch", deeplCode: "NL"),
        TargetLanguage(entryCode: "pl", englishName: "Polish", deeplCode: "PL"),
        TargetLanguage(entryCode: "pt", englishName: "Portuguese", deeplCode: "PT"),
        TargetLanguage(entryCode: "ru", englishName: "Russian", deeplCode: "RU"),
        TargetLanguage(entryCode: "th", englishName: "Thai", deeplCode: "TH"),
        TargetLanguage(entryCode: "tr", englishName: "Turkish", deeplCode: "TR"),
        TargetLanguage(entryCode: "uk", englishName: "Ukrainian", deeplCode: "UK"),
        TargetLanguage(entryCode: "vi", englishName: "Vietnamese", deeplCode: "VI"),
        TargetLanguage(
            entryCode: "zh-Hans", englishName: "Simplified Chinese",
            googleCode: "zh-CN", deeplCode: "ZH-HANS"
        ),
        TargetLanguage(
            entryCode: "zh-Hant", englishName: "Traditional Chinese",
            googleCode: "zh-TW", deeplCode: "ZH-HANT"
        )
    ]

    /// Table-entry constructor: `googleCode` defaults to the BCP-47 code,
    /// which Google accepts verbatim for everything but the Chinese
    /// variants.
    private init(entryCode: String, englishName: String, googleCode: String? = nil, deeplCode: String) {
        code = entryCode
        self.englishName = englishName
        self.googleCode = googleCode ?? entryCode
        self.deeplCode = deeplCode
    }
}
