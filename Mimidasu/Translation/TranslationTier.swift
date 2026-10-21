import Foundation

/// The translation tiers the app names — and the single owner of their
/// names.
///
/// Every **canonical** provider or tier name that reaches the UI derives
/// from `name`. (`TranslationProvider.shortName` is a deliberate
/// abbreviation table for the narrow sidebar card, not a second naming
/// authority.) The tiers are finer than the providers:
/// `TranslationProvider.apple` covers two Apple tiers, and DeepL's name
/// depends on the subscription tier behind the stored key.
enum TranslationTier: Equatable, Sendable {
    /// Apple's on-device neural machine translation model.
    case appleOnDevice
    /// Apple's high-fidelity model — Apple Intelligence.
    case appleHighFidelity
    /// Google Translate.
    case google
    /// DeepL, at a known subscription tier.
    case deepL(DeepLTier)
    /// OpenRouter.
    case openRouter

    /// The DeepL subscription tier. `.unknown` while no key is stored — the
    /// tier cannot be known until one is.
    enum DeepLTier: Equatable, Sendable {
        case unknown
        case free
        case pro
    }

    /// The canonical, user-visible name of the tier.
    var name: String {
        switch self {
        case .appleOnDevice: "Apple (NMT)"
        case .appleHighFidelity: "Apple Intelligence"
        case .google: "Google Translate"
        case .deepL(.unknown): "DeepL"
        case .deepL(.free): "DeepL (Free)"
        case .deepL(.pro): "DeepL (Pro)"
        case .openRouter: "OpenRouter"
        }
    }
}
