import Foundation

/// Translation providers selectable behind the `TranslationQueue` seam.
/// Raw values are the Keychain account names and UserDefaults keys, so they
/// must stay stable.
enum TranslationProvider: String, CaseIterable, Codable, Identifiable {
    case apple
    case google
    case deepl
    case openrouter

    var id: String {
        rawValue
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
        self != .apple
    }
}

extension TranslationProvider {
    /// SF Symbol shown in the settings provider row.
    var settingsIcon: String {
        switch self {
        case .apple: "apple.logo"
        case .google: "g.circle.fill"
        case .deepl: "d.circle.fill"
        case .openrouter: "o.circle.fill"
        }
    }

    /// Supporting detail line under the provider name. Key-holding external
    /// providers append a "Configured" marker.
    func settingsDetail(hasKey: Bool) -> String {
        switch self {
        case .apple: "On-device"
        case .google, .deepl:
            hasKey ? "External · API key · Configured" : "External · API key"
        case .openrouter:
            hasKey ? "External · API key + model · Configured" : "External · API key + model"
        }
    }

    /// The tier this provider sits at, given the tier facts the app knows.
    /// Apple has two tiers — the on-device NMT model and the high-fidelity
    /// one — and DeepL's tier is the subscription behind the stored key.
    func tier(
        appleHighFidelity: Bool = false,
        deepLTier: TranslationTier.DeepLTier = .unknown
    ) -> TranslationTier {
        switch self {
        case .apple: appleHighFidelity ? .appleHighFidelity : .appleOnDevice
        case .google: .google
        case .deepl: .deepL(deepLTier)
        case .openrouter: .openRouter
        }
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
        switch self {
        case .apple: "Apple"
        case .google: "Google"
        case .deepl: "DeepL"
        case .openrouter: "OpenRouter"
        }
    }
}

/// Outcome of the Settings "Test" button, surfaced inline and persisted so
/// the row survives relaunch. Failure detail strings are provider-agnostic
/// status copy — never key material or raw response bodies.
enum ConnectionTestResult: Equatable {
    case success
    case failure(String)
}

/// Non-secret translation settings: selected provider, per-provider `hasKey`
/// flags (with a last-4 hint for the UI), the OpenRouter model string, and
/// the latest connection-test results. Keys themselves live only in
/// `SecureKeyStoring` (the Keychain in production) and are read on demand
/// when an engine is constructed — never cached here.
///
/// Selection policy: a provider becomes selected only once it's configured —
/// a saved key that passes the connection test (the Settings key card selects
/// it on test success). Apple on-device stays active until then, and an
/// unconfigured selection degrades to Apple at engine construction.
@Observable
@MainActor
final class TranslationSettings {
    private(set) var selectedProvider: TranslationProvider {
        didSet { defaults.set(selectedProvider.rawValue, forKey: Self.selectedKey) }
    }

    /// OpenRouter chat-completions model, used verbatim in the request body.
    var openRouterModel: String {
        didSet { defaults.set(openRouterModel, forKey: Self.openRouterModelKey) }
    }

    /// True when the selected DeepL key came from the free tier (`:fx`
    /// suffix) — drives the "DeepL (Free)" label. Non-secret.
    private(set) var deeplIsFreeTier: Bool {
        didSet { defaults.set(deeplIsFreeTier, forKey: Self.deeplFreeKey) }
    }

    /// The DeepL subscription tier behind the stored key. It stays unknown
    /// while no key is stored — the tier cannot be known until one is — so
    /// the provider row reads plain "DeepL" until then.
    var deepLTier: TranslationTier.DeepLTier {
        guard hasKey(for: .deepl) else { return .unknown }
        return deeplIsFreeTier ? .free : .pro
    }

    /// Selected translation target (the source stays fixed `ja`). Persisted
    /// as the raw BCP-47 code; unknown codes fall back to English on load.
    /// Restart-only: a new target applies at the next session start.
    private(set) var targetLanguage: TargetLanguage {
        didSet { defaults.set(targetLanguage.code, forKey: Self.targetLanguageKey) }
    }

    /// Which engine the transcript row's re-translate button uses. Persisted;
    /// unknown raw values fall back to the session engine on load.
    private(set) var retranslateEngine: RetranslateEngine {
        didSet { defaults.set(retranslateEngine.rawValue, forKey: Self.retranslateEngineKey) }
    }

    /// Whether retried rows render their "· via <engine>" provenance marker.
    /// User-editable (the settings card binds it), persisted.
    var showsRetranslateMarker: Bool {
        didSet { defaults.set(showsRetranslateMarker, forKey: Self.retranslateMarkerKey) }
    }

    /// Observed so views update on `removeKey`/`setTestResult`; dictionary
    /// assignment routes through the property setter, firing observation.
    private(set) var hasKey: [TranslationProvider: Bool]
    private(set) var keyHints: [TranslationProvider: String]
    private(set) var testResults: [TranslationProvider: ConnectionTestResult]

