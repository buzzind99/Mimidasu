import Foundation
import SwiftUI

/// What one detached search hands back to the main actor.
///
/// An enum because the three landings are genuinely different: results, a
/// fault the user must be told about, and a scan the user typed past.
/// `Sendable` on purpose — the work runs on a detached task and `any Error` is
/// not `Sendable`, so the engine's typed fault crosses the boundary in place of
/// the raw error rather than as one.
enum DictionarySearchResponse: Sendable {
    case success(DictionarySearchOutcome)
    case failure(DictionarySearchError)
    /// The keystroke was superseded (or the window closed) while the scan ran.
    /// Never applied: the generation guard below drops it.
    case cancelled
}

/// Dictionary mode's search state: the query, the filters, the ranked outcome,
/// and the staleness machinery that keeps an abandoned keystroke's results off
/// the screen.
///
/// Owned by the reference window's host rather than the view, so switching to
/// Favorites and back finds the query, the filters, and every expanded row
/// exactly as they were left. The window close still wipes them, which is the
/// only reset the window has ever performed.
@Observable
@MainActor
final class DictionarySearchState {
    /// Same cadence as the Favorites field: one window, one feel. Defined on
    /// `ReferenceWindow`, which owns both modes, so neither mode's state type
    /// is the other's dependency for a constant.
    static let searchDebounce = ReferenceWindow.searchDebounce

    var query = "" {
        didSet { queryChanged(to: query) }
    }

    /// The query the rows were built from; trails `query` by the debounce.
    private(set) var debouncedQuery = ""
    /// The filter selection the rows were built from. Every external write
    /// goes through `apply(_:)`, which funnels the transition's normalized
    /// result in, so a raw impossible pair (Common under Names) cannot be
    /// parked here. A filter change re-runs the search immediately against
    /// the debounced query — there is nothing to debounce, the input is a
    /// button press, and a filter that visibly did nothing reads as broken.
    private(set) var filters = DictionarySearchFilters() {
        didSet {
            guard filters != oldValue else { return }
            // A new filter set starts one page deep, like a new query: the
            // depth belonged to the previous answer, and without the reset a
            // filter press after Load-more runs a 100-row scan and shows 100
            // rows instead of the first page.
            visibleLimit = DictionarySearchEngine.pageSize
            pruneLookupState()
            run(trimmed: debouncedQuery, filters: filters)
        }
    }

    /// The window's single external write path for the Filter set: the panel
    /// and the tests dispatch events, and the pure transition owns every
    /// exclusion, carry-over, and floor rule. A no-op event (a floor-blocked
    /// match toggle, Common under Names, a clear of an empty set) returns a
    /// value equal to the stored one and returns here before the write — no
    /// observation notification, no re-page, no prune, no search. The direct
    /// write stays private to the type (`resetForClose`, whose defaults are
    /// already normalized), so no external caller can bypass normalization.
    func apply(_ event: DictionarySearchFilters.FilterEvent) {
        let next = filters.apply(event)
        guard next != filters else { return }
        filters = next
    }

    /// Whether the filter panel is open. Chrome only: flipping it re-runs
    /// nothing and survives filter presses, and the close wipes it alongside
    /// the filters themselves.
    var filtersExpanded = false

