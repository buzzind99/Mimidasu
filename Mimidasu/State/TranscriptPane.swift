import Foundation
import Observation

/// One row's landed translations, owned by that row alone.
///
/// A translation landing mutates this cell instead of the pane's rows, so
/// only the body that reads it re-runs: the transcript row for its own
/// sentence, never the list, the HUD filter, or the overlay. `TranscriptPane`
/// keeps the cell in step with the row's value, so the rows stay the
/// authoritative snapshot every non-observing reader (export, write-back
/// scope, archive re-open) works from.
@Observable
@MainActor
final class TranscriptTranslationCell {
    /// This sentence's translations, at most one per language; the same
    /// value the row carries.
    var translations: [SentenceTranslation]

    init(translations: [SentenceTranslation] = []) {
        self.translations = translations
    }
}

/// The transcript pane's one state module: the rows the pane shows, their
/// sentence-to-position map, the character total, the viewed archive
/// language, and which record fills the pane. It owns the live/archive swap
/// choreography for those facts.
///
/// Effects on other surfaces — lookup anchors, the HUD/overlay visibility,
/// the session clock, and the re-translate lane's epoch — stay with the host
/// that composes the pane. The archive projection keeps the one stored copy
/// of the open summary; `openArchive` joins that copy with these rows.
///
/// Two signals, because the two kinds of change cost differently:
///
/// - `entriesRevision` is structural: a row was appended, or the pane's whole
///   contents were replaced (session begin, record open, clear). Reading
///   `entries` observes it, so every list that renders rows refreshes then.
/// - `landingRevision` is in-place: one row's translation changed. Reading
///   `entries` does *not* observe it; a row observes its own
///   `TranscriptTranslationCell` instead, and the few surfaces whose output
///   depends on landed text read `entriesIncludingLandings`.
@Observable
@MainActor
final class TranscriptPane {
    private let projection: ArchiveProjection

    /// The rows in display order: the live session's append-only feed, or
    /// the opened record's rows. Held untracked so an in-place landing writes
    /// no observed property; structure changes bump `entriesRevision`, which
    /// the row accessors below read.
    @ObservationIgnored private var rows: [SessionEntry] = []

    /// Sentence index → that row's landing cell. Untracked: resolving a cell
    /// is not a read of pane state, reading the cell itself is.
    @ObservationIgnored private var cells: [Int: TranscriptTranslationCell] = [:]

    /// O(1) structural signal: every append/replace/clear bumps it.
    private(set) var entriesRevision = 0

    /// O(1) landing signal: an in-place translation swap bumps it and leaves
    /// `entriesRevision` alone.
    private(set) var landingRevision = 0

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

    /// The rows for a surface that renders structure: appends, a record
    /// opening, a clear. A landed translation never refreshes it — the row
    /// that changed observes its own cell.
    var entries: [SessionEntry] {
        _ = entriesRevision
        return rows
    }

    /// The rows for a surface whose output depends on landed text — the HUD's
    /// completed section and the translation overlay. A landing refreshes it;
    /// so does every structural change.
    var entriesIncludingLandings: [SessionEntry] {
        _ = entriesRevision
        _ = landingRevision
        return rows
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

    /// Clears the pane for a fresh live session: rows, their landing cells,
    /// the position map, the character total, and any archive viewing
    /// override reset; the projection's open summary closes with it.
    func beginLiveSession() {
        projection.closeOpen()
        viewingLanguage = nil
        replaceRows(with: [])
        characterCount = 0
    }

    /// Appends one finalized sentence to the live feed.
    func append(_ sentence: Sentence) {
        positionBySentence[sentence.index] = rows.count
        rows.append(SessionEntry(sentence: sentence))
        cells[sentence.index] = TranscriptTranslationCell()
        characterCount += sentence.text.count
        entriesRevision &+= 1
    }

    /// Swaps one row's translation in place. Returns false when the pane no
    /// longer holds that sentence — cleared or swapped underneath the result.
    ///
    /// The landing mutates the row (the snapshot every non-observing reader
    /// uses) and the row's cell (the value its body observes), then bumps the
    /// landing signal. `entriesRevision` deliberately stays put.
    @discardableResult
    func replaceTranslation(index: Int, translation: SentenceTranslation) -> Bool {
        guard let at = positionBySentence[index] else { return false }
        rows[at].replaceTranslation(translation)
        cells[index]?.translations = rows[at].translations
        landingRevision &+= 1
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

    /// The row's landing cell, so its own body can observe exactly that
    /// sentence's translations. Nil for an index the pane no longer holds.
    func translationCell(for sentenceIndex: Int) -> TranscriptTranslationCell? {
        cells[sentenceIndex]
    }

    // MARK: - Archive record

    /// Opens one stored session into the pane: its rows seed the feed, the
    /// position map, the landing cells, and the character total; the viewing
    /// override resets to the record's stored target. Returns false when the
    /// store cannot load it — the pane and its record stay untouched.
    @discardableResult
    func openSession(id: Int64) -> Bool {
        guard let loaded = projection.open(id: id) else { return false }
        viewingLanguage = nil
        replaceRows(with: loaded.entries)
        characterCount = loaded.characterCount
        return true
    }

    /// Closes the opened record: the pane empties (no restore) and the
    /// projection drops its open summary.
    func closeSession() {
        projection.closeOpen()
        viewingLanguage = nil
        replaceRows(with: [])
        characterCount = 0
    }

    /// Selects the opened record's viewing language — view-only: switching
    /// never mutates stored translations.
    func selectViewingLanguage(_ lang: String) {
        viewingLanguage = lang
    }

    // MARK: - Rows

    /// Replaces the pane's whole contents (a record opening or a clear): the
    /// rows, their landing cells seeded from the rows they replace, and the
    /// position map. One structural bump, whatever the row count.
    private func replaceRows(with newRows: [SessionEntry]) {
        rows = newRows
        cells = Dictionary(
            newRows.map { entry in
                (entry.sentence.index, TranscriptTranslationCell(translations: entry.translations))
            },
            uniquingKeysWith: { first, _ in first }
        )
        positionBySentence.removeAll()
        for (position, entry) in newRows.enumerated() {
            positionBySentence[entry.sentence.index] = position
        }
        entriesRevision &+= 1
    }
}
