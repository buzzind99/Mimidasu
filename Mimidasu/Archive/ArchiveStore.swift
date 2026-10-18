import Foundation

/// The session archive's domain façade over `ArchiveDatabase`: the store the
/// app writes through while a session runs and the archive window reads.
///
/// Writes report success so the caller can latch a session-scoped
/// "not persisted" state on the first failure instead of retrying per
/// sentence; reads map failures to empty results, and `isDegraded` exposes
/// the terminal open failure for the window's unavailable state. Every call
/// is synchronous under the database's mutex — the same main-actor contract
/// `FavoritesStore` has, valid because per-sentence writes are ms-scale.
final class ArchiveStore: Sendable {
    /// The recents cap: the newest 10 unsaved sessions are kept, older ones
    /// are evicted silently at finalize/sweep. Saved sessions never count.
    static let recentCap = 10

    /// Authored user data that must survive a clean, so the archive lives in
    /// Application Support in **both** configurations — like favorites, and
    /// unlike the prepared dictionary artifacts.
    static var defaultLocation: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Mimidasu/archives.sqlite")
    }

    private let database: ArchiveDatabase

    /// The stored form of a user-entered session name: trimmed; empty (or
    /// whitespace-only) clears back to the auto-title.
    static func normalizedName(_ name: String?) -> String? {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == true ? nil : trimmed
    }

    /// `location` is the whole test-isolation seam — the default is the real
    /// production file, so a test that forgets to inject one writes to the
    /// developer's own archive.
    init(location: URL = ArchiveStore.defaultLocation) {
        database = ArchiveDatabase(location: location)
    }

    /// True when the underlying database is terminally degraded.
    var isDegraded: Bool {
        database.isDegraded
    }

    // MARK: - Write path (live session)

    /// Appends a finalized sentence. `sessionID` nil means this is the
    /// session's first sentence: the `recording` row is inserted with it and
    /// the new id returned for the caller to cache. Nil result = the write
    /// failed (degraded or a transient fault).
    @discardableResult
    func append(sentence: Sentence, sessionID: Int64?, metadata: SessionMetadata) -> Int64? {
        do {
            let id: Int64 = if let sessionID {
                sessionID
            } else {
                try database.insertRecordingSession(
                    startedAt: metadata.startedAt,
                    targetLang: metadata.targetLang,
                    model: metadata.model,
                    chunkMS: metadata.chunkMS
                )
            }
            try database.insertSentence(sessionID: id, sentence: sentence)
            return id
        } catch {
            return nil
        }
    }

    /// Stores a landed translation under `(session, index, lang)`.
    @discardableResult
    func upsert(
        translation: SentenceTranslation, index: Int, session: Int64
    ) -> Bool {
        do {
            try database.upsertTranslation(
                sessionID: session, index: index, translation: translation
            )
            return true
        } catch {
            return false
        }
    }

    /// Pause/resume transition: the session's accumulated paused time.
    @discardableResult
    func syncPaused(session: Int64, pausedMS: Int) -> Bool {
        do {
            try database.updatePaused(sessionID: session, pausedMS: pausedMS)
            return true
        } catch {
            return false
        }
    }

    /// Finalizes a stopped session, then enforces the recents cap.
    @discardableResult
    func finalize(session: Int64, durationMS: Int, saved: Bool) -> Bool {
        do {
            try database.finalize(
                sessionID: session, endedAt: Date(), durationMS: durationMS, saved: saved
            )
            try database.enforceRecentCap(keeping: Self.recentCap)
            return true
        } catch {
            return false
        }
    }

    /// Launch sweep: `recording` rows left by an unclean exit become
    /// `interrupted`, then the recents cap is enforced.
    @discardableResult
    func sweepInterrupted() -> Bool {
        do {
            try database.sweepInterrupted(endedAt: Date())
            try database.enforceRecentCap(keeping: Self.recentCap)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Archive window

    /// Every stored session (finalized + interrupted), newest first; Saved
    /// rows carry their flag for the window's section split.
    func list() -> [ArchivedSessionSummary] {
        (try? database.summaries()) ?? []
    }

    /// One session with its reconstructed rows; nil when unknown or unreadable.
    func load(id: Int64) -> ArchivedSession? {
        do {
            guard let summary = try database.summary(id: id) else { return nil }
            let entries = try database.entries(sessionID: id)
            return ArchivedSession(summary: summary, entries: entries)
        } catch {
            return nil
        }
    }

    /// One session's list-row summary without loading its sentences — the
    /// opened banner's refresh read after a landed result.
    func summary(id: Int64) -> ArchivedSessionSummary? {
        (try? database.summary(id: id)) ?? nil
    }

    /// Registers a language on the session (idempotent). Membership persists
    /// from the moment the language is added, before any translation lands;
    /// it is never removed in v1.
    @discardableResult
    func addLanguage(id: Int64, lang: String) -> Bool {
        do {
            try database.insertLanguage(sessionID: id, lang: lang)
            return true
        } catch {
            return false
        }
    }

    /// Stores the trimmed name; empty clears back to the auto-title.
    @discardableResult
    func rename(id: Int64, name: String?) -> Bool {
        do {
            try database.rename(id: id, name: Self.normalizedName(name))
            return true
        } catch {
            return false
        }
    }

    /// Promotes a recent to the permanent Saved tier.
    @discardableResult
    func promote(id: Int64) -> Bool {
        do {
            try database.promote(id: id)
            return true
        } catch {
            return false
        }
    }

    /// Deletes a session and, by cascade, its sentences and translations.
    @discardableResult
    func delete(id: Int64) -> Bool {
        do {
            try database.delete(id: id)
            return true
        } catch {
            return false
        }
    }
}