    private(set) var outcome = DictionarySearchOutcome.empty
    private(set) var isSearching = false
    /// How deep the window has been paged. One page to begin with;
    /// `loadMore()` adds another. It slices `outcome.hits` — it is a *view* of
    /// what the search found, not a request the engine has to answer again.
    private(set) var visibleLimit = DictionarySearchEngine.pageSize
    /// The prepared database is not on disk. A fault the view names, never an
    /// empty result — and the launch-time dictionary kick-off is re-fired, so
    /// the next keystroke can find it.
    private(set) var unavailable = false
    /// A search that failed for infrastructure reasons other than a missing
    /// database (corrupt artifact, I/O error, a stale handle after a re-stage
    /// swapped the file, a closed engine). The view names it with a fault
    /// card, never as "no matches" — a dictionary that failed to open is not
    /// an answer.
    private(set) var fault: DictionarySearchError?
    /// Results dropped by the generation guard — the guard's observable half,
    /// the same contract `FavoritesLookupState.discardedLandings` offers.
    private(set) var discardedLandings = 0
    /// Per-row expansion, keyed by `lookupKey(for:)` — the row's entry, not
    /// its headword: two rows can share a headword (two kana-only entries
    /// spelled ポン), and a headword-keyed row would expand its siblings with
    /// it. Rows expand independently, and one row's collapse must not drop a
    /// sibling's in-flight lookup.
    let lookupState: FavoritesLookupState
    /// Which entry an expanded row's pager is showing, per row key.
    private var entryIndices: [String: Int] = [:]
    /// Lead entry identity per row key, so the pager does not retarget when
    /// promotion reorders the entries: starring a word moves its entry to the
    /// front, and without the lead check the stored index would point at a
    /// different entry after the reorder.
    private var entryLeads: [String: Int] = [:]

    private let engine: DictionarySearchEngine
    private let prepareDictionary: () -> Void
    private var generation = 0
    private var debounceTask: Task<Void, Never>?
    private var search: Task<DictionarySearchResponse, Never>?

    init(model: AppModel, lookup: JMDictLookup? = nil) {
        engine = model.dictionarySearch
        // Own handle, not the shared tap engine — see FavoritesWindowState.
        // A passed-in handle is test-only; production takes a fresh one.
        lookupState = FavoritesLookupState(lookup: lookup ?? JMDictLookup())
        prepareDictionary = { model.prepareDictionaries() }
    }

    private func queryChanged(to newValue: String) {
        debounceTask?.cancel()
        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        // Nothing to debounce when the field already matches the query the
        // rows were built from — which is what the close-time reset's own
        // `debouncedQuery = ""` write is for, so it never respawns the task it
        // just cancelled.
        guard trimmed != debouncedQuery else { return }
        debounceTask = Task { @MainActor in
            try? await Task.sleep(for: Self.searchDebounce)
            guard !Task.isCancelled else { return }
            debouncedQuery = trimmed
            // A new query starts one page deep, whatever the previous one had
            // been paged to: the depth belonged to that answer.
            visibleLimit = DictionarySearchEngine.pageSize
            run(trimmed: trimmed, filters: filters)
        }
    }

    /// The rows on screen: the window's prefix of everything the search found.
    ///
    /// An `ArraySlice` so paging costs no copy and the list keeps one
    /// identity as it grows — the rows above the window never move, and a
    /// re-search that finds more only ever appends.
    var visibleHits: ArraySlice<DictionarySearchHit> {
        outcome.hits.prefix(visibleLimit)
    }

    /// The header's `displayed / matched` count. The total carries a `+`
    /// whenever it is a floor — a stage the search skipped, or a headword scan
    /// that stopped at one of its own bounds. A total that says `51+` is the
    /// honest reading of a search that found 51 and declined to look for the
    /// rest; only the first of those two grows when the user pages.
    var countText: String {
        "\(visibleHits.count) / \(outcome.matchedCount)\(outcome.isFloor ? "+" : "")"
    }

    /// Whether one more page can be reached — either the search already holds
    /// rows below the window (a reveal, which costs nothing), or it skipped a
    /// stage that a wider window would run (a probe). False at the ceiling.
    ///
    /// The saturated arm is what a gloss-only query never needs: its total is
    /// complete on the first search, so its clicks are all reveals and its last
    /// page simply ends the list with no footer at all. A `commonOnly` search
    /// is never saturated either — the ladder cannot measure that window
    /// before the join that resolves `common`, so it runs every stage and its
    /// probe arm can only ever fire on rows it already holds.
    var canLoadMore: Bool {
        visibleLimit < DictionarySearchEngine.maxRows
            && (outcome.hits.count > visibleLimit || outcome.saturated)
    }

    /// The window is as deep as it may go and rows remain — the only state in
    /// which refining beats scrolling. At the ceiling the held rows cannot
    /// outnumber the window, so `matchedCount > visibleLimit` says so directly;
    /// a floor total (`saturated` or `truncated`) counts too: under saturation
    /// `matchedCount` is short of the answer, so rows behind the skipped stage
    /// are possible even when the count lands exactly on the ceiling.
    var isAtCeiling: Bool {
        visibleLimit >= DictionarySearchEngine.maxRows
            && (outcome.matchedCount > visibleLimit || outcome.isFloor)
    }

