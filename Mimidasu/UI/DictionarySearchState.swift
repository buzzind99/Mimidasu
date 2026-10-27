import Foundation
import SwiftUI

/// What one detached search hands back to the main actor.
///
/// An enum because the three landings are genuinely different: results, a
/// fault the user must be told about, and a scan the user typed past.
/// `Sendable` on purpose — the work runs on a detached task and `any Error` is
/// not `Sendable`, so `DictionaryError` crosses the boundary in place of
/// the raw error rather than as one; an unrecognized error becomes
/// `.internalError`, never a forged SQLite label.
enum DictionarySearchResponse: Sendable {
    case success(DictionarySearchOutcome)
    case failure(DictionaryError)
    /// The keystroke was superseded (or the window closed) while the scan ran.
    /// Never applied: the generation guard below drops it.
    case cancelled

    /// One search's crossing: runs the scan and lands it as a typed response —
    /// the engine's typed fault passes through, cancellation lands as
    /// `.cancelled`, and anything unrecognized lands as an internal error
    /// carrying the underlying message. An unknown error is not evidence of a
    /// database failure, so no path may label one a SQLite error.
    static func run(
        _ body: () throws -> DictionarySearchOutcome
    ) -> DictionarySearchResponse {
        do {
            return try .success(body())
        } catch let error as DictionaryError {
            return .failure(error)
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .failure(.internalError(message: error.localizedDescription))
        }
    }
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
            window = .initial
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
    /// How deep the list may read the current answer. One page to begin with;
    /// `loadMore()` advances it. The page projects `outcome` through this same
    /// value, so the width shown and the depth requested cannot disagree.
    private(set) var window = DictionarySearchWindow.initial
    /// The prepared database is not on disk. A fault the view names, never an
    /// empty result — and the launch-time dictionary kick-off is re-fired, so
    /// the next keystroke can find it.
    private(set) var unavailable = false
    /// A search that failed for infrastructure reasons other than a missing
    /// database (corrupt artifact, I/O error, a stale handle after a re-stage
    /// swapped the file, a closed engine). The view names it with a fault
    /// card, never as "no matches" — a dictionary that failed to open is not
    /// an answer.
    private(set) var fault: DictionaryError?
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
            window = .initial
            run(trimmed: trimmed, filters: filters)
        }
    }

    /// The current answer as one pure page value: visible slice, total, floor,
    /// footer kind, and empty state, all projected from the window on screen.
    var page: DictionarySearchPage {
        DictionarySearchPage(outcome: outcome, window: window)
    }

    /// Advances one page, following the footer the page already shows.
    ///
    /// The page decides what the click means: it either reveals rows the
    /// search already holds — the free common case, which never calls the
    /// engine — or re-runs a stage the search skipped, because running a
    /// wider window is the only way those rows become reachable. A truncated
    /// answer never re-runs: its bounds are constants, so the same scan would
    /// return the identical rows.
    ///
    /// Either way the rows above the window never move — a stage is skipped
    /// only when its rows rank below every row in the window it was measured
    /// against, so a deeper window can only append.
    func loadMore() {
        guard case let .loadMore(action) = page.footer else { return }
        window = window.advanced
        guard action == .rescan else { return }
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
        let limit = window.limit
        let work = Task.detached(priority: .userInitiated) { () -> DictionarySearchResponse in
            DictionarySearchResponse.run {
                try engine.search(trimmed, filters: filters, limit: limit)
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
    /// reset until the next press. The rule itself is
    /// `DictionaryDefinitionPlan`'s row-validated policy; this method only
    /// supplies the live per-row memory. Nothing is written here; `stepEntry`
    /// persists the lead and index when the user presses, so body evaluation
    /// never mutates the state it reads.
    func validatedIndex(for key: String, in promoted: LookupResult, fallback: Int = 0) -> Int {
        let plan = DictionaryDefinitionPlan(mode: .searchRow)
        return plan.displayEntryIndex(
            in: promoted.entries,
            rowEntryIndex: fallback,
            storedIndex: entryIndices[key],
            storedLead: entryLeads[key]
        ) ?? 0
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
            window = .initial
            entryIndices.removeAll()
            entryLeads.removeAll()
            lookupState.reset()
        }
    }
}
