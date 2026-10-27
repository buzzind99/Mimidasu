import Foundation
import Observation

/// What one detached row query hands back to the main actor.
///
/// An enum because the three landings are genuinely different: a value, a
/// cancelled query whose row must collapse, and a typed failure. Mirrors
/// `DictionarySearchResponse`. `Sendable` on purpose — the query runs on a
/// detached task, where a raw untyped error cannot cross (it is not
/// `Sendable`), so `DictionaryError` crosses in its place; the mapping
/// (cancellation first, then the typed fault, then the total
/// `DictionaryError` wrap) happens inside the detached closure. Declared at
/// file scope so it stays nonisolated and can be built off the main actor.
private enum RowLanding: Sendable {
    case resolved(LookupResult?)
    case cancelled
    case failure(DictionaryError)
}

/// Per-row expansion state for the dictionary windows' rows: which cards are
/// open and what each one's live JMDict lookup resolved to.
///
/// State is keyed by a row key the host derives. The Favorites window keys its
/// rows by headword — the store keeps one row per word — while the search
/// window keys by entry id, because two of its rows can share a headword (two
/// kana-only entries spelled ポン, say) and the headword cannot tell them
/// apart. A single phase plus a single generation token would let one row's
/// collapse drop a sibling's in-flight result; keying by row scopes the
/// staleness check to the row that owns it — a slow query landing after its
/// own row collapsed (or after the word left favorites) is dropped, and no
/// neighbor is affected.
///
/// Deliberately *above* the store and off `AppModel`: an expansion must not
/// re-pin the sidebar card or re-anchor the popover, so it reaches
/// `JMDictLookup` directly instead of the tap-to-pin session.
@Observable
@MainActor
final class FavoritesLookupState {
    enum Phase: Equatable {
        case idle
        case loading
        case resolved(LookupResult)
        case notFound
        case failed(String)
    }

    /// Open rows, newest first; each row toggles only its own key.
    private(set) var expanded: [String] = []
    /// Per-row phase. Absent means never expanded this session.
    private(set) var phases: [String: Phase] = [:]

    /// Monotonic per row: each expand bumps its token, so a result that
    /// lands after a collapse (or a second expand) is discarded.
    private var generations: [String: Int] = [:]

    /// Results dropped by the generation guard — the guard's observable half
    /// and its only writer. A discarded landing writes nothing, so this
    /// counter is the only trace one leaves: a test can wait for it
    /// deterministically instead of guessing when a dropped write would have
    /// arrived, and a deleted guard turns that wait into a failure.
    private(set) var discardedLandings = 0

    private let lookupRow: @Sendable (LookupCandidate) throws -> LookupResult?

    init(lookup: JMDictLookup) {
        let engine = lookup
        lookupRow = { candidate in try engine.lookup(candidate) }
    }

    /// Test seam: the row query without a database, so a fault (including
    /// cancellation) is reachable without one. Production uses `init(lookup:)`.
    init(lookupRow: @escaping @Sendable (LookupCandidate) throws -> LookupResult?) {
        self.lookupRow = lookupRow
    }

    // MARK: - Row keys

    func isExpanded(key: String) -> Bool {
        expanded.contains(key)
    }

    func phase(forKey key: String) -> Phase {
        phases[key] ?? .idle
    }

    /// Expands (and looks up) or collapses the row. Collapsing drops the
    /// row's state entirely so a reopen starts from a fresh query.
    func toggle(key: String, candidate: LookupCandidate) {
        if isExpanded(key: key) {
            expanded.removeAll { open in open == key }
            phases[key] = nil
            generations[key, default: 0] += 1
            return
        }
        expanded.insert(key, at: 0)
        expand(key: key, candidate: candidate)
    }

    /// Drops a deleted row's phase and in-flight token.
    func remove(key: String) {
        expanded.removeAll { open in open == key }
        phases[key] = nil
        generations[key, default: 0] += 1
    }

    // MARK: - Favorite rows

    /// The Favorites window's spelling of the key API: its rows are its words
    /// — the store keeps one row per headword — so the headword is the row
    /// key. The search window derives its own keys (entry ids) and calls the
    /// key methods directly.
    func isExpanded(_ word: FavoriteWord) -> Bool {
        isExpanded(key: word.headword)
    }

    func phase(for word: FavoriteWord) -> Phase {
        phase(forKey: word.headword)
    }

    func toggle(_ word: FavoriteWord) {
        toggle(
            key: word.headword,
            candidate: LookupCandidate(text: word.headword, reading: word.reading)
        )
    }

    /// Drops every expanded row and its phase, wholesale rather than per row:
    /// the window closed, and its next open must find nothing left to collapse.
    /// Each row that had state has its generation bumped, so a lookup still in
    /// flight across the close is discarded instead of re-populating a row the
    /// user is no longer looking at.
    func reset() {
        for key in expanded {
            generations[key, default: 0] += 1
        }
        expanded.removeAll()
        phases.removeAll()
    }

    private func expand(key: String, candidate: LookupCandidate) {
        let generation = (generations[key] ?? 0) + 1
        generations[key] = generation
        phases[key] = .loading
        let row = lookupRow
        Task { @MainActor [weak self] in
            // Detached by design, inheriting no cancellation: collapse, reset,
            // and remove bump the generation instead of cancelling, so rapid
            // cycles pile serial work behind the engine while only the latest
            // lands.
            let landing: RowLanding = await Task.detached(
                priority: .userInitiated
            ) {
                do {
                    return try .resolved(row(candidate))
                } catch is CancellationError {
                    // Intercepted before the typed wrap: a cancelled query is
                    // not a failure, and `DictionaryError` would erase the
                    // distinction into `.internalError`.
                    return .cancelled
                } catch let error as DictionaryError {
                    return .failure(error)
                } catch {
                    return .failure(DictionaryError(error))
                }
            }.value
            guard let self else { return }
            guard generations[key] == generation else {
                discardedLandings += 1
                return
            }
            switch landing {
            case let .resolved(resolved):
                phases[key] = resolved.map(Phase.resolved) ?? .notFound
            case .cancelled:
                // A cancelled query means the lookup was torn down, not
                // that it failed: collapse the row so it reads as never
                // opened rather than as failed. Writes no counter — the
                // generation guard above is its only writer.
                expanded.removeAll { open in open == key }
                phases[key] = nil
            case let .failure(fault):
                phases[key] = .failed(
                    fault.errorDescription ?? fault.localizedDescription
                )
            }
        }
    }
}