    /// Reveals another page, re-searching only when a stage was skipped.
    ///
    /// Rows the search already built are shown for free, which is the common
    /// case: a gloss-only query found its whole answer on the first search and
    /// every click is a reveal rather than a re-run of a 50 ms scan.
    ///
    /// The re-run is gated on `saturated` as well as on outgrowing the rows in
    /// hand, because that is the *only* way a deeper window finds anything: it
    /// changes nothing but which stages the ladder was allowed to skip. A search
    /// that skipped nothing has already seen every row it can see, so asking it
    /// again would pay full price for the same answer.
    ///
    /// Either way the rows already on screen do not move — a stage is skipped
    /// only when its rows rank below every row in the window it was measured
    /// against, so a deeper window can only append.
    func loadMore() {
        let next = min(visibleLimit + DictionarySearchEngine.pageSize, DictionarySearchEngine.maxRows)
        guard next > visibleLimit, canLoadMore else { return }
        visibleLimit = next
        guard outcome.saturated, next > outcome.hits.count else { return }
        run(trimmed: debouncedQuery, filters: filters)
    }

    /// Runs one search off the main actor and applies it only if it is still
    /// the newest one. Cancelling the detached task is what actually stops the
    /// scan: the engine checks `Task.isCancelled` between stages and inside
    /// every drain loop, so an abandoned 20k-row prefix scan releases the
    /// engine's mutex immediately instead of parking the next keystroke behind
    /// it. The window is read once, here, so a load-more and a keystroke racing
    /// for the same engine cannot disagree about how deep it is looking.
    private func run(trimmed: String, filters: DictionarySearchFilters) {
        search?.cancel()
        generation += 1
        let current = generation
        guard !trimmed.isEmpty else {
            outcome = .empty
            isSearching = false
            unavailable = false
            fault = nil
            return
        }
        // A fresh attempt drops the previous fault so the retry reads as a
        // wait, not as a standing "relaunch" verdict on a search now running.
        fault = nil
        isSearching = true
        let engine = engine
        let limit = visibleLimit
        let work = Task.detached(priority: .userInitiated) { () -> DictionarySearchResponse in
            do {
                return try .success(engine.search(trimmed, filters: filters, limit: limit))
            } catch let error as DictionarySearchError {
                return .failure(error)
            } catch is CancellationError {
                return .cancelled
            } catch {
                return .failure(.sqlite(code: -1, message: error.localizedDescription))
            }
        }
        search = work
        Task { @MainActor [weak self] in
            let response = await work.value
            guard let self else { return }
            guard generation == current else {
                discardedLandings += 1
                return
            }
            isSearching = false
            switch response {
            case let .success(hits):
                unavailable = false
                fault = nil
                outcome = hits
                pruneLookupState()
            case let .failure(failure):
                if failure == .databaseMissing {
                    unavailable = true
                    fault = nil
                    prepareDictionary()
                } else {
                    unavailable = false
                    fault = failure
                }
                outcome = .empty
            case .cancelled:
                break
            }
        }
    }

    /// The row key the shared expansion state uses: a search row is one entry,
    /// so the entry id names it. Two rows can share a headword, so the
    /// headword cannot.
    nonisolated static func lookupKey(for hit: DictionarySearchHit) -> String {
        String(hit.entSeq)
    }

    /// Where a row's own entry sits in a promoted lookup — the fallback page
    /// the search view hands `validatedIndex`, so an untouched row opens on
    /// the entry it names rather than on the lookup's ranked first. Two rows
    /// sharing a headword run the same lookup, whose ranked first is one of
    /// them; without this, expanding the other would show its sibling.
    nonisolated static func rowEntryIndex(
        for hit: DictionarySearchHit, in promoted: LookupResult
    ) -> Int {
        promoted.entries.firstIndex { entry in entry.entSeq == hit.entSeq } ?? 0
    }

