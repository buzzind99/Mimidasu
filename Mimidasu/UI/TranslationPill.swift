import SwiftUI

/// Pure translation-status presentation mapping — a `Tone` plus the engine
/// label — derived from status × active engine × fallback latch. The
/// sidebar's ENGINES translation row consumes `map`'s tone for its status
/// dot (via `SidebarStatus.DotTone`); unit tests pin the mapping.
struct TranslationPill: Equatable {
    /// The status-dot scale. The sidebar's dot reads it directly — see
    /// `SidebarStatus.DotTone`.
    enum Tone: Equatable {
        case green, yellow, red, neutral
    }

    let tone: Tone
    /// "On-device" or "External" — the engine label for every status. Not
    /// rendered in production: the sidebar's row reads the tone only, and
    /// the sidebar's own detail line words the states differently. The
    /// label survives for the mapping's own sake and for its tests.
    let label: String

    static func map(
        status: TranslationStatus,
        activeEngine: ActiveTranslationEngine,
        fallbackActive: Bool = false
    ) -> TranslationPill {
        switch status {
        case .ready, .translating:
            // Latched on Apple after an external failure: degraded, not healthy.
            TranslationPill(
                tone: fallbackActive ? .yellow : .green,
                label: engineLabel(activeEngine)
            )
        case .retrying:
            // Retries only happen on external engines.
            TranslationPill(tone: .yellow, label: "External")
        case .degraded:
            // Degraded means latched onto Apple on-device.
            TranslationPill(tone: .yellow, label: "On-device")
        case .unavailable:
            TranslationPill(tone: .red, label: engineLabel(activeEngine))
        case .idle:
            TranslationPill(tone: .neutral, label: engineLabel(activeEngine))
        }
    }

    private static func engineLabel(_ engine: ActiveTranslationEngine) -> String {
        engine == .external ? "External" : "On-device"
    }
}
