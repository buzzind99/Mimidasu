import Foundation
import Observation

/// The transcript pane's one state module: the rows the pane shows, their
/// sentence-to-position map, the character total, the viewed archive
/// language, and which record fills the pane. It owns the live/archive swap
/// choreography for those facts.
///
/// Effects on other surfaces — lookup anchors, the HUD/overlay visibility,
/// the session clock, and the re-translate lane's epoch — stay with the host
/// that composes the pane. The archive projection keeps the one stored copy
/// of the open summary; `openArchive` joins that copy with these rows.
@Observable
@MainActor
final class TranscriptPane {
    private let projection: ArchiveProjection

    /// The rows in display order: the live session's append-only feed, or
    /// the opened record's rows.
    private(set) var entries: [SessionEntry] = [] {
        didSet { entriesRevision &+= 1 }
    }

    /// O(1) transcript-change signal: every `entries` mutation bumps it.
    private(set) var entriesRevision = 0

    /// Σ sentence text lengths (translations excluded), maintained
    /// incrementally instead of re-summing the transcript per render.
    private(set) var characterCount = 0

    /// The opened record's viewing-language override (BCP-47 code), or nil
    /// to show its stored target. Live mode has no override.
    private(set) var viewingLanguage: String?

    /// Sentence index → position in `entries`. Entries are append-only within
    /// a session (positions never shift), so a landing resolves in O(1)
    /// instead of scanning the transcript.
    private var positionBySentence: [Int: Int] = [:]

    init(projection: ArchiveProjection) {
        self.projection = projection
    }

    /// The stored session opened read-only in the pane, or nil.
    var openSessionID: Int64? {
        projection.openSummary?.id
    }

    /// The opened record: the projection's one summary copy joined with the
    /// pane's rows.
    var openArchive: ArchivedSession? {
        guard let summary = projection.openSummary else { return nil }
        return ArchivedSession(summary: summary, entries: entries)
    }

    // MARK: - Live feed

    /// Clears the pane for a fresh live session: rows, the position map, the
    /// character total, and any archive viewing override reset; the
    /// projection's open summary closes with it.
    func beginLiveSession() {
        projection.closeOpen()
        viewingLanguage = nil
        entries.removeAll()
        positionBySentence.removeAll()
        characterCount = 0
    }

    /// Appends one finalized sentence to the live feed.
    func append(_ sentence: Sentence) {
        positionBySentence[sentence.index] = entries.count
        entries.append(SessionEntry(sentence: sentence))
        characterCount += sentence.text.count
    }

    /// Swaps one row's translation in place. Returns false when the pane no
    /// longer holds that sentence — cleared or swapped underneath the result.
    @discardableResult
    func replaceTranslation(index: Int, translation: SentenceTranslation) -> Bool {
        guard let at = positionBySentence[index] else { return false }
        entries[at].replaceTranslation(translation)
        return true
    }

    /// A bulk run's landing: swaps the row only while the pane still shows
    /// the run's session.
    @discardableResult
    func replaceTranslation(
        in sessionID: Int64, index: Int, translation: SentenceTranslation
    ) -> Bool {
        guard openSessionID == sessionID else { return false }
        return replaceTranslation(index: index, translation: translation)
    }

    // MARK: - Archive record

    /// Opens one stored session into the pane: its rows seed the feed, the
    /// position map, and the character total; the viewing override resets to
    /// the record's stored target. Returns false when the store cannot load
    /// it — the pane and its record stay untouched.
    @discardableResult
    func openSession(id: Int64) -> Bool {
        guard let loaded = projection.open(id: id) else { return false }
        viewingLanguage = nil
        entries = loaded.entries
        positionBySentence = Dictionary(
            uniqueKeysWithValues: loaded.entries.enumerated().map { position, entry in
                (entry.sentence.index, position)
            }
        )
        characterCount = loaded.characterCount
        return true
    }

    /// Closes the opened record: the pane empties (no restore) and the
    /// projection drops its open summary.
    func closeSession() {
        projection.closeOpen()
        viewingLanguage = nil
        entries.removeAll()
        positionBySentence.removeAll()
        characterCount = 0
    }

    /// Selects the opened record's viewing language — view-only: switching
    /// never mutates stored translations.
    func selectViewingLanguage(_ lang: String) {
        viewingLanguage = lang
    }
}
