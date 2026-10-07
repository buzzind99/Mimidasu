import Foundation

/// Which engine the transcript row's re-translate button uses. The raw
/// value is the persisted representation and must stay stable.
enum RetranslateEngine: String, Codable, CaseIterable, Sendable, Equatable, Hashable {
    case session
    case appleFast
    case appleHighFidelity
    case google
    case deepl
    case openrouter

    /// The external provider this selection routes through (nil for the
    /// on-device selections, which need no key).
    var provider: TranslationProvider? {
        switch self {
        case .session, .appleFast, .appleHighFidelity: nil
        case .google: .google
        case .deepl: .deepl
        case .openrouter: .openrouter
        }
    }

    /// The selection behind a Settings provider row; nil for Apple, which
    /// has no lane of its own.
    init?(provider: TranslationProvider) {
        switch provider {
        case .apple: return nil
        case .google: self = .google
        case .deepl: self = .deepl
        case .openrouter: self = .openrouter
        }
    }
}

/// Canonical engine identity for provenance stamps
/// (`SentenceTranslation.engine`) and the row marker's render-time
/// comparison against the live session engine. Raw values are stable —
/// they appear in the JSON export.
enum TranslationEngineKind: String, Codable, Sendable, Equatable {
    case appleHighFidelity
    case appleFast
    case google
    case deepl
    case openrouter

    /// nil for Apple: the live Apple identity depends on the OS's strategy
    /// probe (high fidelity vs fast), never on the picker selection.
    init?(provider: TranslationProvider) {
        switch provider {
        case .apple: return nil
        case .google: self = .google
        case .deepl: self = .deepl
        case .openrouter: self = .openrouter
        }
    }

    /// Marker suffix shown on retried rows ("· via Apple (MTL)").
    var markerName: String {
        switch self {
        case .appleHighFidelity: "Apple Intelligence"
        case .appleFast: "Apple (MTL)"
        case .google: "Google Translate"
        case .deepl: "DeepL"
        case .openrouter: "OpenRouter"
        }
    }
}
