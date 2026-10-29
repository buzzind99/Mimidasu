import Foundation
import Observation

/// The archive window's cached read surface over `ArchiveStore`: it owns the
/// current summary list, the one opened session's summary, and a typed
/// availability for the window's unavailable state. SwiftUI bodies read
/// cached rows instead of re-running SQL per evaluation, and every landed
/// write that affects a listed or opened session refreshes both copies from
/// one summary read.
@MainActor
@Observable
final class ArchiveProjection {
    /// Whether the cached list is trustworthy: readable, terminally
    /// unopenable, or faulted on the last read.
    enum Availability: Equatable {
        case available
        case openFailed
        case readFailed
    }

    private let store: ArchiveStore
    private let loadSummaries: @MainActor () -> Result<[ArchivedSessionSummary], ArchiveStore.ReadFailure>
    private let loadSummary: @MainActor (Int64) -> Result<ArchivedSessionSummary?, ArchiveStore.ReadFailure>
    private let loadSession: @MainActor (Int64) -> ArchivedSession?

    private(set) var summaries: [ArchivedSessionSummary] = []
    /// The one stored copy of the session opened in the transcript pane; the
    /// pane's entries stay in `AppModel`.
    private(set) var openSummary: ArchivedSessionSummary?
    private(set) var availability: Availability = .available
    var isAvailable: Bool {
        availability == .available
    }

    init(
        store: ArchiveStore,
        loadSummaries: (@MainActor () -> Result<[ArchivedSessionSummary], ArchiveStore.ReadFailure>)? = nil,
        loadSummary: (@MainActor (Int64) -> Result<ArchivedSessionSummary?, ArchiveStore.ReadFailure>)? = nil,
        loadSession: (@MainActor (Int64) -> ArchivedSession?)? = nil
    ) {
        self.store = store
        self.loadSummaries = loadSummaries ?? { store.loadSummaries() }
        self.loadSummary = loadSummary ?? { id in store.summaryResult(id: id) }
        self.loadSession = loadSession ?? { id in store.load(id: id) }
        reload()
    }

    /// Full re-read: success replaces the rows and syncs the opened summary
    /// when it is still listed; a failure keeps the previous rows and records
    /// why. Reads never write to the store.
    func reload() {
        guard !store.isDegraded else {
            availability = .openFailed
            return
        }
        switch loadSummaries() {
        case let .success(rows):
            summaries = rows
            if let openSummary, let refreshed = rows.first(where: { row in row.id == openSummary.id }) {
                self.openSummary = refreshed
            }
            availability = .available
        case .failure(.openFailed):
            availability = .openFailed
        case .failure(.readFailed):
            availability = .readFailed
        }
    }

    /// The window's on-appear retry: a no-op unless the last read faulted.
    func reloadIfUnavailable() {
        guard availability == .readFailed else { return }
        reload()
    }

    /// Re-reads one list row: replaces it in place, inserts a missing row at
    /// its list position, or drops it when the store no longer holds it. The
    /// availability tests pin the typed-read failure mapping through it;
    /// production writes use `refreshTouched`.
    func refreshRow(id: Int64) {
        guard !store.isDegraded else {
            availability = .openFailed
            return
        }
        switch loadSummary(id) {
        case let .success(summary):
            if let summary {
                place(summary)
            } else {
                summaries.removeAll { row in row.id == id }
            }
            if availability == .readFailed {
                availability = .available
            }
        case .failure(.openFailed):
            availability = .openFailed
        case .failure(.readFailed):
            availability = .readFailed
        }
    }

    // MARK: - Open session

    /// Opens one stored session: loads its rows, stores its summary as the
    /// one open copy, and refreshes a listed row from that same value. An
    /// unlisted session is not inserted into the list. Returns nil when the
    /// store cannot load it; the failure leaves availability untouched.
    func open(id: Int64) -> ArchivedSession? {
        guard let loaded = loadSession(id) else { return nil }
        openSummary = loaded.summary
        if summaries.contains(where: { row in row.id == loaded.id }) {
            place(loaded.summary)
        }
        return loaded
    }