    private let defaults: UserDefaults
    private let keys: SecureKeyStoring

    private static let selectedKey = "translation.selectedProvider"
    private static let openRouterModelKey = "translation.openRouterModel"
    private static let deeplFreeKey = "translation.deeplFreeTier"
    private static let targetLanguageKey = "translation.targetLanguage"
    private static let retranslateEngineKey = "translation.retranslateEngine"
    private static let retranslateMarkerKey = "translation.retranslateMarker"
    private static func hasKeyKey(_ provider: TranslationProvider) -> String {
        "translation.hasKey.\(provider.rawValue)"
    }

    private static func keyHintKey(_ provider: TranslationProvider) -> String {
        "translation.keyHint.\(provider.rawValue)"
    }

    private static func testResultKey(_ provider: TranslationProvider) -> String {
        "translation.testResult.\(provider.rawValue)"
    }

    /// - Parameters:
    ///   - defaults: injectable for tests (unique suite per test).
    ///   - keys: injectable for tests (in-memory stand-in for the Keychain).
    ///     Nil (production default) uses the Keychain in release builds; dev
    ///     builds get a no-op store instead — the dev-signed binary can't
    ///     read items saved by the release app, so every Keychain read would
    ///     pop an access prompt. With no readable key, dev always runs the
    ///     Apple on-device engine.
    init(defaults: UserDefaults = .standard, keys: (any SecureKeyStoring)? = nil) {
        self.defaults = defaults
        #if DEBUG
            self.keys = keys ?? DevNoopKeyStore()
        #else
            self.keys = keys ?? KeychainStore()
        #endif

        let selected = defaults.string(forKey: Self.selectedKey)
            .flatMap(TranslationProvider.init(rawValue:)) ?? .apple
        selectedProvider = selected
        openRouterModel = defaults.string(forKey: Self.openRouterModelKey) ?? ""
        deeplIsFreeTier = defaults.bool(forKey: Self.deeplFreeKey)
        targetLanguage = defaults.string(forKey: Self.targetLanguageKey)
            .map(TargetLanguage.init(code:)) ?? .english
        retranslateEngine = defaults.string(forKey: Self.retranslateEngineKey)
            .flatMap(RetranslateEngine.init(rawValue:)) ?? .session
        showsRetranslateMarker = (defaults.object(forKey: Self.retranslateMarkerKey) as? Bool) ?? true

        var hasKey: [TranslationProvider: Bool] = [:]
        var keyHints: [TranslationProvider: String] = [:]
        var testResults: [TranslationProvider: ConnectionTestResult] = [:]
        for provider in TranslationProvider.allCases {
            let stored = defaults.bool(forKey: Self.hasKeyKey(provider))
            // Cross-check the flag against the actual key store: a flag
            // without a key (or vice versa) degrades to the truth.
            hasKey[provider] = stored && self.keys.readKey(for: provider.rawValue) != nil
            keyHints[provider] = defaults.string(forKey: Self.keyHintKey(provider))
            if let raw = defaults.string(forKey: Self.testResultKey(provider)) {
                testResults[provider] = Self.decodeTestResult(raw)
            }
        }
        self.hasKey = hasKey
        self.keyHints = keyHints
        self.testResults = testResults
    }

    // MARK: - Key management

    func hasKey(for provider: TranslationProvider) -> Bool {
        hasKey[provider] ?? false
    }

    /// Last-4 hint shown after saving ("•••• ab12"). Nil when unconfigured.
    func keyHint(for provider: TranslationProvider) -> String? {
        keyHints[provider]
    }

    /// Reads the key from the secure store on demand (engine construction,
    /// connection tests). Never cached.
    func key(for provider: TranslationProvider) -> String? {
        guard hasKey(for: provider) else { return nil }
        return keys.readKey(for: provider.rawValue)
    }

    /// Writes the key to the secure store and records the non-secret
    /// `hasKey` flag + last-4 hint. Selection is unchanged — the Settings
    /// key card selects the provider when the post-save connection test
    /// succeeds.
    func saveKey(_ key: String, for provider: TranslationProvider) throws(KeychainStoreError) {
        try keys.saveKey(key, for: provider.rawValue)
        hasKey[provider] = true
        let suffix = key.suffix(4)
        keyHints[provider] = suffix.isEmpty ? nil : String(suffix)
        defaults.set(true, forKey: Self.hasKeyKey(provider))
        if suffix.isEmpty {
            defaults.removeObject(forKey: Self.keyHintKey(provider))
        } else {
            defaults.set(String(suffix), forKey: Self.keyHintKey(provider))
        }
        if provider == .deepl {
            deeplIsFreeTier = key.hasSuffix(":fx")
        }
    }