    /// Drops expansion state for rows the current result no longer holds, so an
    /// in-flight lookup cannot land on a row that has since been filtered out.
    /// Runs twice: on the filter press (against the rows on screen now) and
    /// when a successful outcome lands (against the rows the re-search found) —
    /// the landing pass is what achieves the stated purpose. A failed search
    /// does not prune: it holds no rows to prune against, and collapsing every
    /// open row over a possibly-transient fault would drop lookups the next
    /// keystroke puts right back.
    private func pruneLookupState() {
        let rows = Set(outcome.hits.map { hit in Self.lookupKey(for: hit) })
        for key in lookupState.expanded where !rows.contains(key) {
            lookupState.remove(key: key)
        }
        entryIndices = entryIndices.filter { key, _ in rows.contains(key) }
        entryLeads = entryLeads.filter { key, _ in rows.contains(key) }
    }

    /// The raw stored page, unvalidated: no lead check, so a promotion
    /// reorder reads as a stale page here. Only tests read this — display
    /// code must read `validatedIndex(for:in:)`, which restarts at the
    /// fallback when the lead entry changed.
    func entryIndex(for key: String) -> Int {
        entryIndices[key] ?? 0
    }

    /// Pager index against the promoted entry list. A pure read: the display
    /// restarts at the fallback when the lead entry changed — a promotion
    /// reorder, or a fresh lookup that leads with a different entry — and
    /// otherwise clamps the stored index to the list bounds. The search view
    /// passes the row's own entry position as the fallback, so an untouched
    /// row opens on the entry it names rather than on the lookup's ranked
    /// first: the lookups of two rows sharing a headword rank the same, and
    /// a row must not expand to a sibling's definition. A re-lookup that
    /// leads with the same entry keeps the stored page. The same keep can
    /// resurface a page: when a lead flips away and back — an unrelated
    /// unstar elsewhere, then re-starring the same entry reproduces the
    /// promoted ordering — the stored page returns on that star press
    /// rather than a pager touch. That is the accepted trade of the
    /// absolute-target pager, where storage deliberately lags a display
    /// reset until the next press. Nothing is written here; `stepEntry`
    /// persists the lead and index when the user presses, so body evaluation
    /// never mutates the state it reads.
    func validatedIndex(for key: String, in promoted: LookupResult, fallback: Int = 0) -> Int {
        let ceiling = max(promoted.entries.count - 1, 0)
        guard entryLeads[key] == promoted.entries.first?.entSeq else {
            return min(max(fallback, 0), ceiling)
        }
        let stored = entryIndices[key] ?? 0
        return min(max(stored, 0), ceiling)
    }

    /// The expanded row's pager step: the absolute target index the pager
    /// hands over, clamped to the entry list it belongs to. Persists the
    /// promoted lead alongside the index, so a later promotion reorder reads
    /// as a lead change and restarts the display at the fallback.
    func stepEntry(_ key: String, to index: Int, in promoted: LookupResult) {
        if let lead = promoted.entries.first?.entSeq {
            entryLeads[key] = lead
        }
        entryIndices[key] = min(max(index, 0), max(promoted.entries.count - 1, 0))
    }

    /// Wipes the mode at the moment the window closes — see
    /// `FavoritesWindowState.resetForClose` for why it happens here rather than
    /// on the next show.
    func resetForClose() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            debouncedQuery = ""
            debounceTask?.cancel()
            debounceTask = nil
            search?.cancel()
            search = nil
            generation += 1
            query = ""
            outcome = .empty
            isSearching = false
            unavailable = false
            fault = nil
            // The class doc promises the close wipes the filters — a reopened
            // window searching Names-only with COMMON greyed is a silent
            // scope the chrome never explains. Set after `debouncedQuery = ""`
            // so the `filters.didSet` re-run takes the empty-query early exit
            // rather than searching the query just wiped.
            filters = DictionarySearchFilters()
            filtersExpanded = false
            visibleLimit = DictionarySearchEngine.pageSize
            entryIndices.removeAll()
            entryLeads.removeAll()
            lookupState.reset()
        }
    }
}