    /// Clears the opened summary without touching the store.
    func closeOpen() {
        openSummary = nil
    }

    // MARK: - Mutations

    /// A recording row is never listed, so the append returns its session id
    /// without touching the cache.
    @discardableResult
    func append(sentence: Sentence, sessionID: Int64?, metadata: SessionMetadata) -> Int64? {
        store.append(sentence: sentence, sessionID: sessionID, metadata: metadata)
    }

    /// A landed translation refreshes its listed row and/or the open summary
    /// from one read.
    @discardableResult
    func upsert(translation: SentenceTranslation, index: Int, session: Int64) -> Bool {
        guard store.upsert(translation: translation, index: index, session: session) else {
            return false
        }
        refreshTouched(id: session)
        return true
    }

    /// Live pause bookkeeping never changes what the list shows.
    @discardableResult
    func syncPaused(session: Int64, pausedMS: Int) -> Bool {
        store.syncPaused(session: session, pausedMS: pausedMS)
    }

    /// A finalized session joins the list: full re-read.
    @discardableResult
    func finalize(session: Int64, durationMS: Int, saved: Bool) -> Bool {
        guard store.finalize(session: session, durationMS: durationMS, saved: saved) else {
            return false
        }
        reload()
        return true
    }

    /// The sweep flips leftover recording rows to interrupted: full re-read.
    @discardableResult
    func sweepInterrupted() -> Bool {
        guard store.sweepInterrupted() else { return false }
        reload()
        return true
    }

    /// A membership add refreshes its listed row and/or the open summary from
    /// one read.
    @discardableResult
    func addLanguage(id: Int64, lang: String) -> Bool {
        guard store.addLanguage(id: id, lang: lang) else { return false }
        refreshTouched(id: id)
        return true
    }

    /// A stored name refreshes its listed row and/or the open summary from
    /// one read.
    @discardableResult
    func rename(id: Int64, name: String?) -> Bool {
        guard store.rename(id: id, name: name) else { return false }
        refreshTouched(id: id)
        return true
    }

    /// A promotion refreshes its listed row and/or the open summary from one
    /// read.
    @discardableResult
    func promote(id: Int64) -> Bool {
        guard store.promote(id: id) else { return false }
        refreshTouched(id: id)
        return true
    }

    /// A delete drops the row from the cache without re-reading; an opened
    /// copy of the same session clears with it.
    @discardableResult
    func delete(id: Int64) -> Bool {
        guard store.delete(id: id) else { return false }
        summaries.removeAll { row in row.id == id }
        if openSummary?.id == id {
            openSummary = nil
        }
        return true
    }

    // MARK: - Cache

    /// The one-read rule for a write that touched `id`: when the session is
    /// listed or open, one summary read updates both copies from one value;
    /// when it is neither, nothing is read. Internal so the read-count
    /// contract can be pinned at the seam.
    func refreshTouched(id: Int64) {
        let wasListed = summaries.contains { row in row.id == id }
        let wasOpen = openSummary?.id == id
        guard wasListed || wasOpen else { return }
        switch loadSummary(id) {
        case let .success(summary):
            if let summary {
                if wasListed {
                    place(summary)
                }
                if wasOpen {
                    openSummary = summary
                }
            } else if wasListed {
                summaries.removeAll { row in row.id == id }
            }
            if wasListed, availability == .readFailed {
                availability = .available
            }
        case .failure(.openFailed):
            availability = .openFailed
        case .failure(.readFailed):
            if wasListed {
                availability = .readFailed
            }
        }
    }

    /// Replaces the row with `summary.id` in place, or inserts one at its
    /// `startedAt` DESC / `id` DESC position when the cache doesn't hold it.
    private func place(_ summary: ArchivedSessionSummary) {
        if let index = summaries.firstIndex(where: { row in row.id == summary.id }) {
            summaries[index] = summary
            return
        }
        let insertion = summaries.firstIndex { row in
            row.startedAt < summary.startedAt
                || (row.startedAt == summary.startedAt && row.id < summary.id)
        } ?? summaries.endIndex
        summaries.insert(summary, at: insertion)
    }
}
