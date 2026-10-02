import Foundation
import Observation

/// Per-row expansion state for the Favorites window: which cards are open and
/// what each one's live JMDict lookup resolved to.
///
/// State is keyed by headword, not held once for the window, because the list
/// expands any number of rows at once. A single phase plus a single
/// generation token would let one row's collapse drop a sibling's in-flight
/// result; keying by headword scopes the staleness check to the row that owns
/// it — a slow query landing after its own row collapsed (or after the word
/// left favorites) is dropped, and no neighbor is affected.
///
/// Deliberately *above* the store and off `AppModel`: an expansion must not
/// re-pin the sidebar card or re-anchor the popover, so it reaches
/// `JMDictLookup` directly and never `runLookup`/`presentLookup`.
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

    /// Open headwords, newest first; each row toggles only its own key.
    private(set) var expanded: [String] = []
    /// Per-headword phase. Absent means never expanded this session.
    private(set) var phases: [String: Phase] = [:]

    /// Monotonic per headword: each expand bumps its token, so a result that
    /// lands after a collapse (or a second expand) is discarded.
    private var generations: [String: Int] = [:]

    private let lookup: JMDictLookup

    init(lookup: JMDictLookup) {
        self.lookup = lookup
    }

    func isExpanded(_ word: FavoriteWord) -> Bool {
        expanded.contains(word.headword)
    }

    func phase(for word: FavoriteWord) -> Phase {
        phases[word.headword] ?? .idle
    }

    /// Expands (and looks up) or collapses the row. Collapsing drops the
    /// row's state entirely so a reopen starts from a fresh query.
    func toggle(_ word: FavoriteWord) {
        if isExpanded(word) {
            expanded.removeAll { headword in headword == word.headword }
            phases[word.headword] = nil
            generations[word.headword, default: 0] += 1
            return
        }
        expanded.insert(word.headword, at: 0)
        expand(word)
    }

    /// Drops every expanded row and its phase, wholesale rather than per row:
    /// the window closed, and its next open must find nothing left to collapse.
    /// Each row that had state has its generation bumped, so a lookup still in
    /// flight across the close is discarded instead of re-populating a row the
    /// user is no longer looking at.
    func reset() {
        for headword in expanded {
            generations[headword, default: 0] += 1
        }
        expanded.removeAll()
        phases.removeAll()
    }

    /// Drops a deleted row's phase and in-flight token.
    func remove(headword: String) {
        expanded.removeAll { open in open == headword }
        phases[headword] = nil
        generations[headword, default: 0] += 1
    }

    private func expand(_ word: FavoriteWord) {
        generations[word.headword, default: 0] += 1
        let generation = generations[word.headword] ?? 0
        phases[word.headword] = .loading
        let engine = lookup
        let candidate = LookupCandidate(text: word.headword, reading: word.reading)
        Task { [weak self] in
            let result: Result<LookupResult?, Error> = await Task.detached(
                priority: .userInitiated
            ) {
                do {
                    return try .success(engine.lookup(candidate))
                } catch {
                    return .failure(error)
                }
            }.value
            guard let self, generations[word.headword] == generation else { return }
            switch result {
            case let .success(resolved):
                phases[word.headword] = resolved.map(Phase.resolved) ?? .notFound
            case let .failure(error):
                phases[word.headword] = .failed(error.localizedDescription)
            }
        }
    }
}
