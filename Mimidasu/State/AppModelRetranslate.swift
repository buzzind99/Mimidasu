import Foundation
import Translation

// Re-translate-lane façade of `AppModel`: forwarding accessors over
// `RetranslateCoordinator`, which owns the route resolution, the
// serialized alternate-engine runner, the dedicated Apple sessions, the
// marker sets, and the lane's epoch clock. The app model keeps phase,
// entries, and toasts.

// MARK: - Forwarded engine identity

extension AppModel {
    /// Engine identity of the live caption path (see
    /// `RetranslateCoordinator.activeEngineKind`).
    var activeEngineKind: TranslationEngineKind {
        retranslate.activeEngineKind
    }

    /// True when the live Apple session provably runs the given Apple kind.
    func liveSessionRunsKind(_ kind: TranslationEngineKind) -> Bool {
        retranslate.liveSessionRunsKind(kind)
    }

    /// High fidelity is *known* unavailable for the current target (see
    /// `RetranslateCoordinator.highFidelityKnownUnavailable`).
    var highFidelityKnownUnavailable: Bool {
        retranslate.highFidelityKnownUnavailable
    }

    /// High fidelity is *known* unavailable for `targetCode` — probe
    /// evidence only counts for the pair it was probed for, so a row whose
    /// target differs from the settings target is not described by the
    /// settings probe.
    func highFidelityKnownUnavailable(for targetCode: String) -> Bool {
        retranslate.highFidelityKnownUnavailable(for: targetCode)
    }

    /// The Apple model the re-translate selection can actually deliver.
    var effectiveRetranslateSelection: RetranslateEngine {
        retranslate.effectiveRetranslateSelection
    }

    /// True when the configured retry engine resolves to an engine other
    /// than the live session engine.
    var alternateRetranslateEngineActive: Bool {
        retranslate.alternateRetranslateEngineActive
    }
}

// MARK: - Forwarded commands

extension AppModel {
    /// Manual retry for one transcript row: routes through the configured
    /// engine. Idempotent and live-session gated (see
    /// `RetranslateCoordinator.retranslateSentence`).
    func retranslateSentence(_ sentence: Sentence) {
        retranslate.retranslateSentence(sentence)
    }

    /// Settings card selection: the on-device rows complete immediately; an
    /// external row holds its intent behind the cloud disclosure sheet.
    func selectRetranslateEngine(_ engine: RetranslateEngine) {
        retranslate.selectRetranslateEngine(engine)
    }

    /// Arms the kind's dedicated session on the first retry through it.
    func armRetranslateSessionIfNeeded(for kind: TranslationEngineKind) {
        retranslate.armRetranslateSessionIfNeeded(for: kind)
    }

    /// Stores the fast-model session handed over by the second
    /// `.translationTask` host.
    func retranslateSessionArrived(_ engine: any TranslationEngine) {
        retranslate.retranslateSessionArrived(engine)
    }

    /// Stores the Apple Intelligence session handed over by the third
    /// `.translationTask` host.
    func retranslateHifiSessionArrived(_ engine: any TranslationEngine) {
        retranslate.retranslateHifiSessionArrived(engine)
    }

    /// Ends any bulk run resolving against the dedicated sessions, then
    /// drops both armed-session states and invalidates in-flight lane work.
    /// Test seam over `RetranslateCoordinator.teardown` (the live Apple
    /// branch reaches the coordinator directly).
    func teardownRetranslateSession() {
        cancelArchiveTranslation()
        retranslate.teardown()
    }

    /// ja→target configuration for one of the dedicated re-translate
    /// sessions.
    func makeRetranslateConfig(highFidelity: Bool) -> TranslationSession.Configuration {
        retranslate.makeRetranslateConfig(highFidelity: highFidelity)
    }
}

// MARK: - Forwarded state

extension AppModel {
    var retranslateConfig: TranslationSession.Configuration? {
        get { retranslate.retranslateConfig }
        set { retranslate.retranslateConfig = newValue }
    }

    var retranslateSessionEngine: (any TranslationEngine)? {
        get { retranslate.retranslateSessionEngine }
        set { retranslate.retranslateSessionEngine = newValue }
    }

    var retranslateHifiConfig: TranslationSession.Configuration? {
        get { retranslate.retranslateHifiConfig }
        set { retranslate.retranslateHifiConfig = newValue }
    }

    var retranslateHifiSessionEngine: (any TranslationEngine)? {
        get { retranslate.retranslateHifiSessionEngine }
        set { retranslate.retranslateHifiSessionEngine = newValue }
    }

    /// Test seam: the stored lane task is `@ObservationIgnored` storage,
    /// so views must never read it for invalidation. Tests cancel and
    /// inject through this facade.
    var retranslateLaneTask: Task<Void, Never>? {
        get { retranslate.retranslateLaneTask }
        set { retranslate.retranslateLaneTask = newValue }
    }

    var lanePendingRetranslations: Set<Int> {
        get { retranslate.lanePendingRetranslations }
        set { retranslate.lanePendingRetranslations = newValue }
    }

    /// Sentence indexes with a manual re-translation in flight (the
    /// transcript row's dim cue + double-click guard).
    var pendingRetranslations: Set<Int> {
        get { retranslate.pendingRetranslations }
        set { retranslate.pendingRetranslations = newValue }
    }

    /// Injectable factory for the lane's external engines (tests); nil
    /// drives the live session's `makeExternalEngine(for:target:)`. The
    /// closure receives the click-time lane target.
    var retranslateEngineFactory:
        (@Sendable (TranslationProvider, TargetLanguage) -> (any TranslationEngine)?)?
    {
        get { retranslate.retranslateEngineFactory }
        set { retranslate.retranslateEngineFactory = newValue }
    }

    /// How long the re-translate lane waits for an arming dedicated Apple
    /// session before giving up on a click. Injectable for tests.
    var laneArmTimeout: Duration {
        get { retranslate.laneArmTimeout }
        set { retranslate.laneArmTimeout = newValue }
    }

    /// How long an Apple-kind re-translate lane waits for the activation
    /// probe to land before routing on it. Injectable for tests.
    var probeSettleTimeout: Duration {
        get { retranslate.probeSettleTimeout }
        set { retranslate.probeSettleTimeout = newValue }
    }
}
