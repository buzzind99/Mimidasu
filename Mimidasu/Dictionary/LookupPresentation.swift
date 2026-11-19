/// Where one lookup is anchored: the transcript word the user tapped, or the
/// live strip. The app shows a single popover, owned by whatever anchor it was
/// opened from, while the pinned card outlives the popover.
enum LookupAnchor: Equatable, Hashable, Sendable {
    case transcript(sentenceIndex: Int, tokenIndex: Int)
    case liveStrip
}

/// One finished lookup as both hosts read it: the pinned content and the paged
/// entry index. Popover ownership lives on `TapLookupSession.anchor`, so a
/// pager step or a fallback promotion republishes this value without touching
/// the anchor — transcript rows that only read the anchor are not invalidated.
///
/// Value semantics on purpose: paging and promotion are pure derivations over
/// the same content, so the popover and the pinned card can never disagree
/// about which entry is up.
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

    /// Presentation identity: content-derived — entry paging does not change
    /// it, a new content does.
    var id: String {
        switch content {
        case let .found(result, _, _): result.matched
        case let .notFound(surface, _): "not-found:\(surface)"
        // Unreachable in a stored presentation (see `content`); named so the
        // derivation stays total without trapping.
        case let .noHit(surface): "no-hit:\(surface)"
        case .failure: "failure"
        }
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
        return LookupPresentation(content: promoted, entryIndex: 0)
    }

    /// A freshly resolved presentation for the pinned card — the caller sets
    /// the owning anchor separately. The entry index is clamped into the
    /// display entries — a not-found or empty display has none and opens at
    /// zero.
    static func initial(content: LookupAnswer, entryIndex: Int) -> LookupPresentation {
        var presentation = LookupPresentation(content: content, entryIndex: 0)
        presentation.stepEntry(to: entryIndex)
        return presentation
    }
}
