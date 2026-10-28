struct TranslationRuntime: Equatable, Sendable {
    var engine: ActiveTranslationEngine = .apple
    var externalProvider: TranslationProvider?
    var workerAttached: Bool = false
    var status: TranslationStatus = .idle
    var fallbackLatched: Bool = false

    /// The one latch derivation the sidebar and Settings both read today.
    var isAppleFallbackLatched: Bool {
        fallbackLatched && engine == .apple
    }
}
