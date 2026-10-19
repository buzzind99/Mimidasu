import Foundation
import Observation

/// The archive window's cached read surface over `ArchiveStore`: it owns the
/// current summary list, a typed availability for the window's unavailable
/// state, and a revision bumped by every landed mutation, so SwiftUI bodies
/// read cached rows instead of re-running SQL per evaluation.
@MainActor
@Observable
final class ArchiveReadModel {
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

    private(set) var summaries: [ArchivedSessionSummary] = []
    private(set) var availability: Availability = .available
    private(set) var revision = 0

    var isAvailable: Bool {
        availability == .available
    }

    init(
        store: ArchiveStore,
        loadSummaries: (@MainActor () -> Result<[ArchivedSessionSummary], ArchiveStore.ReadFailure>)? = nil,
        loadSummary: (@MainActor (Int64) -> Result<ArchivedSessionSummary?, ArchiveStore.ReadFailure>)? = nil
    ) {
        self.store = store
        self.loadSummaries = loadSummaries ?? { store.loadSummaries() }
        self.loadSummary = loadSummary ?? { id in store.summaryResult(id: id) }
        reload()
    }

    /// Full re-read: success replaces the rows, a failure keeps the previous
    /// rows and records why. Reads never touch the revision.
    func reload() {
        guard !store.isDegraded else {
            availability = .openFailed
            return
        }
        switch loadSummaries() {
        case let .success(rows):
            summaries = rows
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
    /// its list position, or drops it when the store no longer holds it.
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

    // MARK: - Mutations

    /// A recording row is never listed, so the append returns its session id
    /// without touching the cache or the revision.
    @discardableResult
    func append(sentence: Sentence, sessionID: Int64?, metadata: SessionMetadata) -> Int64? {
        store.append(sentence: sentence, sessionID: sessionID, metadata: metadata)
    }

    /// A landed translation bumps the revision and refreshes its row when the
    /// row is currently listed.
    @discardableResult
    func upsert(translation: SentenceTranslation, index: Int, session: Int64) -> Bool {
        guard store.upsert(translation: translation, index: index, session: session) else {
            return false
        }
        revision += 1
        refreshIfListed(id: session)
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
        revision += 1
        reload()
        return true
    }

    /// The sweep flips leftover recording rows to interrupted: full re-read.
    @discardableResult
    func sweepInterrupted() -> Bool {
        guard store.sweepInterrupted() else { return false }
        revision += 1
        reload()
        return true
    }

    /// A membership add bumps the revision and refreshes its row when listed.
    @discardableResult
    func addLanguage(id: Int64, lang: String) -> Bool {
        guard store.addLanguage(id: id, lang: lang) else { return false }
        revision += 1
        refreshIfListed(id: id)
        return true
    }

    /// A stored name bumps the revision and refreshes its row when listed.
    @discardableResult
    func rename(id: Int64, name: String?) -> Bool {
        guard store.rename(id: id, name: name) else { return false }
        revision += 1
        refreshIfListed(id: id)
        return true
    }

    /// A promotion bumps the revision and refreshes its row when listed.
    @discardableResult
    func promote(id: Int64) -> Bool {
        guard store.promote(id: id) else { return false }
        revision += 1
        refreshIfListed(id: id)
        return true
    }

    /// A delete bumps the revision and drops the row from the cache without
    /// re-reading.
    @discardableResult
    func delete(id: Int64) -> Bool {
        guard store.delete(id: id) else { return false }
        revision += 1
        summaries.removeAll { row in row.id == id }
        return true
    }

    // MARK: - Cache

    /// Refreshes a row only when the cache currently lists it.
    private func refreshIfListed(id: Int64) {
        guard summaries.contains(where: { row in row.id == id }) else { return }
        refreshRow(id: id)
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