    /// Removes the key and its non-secret traces. Removing the selected
    /// provider's key falls back to Apple — an unconfigured provider can't
    /// stay active, and the settings view's selection observer re-attaches
    /// the on-device engine immediately.
    func removeKey(for provider: TranslationProvider) {
        keys.deleteKey(for: provider.rawValue)
        hasKey[provider] = false
        keyHints[provider] = nil
        if provider == .deepl {
            deeplIsFreeTier = false
        }
        defaults.set(false, forKey: Self.hasKeyKey(provider))
        defaults.removeObject(forKey: Self.keyHintKey(provider))
        setTestResult(nil, for: provider)
        if selectedProvider == provider {
            select(.apple)
        }
        // The persisted re-translate selection must stay resolvable in
        // Settings (only configured providers are listed there); click-time
        // unavailability is then only the Apple-fast cold start.
        if retranslateEngine.provider == provider {
            selectRetranslate(.session)
        }
    }

    // MARK: - Selection

    /// Persists the picker selection.
    func select(_ provider: TranslationProvider) {
        selectedProvider = provider
    }

    /// Persists the re-translate engine selection (the settings card).
    /// Deliberately not a `select` overload: the two enums share case names
    /// (`google`, `deepl`), which would make every `.google` call site
    /// ambiguous.
    func selectRetranslate(_ engine: RetranslateEngine) {
        retranslateEngine = engine
    }

    /// Persists the target-language picker selection. Restart-only: engines
    /// and the Apple config read the value at the next session start; no
    /// mid-session re-translation is wired.
    func select(_ target: TargetLanguage) {
        targetLanguage = target
    }

    // MARK: - Connection tests

    func testResult(for provider: TranslationProvider) -> ConnectionTestResult? {
        testResults[provider]
    }

    /// Records the latest Test-button outcome (nil clears it).
    func setTestResult(_ result: ConnectionTestResult?, for provider: TranslationProvider) {
        testResults[provider] = result
        if let raw = result.map(Self.encodeTestResult) {
            defaults.set(raw, forKey: Self.testResultKey(provider))
        } else {
            defaults.removeObject(forKey: Self.testResultKey(provider))
        }
    }

    // MARK: - "Currently using" row

    /// The model the OpenRouter engine actually sends per request: the stored
    /// string, or the engine's default when the field is left empty (mirrors
    /// the init fallback in `OpenRouterEngine`).
    var effectiveOpenRouterModel: String {
        openRouterModel.isEmpty ? OpenRouterEngine.defaultModel : openRouterModel
    }

    /// Truthful description of the engine currently in use, including the
    /// Apple-fallback latch ("DeepL (Free) — fallback active") and the
    /// selected target ("Apple (NMT) → English"; "Apple Intelligence →
    /// English" once the probe reports the strategy installed). The Apple
    /// label names Apple Intelligence only while the OS reported the
    /// high-fidelity strategy installed for the current pair
    /// (`appleHighFidelity`); otherwise it names the on-device model. The
    /// base label prefers the attached provider (`attachedProvider`) over
    /// the picker so it never names an engine that isn't actually running;
    /// nil (nothing external attached, or no session yet) falls back to the
    /// picker selection. Driven by published state
    /// (`translationFallbackActive`, `activeExternalProvider`), never
    /// re-derived from the picker alone.
    func activeEngineDescription(
        fallbackActive: Bool,
        attachedProvider: TranslationProvider? = nil,
        appleHighFidelity: Bool = false
    ) -> String {
        let provider = attachedProvider ?? selectedProvider
        var label: String = switch provider {
        case .apple:
            appleHighFidelity
                ? TranslationTier.appleHighFidelity.name
                : TranslationTier.appleOnDevice.name
        case .google:
            TranslationTier.google.name
        case .deepl:
            // The running engine always has a key, so its tier is known
            // here — unlike the provider row, which must stay "DeepL"
            // until a key is stored.
            TranslationTier.deepL(deeplIsFreeTier ? .free : .pro).name
        case .openrouter:
            "\(TranslationTier.openRouter.name) · \(effectiveOpenRouterModel)"
        }
        label += " → \(targetLanguage.displayName)"
        if fallbackActive, provider.isExternal {
            label += " — fallback active"
        }
        return label
    }

    // MARK: - Test-result persistence (non-secret)

    private static func encodeTestResult(_ result: ConnectionTestResult) -> String {
        switch result {
        case .success: "success"
        case let .failure(message): "failure:\(message)"
        }
    }

    private static func decodeTestResult(_ raw: String) -> ConnectionTestResult? {
        if raw == "success" {
            return .success
        }
        if raw.hasPrefix("failure:") {
            return .failure(String(raw.dropFirst("failure:".count)))
        }
        return nil
    }
}

#if DEBUG
    /// Dev-only `SecureKeyStoring` that never touches the Keychain: saves are
    /// discarded and reads always return nil, so dev builds pin translation to
    /// the Apple on-device engine and no Keychain access prompt ever fires.
    private struct DevNoopKeyStore: SecureKeyStoring {
        func saveKey(_ key: String, for providerID: String) {}

        func readKey(for providerID: String) -> String? {
            nil
        }

        func deleteKey(for providerID: String) {}
    }
#endif
