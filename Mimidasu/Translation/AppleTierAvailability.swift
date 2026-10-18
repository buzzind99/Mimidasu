import Foundation
import Translation

/// Pair-scoped availability of the high-fidelity (Apple Intelligence)
/// translation strategy: the landed probe evidence, the supersede token,
/// the tier resolution that degrades an unsupported high-fidelity pick to
/// the fast model, and the strategy application for a session
/// configuration. The target-language catalog lives separately in
/// `AppleTranslationAvailability`.
@MainActor
@Observable
final class AppleTierAvailability {
    /// Landed probe evidence: (installed, the pair it was probed for).
    /// `(false, nil)` until a landing; every `beginProbe` resets it.
    private(set) var probe: (installed: Bool, targetCode: String?) = (false, nil)

    @ObservationIgnored private var sequence = 0
    @ObservationIgnored private let check: @Sendable (String) async -> Bool

    init(check: @escaping @Sendable (String) async -> Bool = AppleTierAvailability.check) {
        self.check = check
    }

    /// True when the OS exposes the high-fidelity strategy API (macOS 26.4+).
    static var supportsStrategySelection: Bool {
        guard #available(macOS 26.4, *) else { return false }
        return true
    }

    /// Re-fires the activation probe for `targetCode`: evidence resets
    /// synchronously, the async landing applies unless superseded.
    func beginProbe(for targetCode: String) {
        probe = (false, nil)
        sequence += 1
        let sequence = sequence
        let check = check
        Task { @MainActor [weak self] in
            let installed = await check(targetCode)
            guard let self,
                  sequence == self.sequence
            else { return }
            land(installed: installed, targetCode: targetCode)
        }
    }

    /// Records a landing — the probe task's write and the test seam.
    func land(installed: Bool, targetCode: String?) {
        probe = (installed, targetCode)
    }

    /// Drops an airborne probe without touching the landed evidence.
    func supersedeInFlightProbe() {
        sequence += 1
    }

    // Pair-scoped evidence

    /// The last landing was recorded for exactly `targetCode`.
    func probeLanded(for targetCode: String) -> Bool {
        probe.targetCode == targetCode
    }

    /// The pair has landed evidence and the strategy is not installed.
    func knownUnavailable(for targetCode: String) -> Bool {
        probeLanded(for: targetCode) && !probe.installed
    }

    /// The OS supports strategy selection, the pair's probe landed, and the
    /// strategy is installed.
    func available(for targetCode: String) -> Bool {
        Self.supportsStrategySelection && probeLanded(for: targetCode) && probe.installed
    }

    /// High fidelity can be offered: the OS supports it and no landing for
    /// this pair says it is unavailable.
    func offersHighFidelity(for targetCode: String) -> Bool {
        Self.supportsStrategySelection && !knownUnavailable(for: targetCode)
    }

    /// The pair's identity is established: below the strategy API the fast
    /// model is the only identity, and above it a landing is required.
    func identityKnown(for targetCode: String) -> Bool {
        !Self.supportsStrategySelection || probeLanded(for: targetCode)
    }

    // Resolution

    /// Degrades a high-fidelity selection to the fast model where the OS
    /// lacks the API or the pair's landing says it is unavailable. Every
    /// other tier — including high fidelity with no evidence for the pair —
    /// passes through unchanged.
    func effectiveTier(_ tier: RetranslateEngine, targetCode: String) -> RetranslateEngine {
        guard tier == .appleHighFidelity else { return tier }
        guard Self.supportsStrategySelection else { return .appleFast }
        return knownUnavailable(for: targetCode) ? .appleFast : tier
    }

    /// The engine-kind spelling of `effectiveTier(_:targetCode:)`.
    func effectiveKind(_ kind: TranslationEngineKind, targetCode: String) -> TranslationEngineKind {
        guard kind == .appleHighFidelity else { return kind }
        guard Self.supportsStrategySelection else { return .appleFast }
        return knownUnavailable(for: targetCode) ? .appleFast : kind
    }

    /// Applies the selected strategy where the API exists; no-op below 26.4.
    func applyPreferredStrategy(to config: inout TranslationSession.Configuration, highFidelity: Bool) {
        guard #available(macOS 26.4, *) else { return }
        config.preferredStrategy = highFidelity ? .highFidelity : .lowLatency
    }

    /// The real probe: asks `LanguageAvailability` whether the
    /// high-fidelity strategy is installed for ja→`targetCode`. Only
    /// `.installed` counts — a downloadable pair still runs the fast model —
    /// and older systems report false.
    nonisolated static func check(targetCode: String) async -> Bool {
        guard #available(macOS 26.4, *) else { return false }
        let availability = LanguageAvailability(preferredStrategy: .highFidelity)
        let status = await availability.status(
            from: Locale.Language(identifier: "ja"),
            to: Locale.Language(identifier: targetCode)
        )
        return status == .installed
    }
}
