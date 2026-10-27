import Foundation

/// How deep a search's rows may be read: the list's slice of the ranked
/// payload, never a bound on what the engine returns.
///
/// Clamping lives here so the state cannot store a depth the engine would
/// refuse. A window below zero reads as an empty list, and one past
/// `DictionarySearchEngine.maxRows` reads as the ceiling — the same range
/// `DictionarySearchEngine.search` applies to its own `limit`.
struct DictionarySearchWindow: Equatable, Sendable {
    /// Rows in one page, read off the engine's own constant.
    static let pageSize = DictionarySearchEngine.pageSize
    /// The deepest window the engine answers, read off the engine's own constant.
    static let maxRows = DictionarySearchEngine.maxRows

    /// Rows the list may show, always within `0...maxRows`.
    let limit: Int

    init(limit: Int) {
        self.limit = min(max(limit, 0), Self.maxRows)
    }

    /// One page deep — the depth a fresh query starts from.
    static let initial = DictionarySearchWindow(limit: pageSize)

    /// One page deeper than this window, clamped at the ceiling.
    var advanced: DictionarySearchWindow {
        DictionarySearchWindow(limit: limit + Self.pageSize)
    }

    /// The window is as deep as the engine allows; nothing below it can be
    /// revealed, and the list offers no more pages.
    var isAtMaximum: Bool {
        limit >= Self.maxRows
    }
}

/// One search answer as the list renders it: the visible prefix, the totals
/// behind it, and the one footer action or empty message that follows.
///
/// A pure projection of an outcome and a window. The visible rows are a slice
/// of the outcome's own array, so a wider window costs no copy and every page
/// over the same payload shares one ordering. The value carries no second
/// payload channel: the outcome is read once, at construction, and paging
/// policy is decided from its counts and floor facts.
struct DictionarySearchPage: Equatable, Sendable {
    /// What one load-more click would do.
    enum LoadMore: Equatable, Sendable {
        /// Show rows the search already holds. No engine call.
        case reveal
        /// Re-run the search at a wider window, because a skipped stage's rows
        /// are only reachable that way.
        case rescan
    }

    /// What the list offers below its last visible row.
    enum Footer: Equatable, Sendable {
        /// The answer is complete and entirely visible.
        case none
        /// One more page is reachable.
        case loadMore(LoadMore)
        /// No page can be had while the answer is still short of the truth or
        /// holds rows below the window.
        case ceiling
    }

    /// Why an empty page is empty.
    enum EmptyState: Equatable, Sendable {
        /// The search completed and found nothing.
        case noMatches
        /// The search stopped at a bound or skipped a stage, so empty means
        /// "nothing in what was scanned" rather than "nothing exists".
        case noMatchesInScannedWindow
    }

    /// The window that produced the outcome and this slice.
    let window: DictionarySearchWindow
    /// The visible prefix of the outcome's ranked rows.
    let hits: ArraySlice<DictionarySearchHit>
    /// `matchedCount` from the outcome: the total behind the visible rows.
    let total: Int
    /// The total is a floor over a larger answer, so `countText` marks it.
    let isFloor: Bool
    /// The one action, or the ceiling notice, below the rows.
    let footer: Footer
    /// The empty message, or nil when rows are visible.
    let emptyState: EmptyState?

    /// Whether the visible slice holds no rows.
    var isEmpty: Bool {
        hits.isEmpty
    }

    /// The header's `displayed / matched` count, with `+` while the total is
    /// only a floor.
    var countText: String {
        "\(hits.count) / \(total)\(isFloor ? "+" : "")"
    }

    /// Projects `outcome` through `window`.
    ///
    /// A reveal is offered while the window can still grow and rows are
    /// already held below it. A rescan is offered only for a saturated answer
    /// that is not truncated — truncation's bounds are constants, so re-running
    /// would return the identical rows — and only when the next window outgrows
    /// the rows in hand. A saturated-and-truncated answer therefore reveals as
    /// far as its held rows go and then stops at the ceiling. An empty page
    /// offers no list footer at all; its floor, when it has one, lives in
    /// `emptyState`.
    init(outcome: DictionarySearchOutcome, window: DictionarySearchWindow) {
        let hits = outcome.hits.prefix(window.limit)
        let visible = hits.count
        let canReveal = !window.isAtMaximum && outcome.hits.count > window.limit
        let canRescan = !window.isAtMaximum && outcome.saturated && !outcome.truncated
        let canGrow = canReveal || canRescan
        let nextLimit = min(
            window.limit + DictionarySearchEngine.pageSize,
            DictionarySearchEngine.maxRows
        )
        let footer: Footer = if hits.isEmpty {
            .none
        } else if canRescan, nextLimit > outcome.hits.count {
            .loadMore(.rescan)
        } else if canGrow {
            .loadMore(.reveal)
        } else if outcome.matchedCount > visible || outcome.isFloor {
            .ceiling
        } else {
            .none
        }
        let emptyState: EmptyState? = if !hits.isEmpty {
            nil
        } else if outcome.isFloor {
            .noMatchesInScannedWindow
        } else {
            .noMatches
        }

        self.window = window
        self.hits = hits
        total = outcome.matchedCount
        isFloor = outcome.isFloor
        self.footer = footer
        self.emptyState = emptyState
    }
}
