import Foundation
import SwiftUI

/// The Favorites mode's whole mutable surface, hoisted out of `FavoritesView`
/// into the reference window's host.
///
/// The host owns it because the window is now two modes sharing one scene: a
/// mode switch tears down the inactive mode's view, and `@State` in that view
/// would take the search query, the result list, and every expanded row with
/// it. A state object created once by the host survives the switch, so coming
/// back to Favorites shows exactly what was left behind — and the window close
/// still wipes it (`resetForClose`), which is the only reset the window ever
/// performed.
@Observable
@MainActor
final class FavoritesWindowState {
    /// The query the rows were built from; trails `query` by the debounce so a
    /// fast typist runs one query instead of one per keystroke.
    private(set) var debouncedQuery = ""
    /// The rows on screen — the whole list with no query, the store's matches
    /// with one. Held rather than computed so the query runs when its inputs
    /// change (the debounce landing, a favorites mutation, a close) and not on
    /// every body evaluation: a search active, each row expansion and each star
    /// pressed in a dictionary host re-runs `body`, and none of those needs to
    /// re-query the file.
    private(set) var results: [FavoriteWord]
    /// One instance for the whole mode, so several rows can be expanded at
    /// once and each keeps its own in-flight lookup.
    let lookupState: FavoritesLookupState

    var query = "" {
        didSet { queryChanged(to: query) }
    }

    /// Shared by both reference modes: one cadence for the window, so the two
    /// search fields feel like the same control. Defined on `ReferenceWindow`,
    /// which owns both modes; this is the Favorites-mode spelling of it.
    static let searchDebounce = ReferenceWindow.searchDebounce

    private let favorites: FavoritesStore
    private var searchTask: Task<Void, Never>?

    init(model: AppModel, lookup: JMDictLookup? = nil) {
        favorites = model.favorites
        // Own handle so a slow tap cannot stall starred-row expansion (and
        // vice versa): AppModel gave dictionarySearch the same treatment so
        // a long prefix scan cannot stall a tap. Same resolve seam, separate
        // Mutex — a passed-in handle is test-only; production takes a fresh one.
        lookupState = FavoritesLookupState(lookup: lookup ?? JMDictLookup())
        results = model.favorites.words
    }

    /// Cancels any in-flight debounce and, unless the field already matches
    /// the query the rows were built from, schedules a new one. The close-time
    /// reset lands through the same path — its own `query = ""` write re-enters
    /// here — and must not respawn the task it just cancelled, which the
    /// equality guard turns into an early return.
    private func queryChanged(to newValue: String) {
        searchTask?.cancel()
        guard newValue != debouncedQuery else { return }
        searchTask = Task { @MainActor in
            try? await Task.sleep(for: Self.searchDebounce)
            guard !Task.isCancelled else { return }
            debouncedQuery = newValue
            results = rows(for: newValue)
        }
    }

    /// A favorites mutation landed. Removal is confirmed and then committed by
    /// the shared alert, so this state no longer knows *which* control removed
    /// the word — the popover, the card, and a search row can all remove one.
    /// Pruning covers all three, and the rows follow: a search stays live over
    /// the surviving words, and an unfiltered list picks up the store's new
    /// ordering.
    func favoritesChanged() {
        let remaining = Set(favorites.words.map(\.headword))
        for key in lookupState.expanded where !remaining.contains(key) {
            lookupState.remove(key: key)
        }
        results = rows(for: debouncedQuery)
    }

    /// Wipes everything the window remembers between visits, at the moment it
    /// closes. The scene caches this view, so without this the search query and
    /// every expanded row would still be there on the next open — and a reset
    /// on the next *show* instead is what the user saw: `didBecomeKey` fires
    /// with the window already on screen, so the row animation replayed the
    /// whole list's collapse in front of them on every open.
    ///
    /// Animations are off for the reset itself. `willClose` is the only close
    /// notification AppKit posts (there is no `didClose`), and it arrives while
    /// the window is still on screen — mid close-animation — so an animated
    /// reset would just relocate the flash from opening to closing.
    func resetForClose() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            // `debouncedQuery` first: `query = ""` below re-enters the query
            // handler, and its equality guard only turns the reset into an
            // early return if the two already agree. Otherwise a 150ms task
            // would be spawned for the empty query — the last thing a window
            // that is closing should start.
            debouncedQuery = ""
            searchTask?.cancel()
            searchTask = nil
            query = ""
            results = favorites.words
            lookupState.reset()
        }
    }

    /// The rows a query means: everything with no query, the store's matches
    /// with one. Called only from the events that change its inputs — the
    /// debounce landing, a favorites mutation, a close — never per body
    /// evaluation; each call is a synchronous query.
    private func rows(for query: String) -> [FavoriteWord] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return favorites.words }
        return favorites.search(trimmed)
    }

    /// The header's trailing count: capacity against the store's size with no
    /// query, the row count with one.
    func countText() -> String {
        let trimmed = debouncedQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "\(favorites.count) / \(FavoritesStore.limit)"
        }
        return results.count == 1 ? "1 entry" : "\(results.count) entries"
    }
}
