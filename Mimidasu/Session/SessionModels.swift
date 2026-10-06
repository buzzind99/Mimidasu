import Foundation

/// A finalized sentence. Immutable value type; crosses thread boundaries.
struct Sentence: Identifiable, Equatable, Sendable {
    /// Stable index; keys JP↔EN alignment.
    let index: Int
    /// Session-relative start time in seconds (first chunk's sample offset).
    let startS: Double
    /// Session-relative end time in seconds (last chunk's offset + duration).
    let endS: Double
    /// Per-sentence language (BCP-47, e.g. "ja").
    let lang: String
    let text: String

    var id: Int {
        index
    }
}

/// A translation for a sentence. A row carries at most one of these per
/// language (`SessionEntry.replaceTranslation` is the only mutator), which is
/// also what keeps the future multi-target case to one line per language.
struct SentenceTranslation: Equatable, Codable, Sendable {
    let lang: String
    let text: String
}

/// ASR streaming events delivered from the ASR queue.
enum ASREvent: Sendable {
    case partial(text: String)
    case final(text: String, startSample: Int, endSample: Int, lang: String)
}

/// A complete session row: sentence + its (possibly empty) translations.
/// Display strings (timestamps, joined translations) are precomputed at
/// mutation time so row rendering never re-joins or re-formats.
struct SessionEntry: Identifiable, Equatable, Sendable {
    let sentence: Sentence
    var translations: [SentenceTranslation] = []
    /// Formatted once at init for cheap row rendering.
    let startTimestamp: String
    let endTimestamp: String
    /// `nil` while untranslated; the row renders a placeholder instead.
    private(set) var joinedTranslations: String?

    init(sentence: Sentence) {
        self.sentence = sentence
        startTimestamp = SessionClock.timestamp(sentence.startS)
        endTimestamp = SessionClock.timestamp(sentence.endS)
    }

    /// The only mutator, so `translations` holds at most one entry per
    /// language by construction: a language already present is swapped in
    /// place, a new one is appended. Every result therefore lands as the fresh
    /// text — a repeat, a replay, or a manual retry can never grow an `" / "`
    /// pileup on the row.
    mutating func replaceTranslation(_ translation: SentenceTranslation) {
        if let at = translations.firstIndex(where: { existing in
            existing.lang == translation.lang
        }) {
            translations[at] = translation
        } else {
            translations.append(translation)
        }
        joinedTranslations = translations.map(\.text).joined(separator: " / ")
    }

    var id: Int {
        sentence.index
    }
}

/// Session metadata captured at Start.
struct SessionMetadata: Equatable, Codable {
    var startedAt: Date
    var sourceLang: String?
    var targetLang: String?
    var model: String?
    var chunkMS: Int
}

enum SessionClock {
    static let sampleRate: Double = 16000

    static func seconds(_ sample: Int) -> Double {
        Double(sample) / sampleRate
    }

    /// Formats session-relative seconds as `HH:MM:SS` (or `MM:SS` under 1 h).
    static func timestamp(_ seconds: Double) -> String {
        let total = Int(max(0, seconds.rounded(.down)))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%02d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }
}

extension Notification.Name {
    /// Posted from `AppDelegate.applicationShouldTerminate` (which returns
    /// `.terminateLater`) so `AppModel` can wind the live session down on quit.
    static let mimidasuAppWillTerminate = Notification.Name("MimidasuAppWillTerminate")

    /// Posted by `AppModel` once quit-time teardown finished (session wound
    /// down, warm ASR engine released). `AppDelegate` replies to
    /// `applicationShouldTerminate` on receiving it — or when its watchdog
    /// fires, whichever comes first.
    static let mimidasuTerminationTeardownComplete =
        Notification.Name("MimidasuTerminationTeardownComplete")

    /// Posted by `AppModel` whenever `hudVisible` flips. The HUD panel is
    /// driven from here rather than a scene-scoped `onChange` because two
    /// of the flag's mutation sites (the HUD's own close button, the
    /// translation overlay's subtitle button) sit on panels that outlive
    /// the main window.
    static let mimidasuHUDVisibilityDidChange =
        Notification.Name("MimidasuHUDVisibilityDidChange")

    /// Posted by `AppModel` whenever `translationOverlayVisible` flips. The
    /// overlay window is driven from here rather than a scene-scoped
    /// `onChange` because two of the flag's mutation sites (the HUD's
    /// translate button, the overlay's own close button) sit on panels
    /// that outlive the main window (the third, the sidebar's overlay
    /// master switch, lives in the main window itself).
    static let mimidasuTranslationOverlayVisibilityDidChange =
        Notification.Name("MimidasuTranslationOverlayVisibilityDidChange")
}
