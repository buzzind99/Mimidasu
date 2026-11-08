/// Translation providers selectable behind the `TranslationQueue` seam.
/// Raw values are the Keychain account names and UserDefaults keys, so they
/// must stay stable.
enum TranslationProvider: String, CaseIterable, Codable, Identifiable {
    case apple
    case google
    case deepl
    case openrouter
    case openai
    case anthropic
    case moonshot
    case zai
    case deepseek
    case xai

    var id: String {
        rawValue
    }

    /// The provider's catalog row — the single source of its fixed facts.
    var spec: ProviderSpec {
        ProviderCatalog.spec(for: self)
    }

    /// The provider's canonical name at the default tier facts: Apple's
    /// on-device model, DeepL at an unknown tier (the tier is only known
    /// once a key is stored). Every provider or tier name in the app comes
    /// from `TranslationTier`.
    var displayName: String {
        tier().name
    }

    /// Cloud providers send transcript sentences off the machine.
    var isExternal: Bool {
        spec.isExternal
    }

    /// Providers that translate through a chat model rather than a
    /// fixed-contract machine-translation API.
    var isLLM: Bool {
        spec.isLLM
    }

    /// The provider's default model from its catalog row; empty for the
    /// non-LLM providers.
    var defaultModel: String {
        spec.llm?.defaultModel ?? ""
    }
}

extension TranslationProvider {
    /// SF Symbol shown in the settings provider row.
    var settingsIcon: String {
        spec.settingsIcon
    }

    /// Supporting detail line under the provider name. Verified external
    /// providers append a "Configured" marker.
    func settingsDetail(configured: Bool) -> String {
        spec.settingsDetail(configured: configured)
    }

    /// The tier this provider sits at, given the tier facts the app knows.
    /// Apple has two tiers — the on-device NMT model and the high-fidelity
    /// one — and DeepL's tier is the subscription behind the stored key.
    /// The catalog row records which of those shapes applies.
    func tier(
        appleHighFidelity: Bool = false,
        deepLTier: TranslationTier.DeepLTier = .unknown
    ) -> TranslationTier {
        spec.tier.resolve(appleHighFidelity: appleHighFidelity, deepLTier: deepLTier)
    }

    /// Provider picker row label. Apple names the capability tier only when
    /// the OS reported the high-fidelity strategy installed for the current
    /// pair (`appleHighFidelity`), matching the sidebar and status rows;
    /// DeepL names its subscription tier, which stays unknown while no key
    /// is stored.
    func settingsName(
        deepLTier: TranslationTier.DeepLTier,
        appleHighFidelity: Bool = false
    ) -> String {
        tier(appleHighFidelity: appleHighFidelity, deepLTier: deepLTier).name
    }

    /// Compact engine label for the sidebar ENGINES card and the cloud
    /// disclosure sheet. Deliberately shorter than the canonical tier name
    /// — only the external providers reach it (the sidebar's Apple row is
    /// spelled by `SidebarStatus.translationEngineName`, which knows the
    /// Apple tier), so the Apple case is never rendered.
    var shortName: String {
        spec.shortName
    }
}
