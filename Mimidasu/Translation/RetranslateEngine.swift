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

    /// The external provider this selection routes through; nil for the
    /// on-device selections, which need no key. The engine kind resolves the
    /// provider through its catalog row.
    var provider: TranslationProvider? {
        kind?.provider
    }

    /// The engine identity this selection names; nil for `.session`, which
    /// names no engine of its own. The switch is exhaustive so a new
    /// selection must decide its kind; external selections share their
    /// kind's raw value.
    var kind: TranslationEngineKind? {
        switch self {
        case .session:
            return nil
        case .appleFast:
            return .appleFast
        case .appleHighFidelity:
            return .appleHighFidelity
        case .google, .deepl, .openrouter, .openai, .anthropic, .moonshot, .zai, .deepseek, .xai:
            guard let kind = TranslationEngineKind(rawValue: rawValue) else {
                assertionFailure("external selection \(rawValue) has no engine kind")
                return nil
            }
            return kind
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
    /// has no lane of its own. External selections share their kind's raw
    /// value — the persisted selection identity — so the selection is the
    /// kind's raw value.
    init?(provider: TranslationProvider) {
        guard let kind = TranslationEngineKind(provider: provider) else { return nil }
        self.init(rawValue: kind.rawValue)
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

    /// The external provider this identity names; nil for the two Apple
    /// engine identities, which have no provider row of their own. The
    /// provider's catalog row names the kind, so the reverse lookup is
    /// verified against that row rather than trusting the shared raw value
    /// alone.
    var provider: TranslationProvider? {
        guard let provider = TranslationProvider(rawValue: rawValue),
              ProviderCatalog.spec(for: provider).engineKind == self
        else { return nil }
        return provider
    }

    /// nil for Apple: the live Apple identity depends on the OS's strategy
    /// probe (high fidelity vs fast), never on the picker selection.
    init?(provider: TranslationProvider) {
        guard let kind = ProviderCatalog.spec(for: provider).engineKind else { return nil }
        self = kind
    }

    /// The tier this kind names — the one vocabulary of engine names. The
    /// mapping is total so a stamped row can always render its label; the
    /// catalog's tier shapes are pinned against it by the identity tests.
    var tier: TranslationTier {
        switch self {
        case .appleFast:
            .appleOnDevice
        case .appleHighFidelity:
            .appleHighFidelity
        case .google:
            .google
        case .deepl:
            .deepL(.unknown)
        case .openrouter:
            .openRouter
        case .openai:
            .openAI
        case .anthropic:
            .anthropic
        case .moonshot:
            .moonshot
        case .zai:
            .zai
        case .deepseek:
            .deepSeek
        case .xai:
            .xAI
        }
    }

    /// Marker suffix shown on retried rows ("· via Apple (NMT)").
    var markerName: String {
        tier.name
    }
}
