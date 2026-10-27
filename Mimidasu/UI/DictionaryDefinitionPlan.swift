import Foundation

/// The four hosts a shared dictionary definition renders in. Each host's
/// whole rendering stance — entry selection, chrome suppression, limits —
/// is one `DictionaryDefinitionPlan` keyed by this mode.
///
/// The popover and the sidebar card show the tap's pinned lookup; the
/// favorites row and the search row show a list row's own resolved lookup
/// expanded in place.
enum DictionaryDefinitionMode: Equatable, Sendable {
    /// The transient definition anchored at the tap.
    case popover
    /// The sidebar card pinning the session's last lookup.
    case sidebarCard
    /// A starred word's row, expanded in place in the Favorites list.
    case favoritesRow
    /// A search hit's row, expanded in place in the dictionary list.
    case searchRow
}

/// How a host picks which entry of a resolved lookup its definition shows —
/// the decision the four hosts disagree on hardest: the two tap hosts read
/// the presentation's page straight out of the lookup's entries, while both
/// list rows hand the entries to favorite-first promotion first and key the
/// selection off the row.
enum DictionaryEntrySelectionPolicy: Equatable, Sendable {
    /// Read the host's requested index straight out of the entries, in
    /// bounds or not: a lookup replaced under a stale selection renders
    /// nothing rather than snapping to a different entry. The popover and
    /// the sidebar card.
    case directIndex
    /// Open on the lead entry of the list the host presents — favorite-first
    /// promotion has already reordered that list, so the starred entry
    /// leads. The favorites row.
    case promotedLead
    /// The pager page stored for the row's key while the lead it was stored
    /// against still leads, else the row's own entry position in the list —
    /// either way clamped into bounds. The search row: a row that was never
    /// stepped opens on the entry it names, and a stepped row keeps its
    /// page until promotion reorders the list underneath it.
    case rowValidatedFallback
}

/// Who draws the entry pager (`◀ i/N ▶`) for a host.
enum DictionaryPagerPlacement: Equatable, Sendable {
    /// The definition's own header row, between the headword and the
    /// copy/star controls — so the pager exists only while the headword
    /// block is shown. The popover; the search row asks for this placement
    /// inside the headword block it suppresses.
    case contentHeader
    /// The host's own row above the definition — the sidebar card's
    /// DICTIONARY label row, which frees the headword's width. The host
    /// draws the pager there regardless of the definition's own pager flag.
    case hostLabelRow
    /// Nowhere: the host draws none and asks the definition for none. The
    /// favorites row.
    case none
}

/// The pure rendering decisions behind the shared entry definition, one
/// value per `DictionaryDefinitionMode`.
///
/// Everything the four hosts disagree about that is a *value* lives here.
/// What stays out: the entry data the host passes at render time (the
/// entry, its count, the "also:" results, the badge origin, the live star
/// membership), everything the host *measures* (the senses viewport height
/// and the three height probes the sidebar card feeds it), and the action
/// closures — those are the host's wiring, not a rendering decision. Each
/// host reads its own mode's row, and the shared entry module consumes the
/// plan the host hands it.
struct DictionaryDefinitionPlan: Sendable {
    /// The host this plan renders for.
    let mode: DictionaryDefinitionMode
    /// Which entry of the lookup the definition shows.
    let entrySelection: DictionaryEntrySelectionPolicy
    /// The value the definition's own pager flag takes — true only when the
    /// pager belongs to the definition's header row.
    let showsEntryPager: Bool
    /// Who draws the pager: the definition's header row, the host's chrome,
    /// or nobody.
    let pagerPlacement: DictionaryPagerPlacement
    /// False hides the whole headword block — headword, reading, romaji,
    /// and the header row's controls (pager, copy, star). A list row
    /// suppresses it because its own header already names the word above.
    let showsHeadword: Bool
    /// False hides the badge row, for a row whose collapsed header already
    /// carries the badges directly above the expansion. Independent of
    /// `showsHeadword`: the Favorites window shows no badges in its header,
    /// so it suppresses neither.
    let showsBadges: Bool
    /// Which header the favorite star draws in: the card's tiled 14pt mark
    /// or the popover's bare 18pt glyph. Inert wherever the headword block
    /// is suppressed, since the star lives there.
    let favoriteStyle: DictionaryFavoriteStyle
    /// Where the copy control lands: the header row's top-trailing icon, or
    /// nowhere. Inert wherever the headword block is suppressed, since the
    /// copy control lives there.
    let copyPlacement: DictionaryCopyPlacement
    /// Senses rendered (nil = every sense). All four hosts ask for all of
    /// them: a long entry expands in full wherever it is shown.
    let senseLimit: Int?
    /// Glosses per sense (nil = every gloss); same host story as `senseLimit`.
    let glossLimit: Int?
    /// True when a sense carrying more than one POS tag falls back to a
    /// stacked tag line the moment the inline row would overflow — the
    /// sidebar card's one divergence, whose 254pt content is the narrowest
    /// a sense row is ever drawn. The other hosts keep senses inline.
    let wrapsSensePOS: Bool

