import SwiftUI

/// Pure phase → presentation mapping for the sidebar's status affordances —
/// the session capsule (title, icon, gradient choice, disabled gate) and the
/// ASR engine dot's tone. Mirrors the `TranslationPill.map` precedent: the
/// view renders the mapping, tests pin it.
struct SidebarStatus: Equatable {
    /// Status-dot tone, shared by the ASR and translation rows. The pill
    /// mapping already owns the scale, so the sidebar reads it directly
    /// instead of keeping a second copy of the case set.
    typealias DotTone = TranslationPill.Tone

    /// Stop-capsule states: a live session (or one whose capture source was
    /// lost, or a paused one) offers Stop; everything else offers Start.
    let isLiveSession: Bool
    let sessionTitle: String
    let sessionIcon: String
    /// While model discovery is in flight Start is gated (`isCheckingModel`);
    /// Stop must stay reachable from a live session.
    let isSessionDisabled: Bool
    let asrDot: DotTone
    /// The round pause/resume button beside the capsule, shown while a
    /// session is live (`.running` / `.paused`). Hidden in archive mode.
    let showsPauseButton: Bool
    /// The round close (x) button beside the capsule, shown while an
    /// archived session is open in the pane.
    let showsCloseArchive: Bool

    static func map(
        phase: SessionPhase, isCheckingModel: Bool, archiveOpen: Bool = false
    ) -> SidebarStatus {
        let isLive = SessionPhaseMachine.isLive(phase)
        let title = switch phase {
        case .running, .sourceLost, .paused: "Stop session"
        case .starting: "Starting…"
        case .stopping: "Stopping…"
        case .idle, .needsModel, .failed: "Start session"
        }
        let dot: DotTone = switch phase {
        case .running: .green
        case .starting, .stopping: .yellow
        case .paused: .neutral
        case .sourceLost, .failed: .red
        case .idle, .needsModel: .neutral
        }
        // Archive mode: the capsule stays the normal Start session (the
        // action asks to close first) and the round x closes directly.
        // Open implies a non-live phase by construction, so the live
        // presentation above never competes with it.
        return SidebarStatus(
            isLiveSession: isLive,
            sessionTitle: title,
            sessionIcon: isLive ? "stop.fill" : "play.fill",
            isSessionDisabled: phase == .starting || phase == .stopping
                || (isCheckingModel && !isLive),
            asrDot: dot,
            showsPauseButton: phase == .running || phase == .paused,
            showsCloseArchive: archiveOpen && !isLive
        )
    }

    /// The translation row's detail line. The latched Apple fallback stays
    /// visible after the fresh Apple run publishes `.ready` — otherwise
    /// "On-device (fallback)" would flash for under a second and the card
    /// would read as healthy green. The latch never masks failure:
    /// `.unavailable` wins over it, and `.retrying` (external-only) names
    /// the engine — mirroring the dot tones from `TranslationPill.map`.
    static func translationDetail(
        status: TranslationStatus,
        activeEngine: ActiveTranslationEngine,
        fallbackActive: Bool
    ) -> String {
        switch status {
        case .unavailable: "Unavailable"
        case .degraded: "On-device (fallback)"
        case .retrying: "External"
        case .ready, .translating, .idle:
            fallbackActive
                ? "On-device (fallback)"
                : (activeEngine == .apple ? "On-device" : "External")
        }
    }

    /// Names the translation engine for the ENGINES card's row title. The
    /// Apple row names Apple Intelligence when the OS reported the strategy
    /// installed for the current pair; otherwise it names the on-device
    /// model. External runs name `externalProvider` (recorded at attachment
    /// time), never the picker — a mid-session selection change must not
    /// relabel an engine the queue isn't using.
    static func translationEngineName(
        activeEngine: ActiveTranslationEngine,
        externalProvider: TranslationProvider?,
        selectedProvider: TranslationProvider,
        appleHighFidelity: Bool
    ) -> String {
        guard activeEngine == .external else {
            return appleHighFidelity
                ? TranslationTier.appleHighFidelity.name
                : TranslationTier.appleOnDevice.name
        }
        return (externalProvider ?? selectedProvider).shortName
    }
}
