import Foundation

/// Where one lookup is anchored: the transcript word the user tapped, or the
/// live strip. The app shows a single popover, owned by whatever anchor it was
/// opened from, while the pinned card outlives the popover.
enum LookupAnchor: Equatable, Hashable, Sendable {
    case transcript(sentenceIndex: Int, tokenIndex: Int)
    case liveStrip
}

/// One finished lookup as both hosts read it: the content, the paged entry
/// index, and the anchor whose popover presents it. A nil anchor is the
/// dismissed-popover state — the pinned card still shows `content` at
/// `entryIndex`, while no row owns a popover.
///
/// Value semantics on purpose: paging, promotion, and dismissal are pure
/// derivations over the same state, so the popover and the pinned card can
/// never disagree about which lookup is up.
struct LookupPresentation: Equatable, Sendable, Identifiable {
    /// The pinned display content. A stored presentation only ever holds the
    /// pinnable answers — `.found` (a hit with its fallback results) or
    /// `.notFound` (a not-found tap with its related suggestions). `.noHit`
    /// and `.failure` are feedback verdicts, never pins, and a dropped
    /// (nil) answer never reaches here: the session applies only the
    /// pinnable two, so the branches that name the unpinnable ones exist
    /// for totality over this type, never for a stored value.
    var content: LookupAnswer
    /// The paged entry index into the display result's entries.
    var entryIndex: Int
    /// nil means the popover is dismissed; the pinned card still shows.
    var anchor: LookupAnchor?

    /// Presentation identity. The anchor and the matched token key it — entry
    /// paging does not change identity, a new content does. A dismissed
    /// presentation keeps a content-derived id so a re-pin can be recognized.
    var id: String {
        let token: String = switch content {
        case let .found(result, _, _): result.matched
        case let .notFound(surface, _): "not-found:\(surface)"
        // Unreachable in a stored presentation (see `content`); named so the
        // derivation stays total without trapping.
        case let .noHit(surface): "no-hit:\(surface)"
        case .failure: "failure"
        }
        guard let anchor else { return "pinned-\(token)" }
        return "\(anchor)-\(token)"
    }

    /// The popover item `anchor` presents — only the owning anchor shows the
    /// popover; every other surface sees nothing. A dismissed presentation
    /// matches no anchor.
    func popoverItem(for anchor: LookupAnchor) -> LookupPresentation? {
        self.anchor == anchor ? self : nil
    }

    /// Turns the entry pager to `index`, clamped into the display result's
    /// entries. A not-found pin has no display and an empty display has no
    /// entry: both leave the index untouched — as does an answer that never
    /// pins, which carries no display either.
    mutating func stepEntry(to index: Int) {
        guard let entries = content.displayResult?.entries, !entries.isEmpty
        else { return }
        entryIndex = min(max(index, 0), entries.count - 1)
    }

    /// Re-selects a fallback pill — an "also:" hit on a found card, or a
    /// "related:" suggestion on a not-found one: the display switches to that
    /// result as found, the fallback row recomputes from the retained results,
    /// and the pager restarts at the first entry. A same-display re-select
    /// preserves its origin; a cross-pill move carries the tapped-surface
    /// origin. The rebuilt content runs through the same favorites promotion a
    /// fresh tap gets, so a selection opens on a favorited entry when one is
    /// eligible. A foreign result — one the tap never resolved — fails closed
    /// with nil, and so does a promotion that leaves the content unchanged.
    /// The anchor is preserved, dismissed included.
    func promoting(
        _ choice: LookupResult, favorites: FavoriteIdentity
    ) -> LookupPresentation? {
        guard content.allResults.contains(choice) else { return nil }
        let promoted: LookupAnswer = if let display = content.displayResult, choice == display,
                                        case let .found(_, _, origin) = content
        {
            FavoritesPromotion.promotingFavorites(
                in: .found(
                    result: choice,
                    also: content.allResults.filter { candidate in candidate != choice },
                    origin: origin
                ),
                identity: favorites
            )
        } else {
            FavoritesPromotion.promotingFavorites(
                in: .found(
                    result: choice,
                    also: content.allResults.filter { candidate in candidate != choice },
                    origin: .tappedSurface
                ),
                identity: favorites
            )
        }
        guard promoted != content else { return nil }
        return LookupPresentation(content: promoted, entryIndex: 0, anchor: anchor)
    }

    /// A freshly resolved presentation: the popover is up at `anchor` and the
    /// pinned card shows the same lookup. The entry index is clamped into the
    /// display entries — a not-found or empty display has none and opens at
    /// zero.
    static func initial(
        content: LookupAnswer, entryIndex: Int, anchor: LookupAnchor
    ) -> LookupPresentation {
        var presentation = LookupPresentation(content: content, entryIndex: 0, anchor: anchor)
        presentation.stepEntry(to: entryIndex)
        return presentation
    }
}