    init(mode: DictionaryDefinitionMode) {
        self.mode = mode
        switch mode {
        case .popover:
            entrySelection = .directIndex
            showsEntryPager = true
            pagerPlacement = .contentHeader
            showsHeadword = true
            showsBadges = true
            favoriteStyle = .popover
            copyPlacement = .icon
            senseLimit = nil
            glossLimit = nil
            wrapsSensePOS = false
        case .sidebarCard:
            entrySelection = .directIndex
            showsEntryPager = false
            pagerPlacement = .hostLabelRow
            showsHeadword = true
            showsBadges = true
            favoriteStyle = .card
            copyPlacement = .icon
            senseLimit = nil
            glossLimit = nil
            wrapsSensePOS = true
        case .favoritesRow:
            entrySelection = .promotedLead
            showsEntryPager = false
            pagerPlacement = .none
            showsHeadword = false
            showsBadges = true
            favoriteStyle = .card
            copyPlacement = .none
            senseLimit = nil
            glossLimit = nil
            wrapsSensePOS = false
        case .searchRow:
            entrySelection = .rowValidatedFallback
            showsEntryPager = true
            pagerPlacement = .contentHeader
            showsHeadword = false
            showsBadges = false
            favoriteStyle = .card
            copyPlacement = .none
            senseLimit = nil
            glossLimit = nil
            wrapsSensePOS = false
        }
    }

    /// Whether the mode can show an entry pager once the definition's own
    /// rules apply: a header-row pager lives inside the headword block,
    /// which `showsHeadword` may suppress, while a host-placed pager is the
    /// host's own chrome and answers to no flag here. A multi-entry lookup
    /// gates every pager — this says where one may appear, never whether
    /// the lookup has entries to page.
    var rendersEntryPager: Bool {
        switch pagerPlacement {
        case .hostLabelRow: true
        case .contentHeader: showsEntryPager && showsHeadword
        case .none: false
        }
    }

    /// The index of the entry this plan's host displays from `entries`, or
    /// nil when the host renders its own "nothing to show" text instead
    /// (blank in the popover, the sidebar card's hint, the row's
    /// unavailable line).
    ///
    /// Only the mode's own policy reads the inputs: `requestedIndex` is the
    /// presentation's page (the direct-index hosts), `rowEntryIndex` is
    /// where a search row's own entry sits in the promoted list, and
    /// `storedIndex`/`storedLead` are the pager page remembered for that
    /// row's key with the lead entry it was stored against. An ignored
    /// input never moves the selection.
    func displayEntryIndex(
        in entries: [JMDictEntry],
        requestedIndex: Int = 0,
        rowEntryIndex: Int = 0,
        storedIndex: Int? = nil,
        storedLead: Int? = nil
    ) -> Int? {
        switch entrySelection {
        case .directIndex:
            return entries.indices.contains(requestedIndex) ? requestedIndex : nil
        case .promotedLead:
            return entries.isEmpty ? nil : 0
        case .rowValidatedFallback:
            guard let lead = entries.first else { return nil }
            let ceiling = entries.count - 1
            let candidate = storedLead == lead.entSeq ? (storedIndex ?? 0) : rowEntryIndex
            return min(max(candidate, 0), ceiling)
        }
    }
}
