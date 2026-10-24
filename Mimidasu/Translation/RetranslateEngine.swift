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
    case openai
    case anthropic
    case moonshot
    case zai
    case deepseek
    case xai

    /// The external provider this selection routes through (nil for the
    /// on-device selections, which need no key).
    var provider: TranslationProvider? {
        switch self {
        case .session, .appleFast, .appleHighFidelity: nil
        case .google: .google
        case .deepl: .deepl
        case .openrouter: .openrouter
        case .openai: .openai
        case .anthropic: .anthropic
        case .moonshot: .moonshot
        case .zai: .zai
        case .deepseek: .deepseek
        case .xai: .xai
        }
    }

    /// The engine identity this selection names; nil for `.session`, which
    /// names no engine of its own.
    var kind: TranslationEngineKind? {
        switch self {
        case .session: nil
        case .appleFast: .appleFast
        case .appleHighFidelity: .appleHighFidelity
        case .google: .google
        case .deepl: .deepl
        case .openrouter: .openrouter
        case .openai: .openai
        case .anthropic: .anthropic
        case .moonshot: .moonshot
        case .zai: .zai
        case .deepseek: .deepseek
        case .xai: .xai
        }
    }

    /// Display label for surfaces that pick an engine (the archive engine
    /// picker's rows, the bulk run's progress card). The name comes from
    /// the shared tier vocabulary; `.session` names no engine of its own —
    /// only the settings card offers it.
    var displayName: String {
        kind?.tier.name ?? "Session engine"
    }

    /// The selection behind a Settings provider row; nil for Apple, which
    /// has no lane of its own.
    init?(provider: TranslationProvider) {
        switch provider {
        case .apple: return nil
        case .google: self = .google
        case .deepl: self = .deepl
        case .openrouter: self = .openrouter
        case .openai: self = .openai
        case .anthropic: self = .anthropic
        case .moonshot: self = .moonshot
        case .zai: self = .zai
        case .deepseek: self = .deepseek
        case .xai: self = .xai
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
    case openai
    case anthropic
    case moonshot
    case zai
    case deepseek
    case xai

    /// nil for Apple: the live Apple identity depends on the OS's strategy
    /// probe (high fidelity vs fast), never on the picker selection.
    init?(provider: TranslationProvider) {
        switch provider {
        case .apple: return nil
        case .google: self = .google
        case .deepl: self = .deepl
        case .openrouter: self = .openrouter
        case .openai: self = .openai
        case .anthropic: self = .anthropic
        case .moonshot: self = .moonshot
        case .zai: self = .zai
        case .deepseek: self = .deepseek
        case .xai: self = .xai
        }
    }

    /// The tier this kind names — the one vocabulary of engine names.
    var tier: TranslationTier {
        switch self {
        case .appleFast: .appleOnDevice
        case .appleHighFidelity: .appleHighFidelity
        case .google: .google
        case .deepl: .deepL(.unknown)
        case .openrouter: .openRouter
        case .openai: .openAI
        case .anthropic: .anthropic
        case .moonshot: .moonshot
        case .zai: .zai
        case .deepseek: .deepSeek
        case .xai: .xAI
        }
    }

    /// Marker suffix shown on retried rows ("· via Apple (NMT)").
    var markerName: String {
        tier.name
    }
}
