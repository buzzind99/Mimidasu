/// The live translation engine's identity and attachment: which engine the
/// queue is running, the external provider behind it, whether a worker is
/// attached, and the latched Apple fallback.
///
/// The queue's status deliberately lives outside this value (on
/// `TranslationSessionCoordinator`), because this one is read by the
/// transcript's row plan: a per-batch `.translating` → `.ready` flip would
/// otherwise re-render every transcript row.
struct TranslationRuntime: Equatable, Sendable {
    var engine: ActiveTranslationEngine = .apple
    var externalProvider: TranslationProvider?
    var workerAttached: Bool = false
    var fallbackLatched: Bool = false

    /// The one latch derivation the sidebar and Settings both read today.
    var isAppleFallbackLatched: Bool {
        fallbackLatched && engine == .apple
    }
}
