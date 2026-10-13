import SwiftUI

/// The collapsible filter panel behind the dictionary search field's funnel
/// button: scope + reset, then the match, JLPT (+ COMMON), and name-type
/// rows. Gone entirely while `filtersExpanded` is false, so the
/// list keeps the room.
///
/// Split from `DictionarySearchView` so both types stay inside the body
/// budget — the rows below are the panel's, and the result list stays the
/// window chrome's.
struct DictionaryFilterPanel: View {
    let state: DictionarySearchState
    /// The Names row's disclosure. Local chrome state, not a search filter:
    /// the panel itself is torn down with the close, so this always returns
    /// to collapsed — which is the specified default.
    @State private var namesExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            scopeRow
            matchRow
            jlptRow
            nameTypeRow
        }
    }

    private var scopeRow: some View {
        HStack(spacing: 8) {
            ScopeBadgePicker(selection: scope)
            Spacer(minLength: 0)
            resetButton
        }
    }

    /// Clears every filter back to the defaults. Sits at the row's trailing
    /// edge, aligned under the funnel button. Disabled at the defaults, so
    /// it never offers a press that would visibly do nothing — and while
    /// disabled it wears neither the hover wash nor the link cursor.
    private var resetButton: some View {
        // Raw equality is the right read here: a kept-but-ignored selection
        // (JLPT under Names, name types under Words) only exists alongside a
        // non-default scope, which narrows on its own — so Reset is never
        // enabled over a search identical to the defaults.
        let isDefault = state.filters == DictionarySearchFilters()
        return Button {
            state.filters = DictionarySearchFilters()
        } label: {
            Text("Reset")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isDefault ? Theme.secondaryText.opacity(0.6) : Theme.accentPink)
        }
        .buttonStyle(.plain)
        .modifier(LinkCursor(enabled: !isDefault))
        .disabled(isDefault)
        .opacity(isDefault ? 0.7 : 1)
        .help("Reset all filters")
        .accessibilityLabel("Reset all filters")
    }

    /// Which match tiers may answer. Every group toggles independently, and All
    /// switches every group back on; the last enabled group cannot be switched
    /// off, so the row can never narrow the answer to nothing.
    private var matchRow: some View {
        HStack(spacing: 6) {
            caption("Match")
            ForEach(DictionarySearchFilters.MatchGroup.allCases, id: \.self) { group in
                FilterBadgeButton(
                    text: group.label.uppercased(),
                    selected: state.filters.matchGroups.contains(group),
                    help: matchHelp(for: group),
                    accessibility: "\(group.label) matches only"
                ) {
                    toggleMatchGroup(group)
                }
            }
            FilterBadgeButton(
                text: "All",
                selected: state.filters.matchGroups == Set(DictionarySearchFilters.MatchGroup.allCases),
                help: "Search every match type",
                accessibility: "All match types"
            ) {
                selectAllMatchGroups()
            }
            Spacer(minLength: 0)
        }
    }

    /// JLPT levels an entry must carry, with COMMON riding the same row past
    /// a divider. Both describe word entries, so the row disables under
    /// Names with the selections kept, restoring on the way back.
    private var jlptRow: some View {
        let disabled = state.filters.scope == .names
        return HStack(spacing: 6) {
            caption("JLPT")
            ForEach(1 ... 5, id: \.self) { level in
                FilterBadgeButton(
                    text: "N\(level)",
                    selected: state.filters.jlptLevels.contains(level),
                    selectedColor: Theme.brandViolet,
                    disabled: disabled,
                    help: "Only JLPT N\(level) entries",
                    accessibility: "JLPT N\(level) only"
                ) {
                    toggleJLPTLevel(level)
                }
            }
            FilterBadgeButton(
                text: "All",
                selected: state.filters.jlptLevels.isEmpty,
                selectedColor: Theme.brandViolet,
                disabled: disabled,
                help: "All JLPT levels",
                accessibility: "All JLPT levels"
            ) {
                clearJLPTLevels()
            }
            Rectangle()
                .fill(Theme.secondaryText.opacity(0.4))
                .frame(width: 1, height: 16)
                .padding(.horizontal, 2)
                .accessibilityHidden(true)
            commonOnlyToggle
            Spacer(minLength: 0)
        }
        .opacity(disabled ? 0.4 : 1)
        .help("JLPT levels apply to word entries")
    }

    /// Name-type badges an entry must carry. Disabled under Words — types
    /// describe name entries — with the selection kept, mirroring the JLPT row.
    /// Collapsible: twenty-two types plus All never fit one line, so the
    /// collapsed row shows only the pinned SURNAME / GIVEN NAME / PLACE NAME
    /// chips (plus any active selection the pins would hide, plus All), with
    /// a chevron flowing right after the last badge toggling the full list.
    private var nameTypeRow: some View {
        let disabled = state.filters.scope == .words
        return HStack(alignment: .top, spacing: 6) {
            caption("Names")
            FlowLayout(
                spacing: 6, lineSpacing: 6,
                fingerprint: nameFingerprint
            ) {
                ForEach(visibleNameBadges, id: \.self) { badge in
                    FilterBadgeButton(
                        text: badge,
                        selected: state.filters.nameTypes.contains(badge),
                        selectedColor: Theme.brandViolet,
                        disabled: disabled,
                        help: "Only \(badge) entries",
                        accessibility: "\(badge) only"
                    ) {
                        toggleNameType(badge)
                    }
                }
                FilterBadgeButton(
                    text: "All",
                    selected: state.filters.nameTypes.isEmpty,
                    selectedColor: Theme.brandViolet,
                    disabled: disabled,
                    help: "All name types",
                    accessibility: "All name types"
                ) {
                    clearNameTypes()
                }
                namesDisclosureButton
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .opacity(disabled ? 0.4 : 1)
        .help("Name types apply to name entries")
    }

    /// The pinned chips the collapsed Names row keeps, in display order:
    /// surname, given name, place name.
    private static let pinnedNameBadges = ["SURNAME", "GIVEN NAME", "PLACE NAME"]

    /// The type chips on screen now. Collapsed: the pins in pinned order,
    /// plus any selected type the pins would otherwise hide — a live filter
    /// must never vanish behind the disclosure — in `allNameTypeBadges`
    /// order. Expanded: all.
    private var visibleNameBadges: [String] {
        guard !namesExpanded else { return DictionaryContent.allNameTypeBadges }
        let selected = state.filters.nameTypes
        let extras = DictionaryContent.allNameTypeBadges.filter { badge in
            selected.contains(badge) && !Self.pinnedNameBadges.contains(badge)
        }
        return Self.pinnedNameBadges + extras
    }

    /// Keys the `FlowLayout` cache on what it lays out: the disclosure state,
    /// the chips on screen, and the selection (which recolors them).
    private var nameFingerprint: String {
        let expanded = namesExpanded ? "open" : "shut"
        let visible = visibleNameBadges.joined(separator: "\n")
        let selected = state.filters.nameTypes.sorted().joined(separator: "\n")
        return "\(expanded)\n\(visible)\n\(selected)"
    }

    /// The chevron toggling the Names row. A child of the flow, so it sits
    /// right after the last badge rather than pinned to the window's
    /// trailing edge. Chrome, not a filter, so it stays enabled while the
    /// chips themselves are disabled under Words.
    private var namesDisclosureButton: some View {
        Button {
            namesExpanded.toggle()
        } label: {
            Image(systemName: namesExpanded ? "chevron.up" : "chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 20, height: 20)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .hoverHighlight(Circle())
        .help(namesExpanded ? "Collapse name types" : "Show all name types")
        // No expanded trait exists in SwiftUI — the label itself carries the
        // state, the same pattern the row chevrons use.
        .accessibilityLabel(namesExpanded ? "Collapse name types" : "Show all name types")
    }

    /// The small leading label each filter row carries, fixed wide so the
    /// chips line up in one column down the panel. Wide enough for "Match"
    /// / "Names" (the longest captions) and single-line, so no caption can
    /// ever wrap onto two lines.
    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Theme.secondaryText)
            .lineLimit(1)
            .frame(width: 42, alignment: .leading)
    }

    private func matchHelp(for group: DictionarySearchFilters.MatchGroup) -> String {
        switch group {
        case .exact: "Only exact and lemma matches"
        case .prefix: "Only prefix matches"
        case .gloss: "Only meaning matches"
        }
    }

    private func toggleMatchGroup(_ group: DictionarySearchFilters.MatchGroup) {
        var filters = state.filters
        if filters.matchGroups.contains(group) {
            guard filters.matchGroups.count > 1 else { return }
            filters.matchGroups.remove(group)
        } else {
            filters.matchGroups.insert(group)
        }
        state.filters = filters
    }

    private func selectAllMatchGroups() {
        var filters = state.filters
        filters.matchGroups = Set(DictionarySearchFilters.MatchGroup.allCases)
        state.filters = filters
    }

    private func toggleJLPTLevel(_ level: Int) {
        var filters = state.filters
        if filters.jlptLevels.contains(level) {
            filters.jlptLevels.remove(level)
        } else {
            filters.jlptLevels.insert(level)
            // JLPT and name types are mutually exclusive under All — their
            // conjunction answers zero rows — so setting one clears the
            // other. Under Words/Names the other row's selection is merely
            // kept-but-ignored, and stays untouched.
            if filters.scope == .all {
                filters.nameTypes = []
            }
        }
        state.filters = filters
    }

    private func clearJLPTLevels() {
        var filters = state.filters
        filters.jlptLevels = []
        state.filters = filters
    }

    private func toggleNameType(_ badge: String) {
        var filters = state.filters
        if filters.nameTypes.contains(badge) {
            filters.nameTypes.remove(badge)
        } else {
            filters.nameTypes.insert(badge)
            // Mirror of the JLPT toggle above: mutually exclusive under All.
            if filters.scope == .all {
                filters.jlptLevels = []
            }
        }
        state.filters = filters
    }

    private func clearNameTypes() {
        var filters = state.filters
        filters.nameTypes = []
        state.filters = filters
    }

    private var scope: Binding<DictionarySearchFilters.Scope> {
        Binding(
            get: { state.filters.scope },
            set: { newValue in
                var filters = state.filters
                let leaving = filters.scope
                filters.scope = newValue
                // Nothing to clear here: `DictionarySearchState.filters`
                // normalizes COMMON away under Names on the way in, for every
                // writer, so the chip below can never be left reading live
                // over a scope that can never satisfy it.
                //
                // Entering All can reunite two selections the scoped rows kept
                // apart: JLPT picked under Words plus name types kept under
                // Words (or vice versa under Names). The side that was live in
                // the scope being left wins; the kept-but-ignored side clears,
                // so All never lands in the provably-empty conjunction.
                if newValue == .all {
                    switch leaving {
                    case .words: filters.nameTypes = []
                    case .names: filters.jlptLevels = []
                    case .all: break
                    }
                }
                state.filters = filters
            }
        )
    }

    /// Names are never common in the source data, so "Common only" over Names
    /// is structurally zero rows. `DictionarySearchState` clears the flag on the
    /// way into that scope, so none is left behind reading as a live filter the
    /// user could switch back off. Lives in the JLPT row past the divider, so
    /// the row's own dimming covers the disabled state — no local opacity here,
    /// or Names would double-dim the chip.
    private var commonOnlyToggle: some View {
        let disabled = state.filters.scope == .names
        let selected = state.filters.commonOnly && !disabled
        return FilterBadgeButton(
            text: "COMMON",
            selected: selected,
            selectedColor: Theme.dotGreen,
            disabled: disabled,
            help: disabled
                ? "Name entries are never marked common"
                : "Only entries the dictionary marks common",
            accessibility: "Common entries only"
        ) {
            var filters = state.filters
            filters.commonOnly.toggle()
            state.filters = filters
        }
    }
}

/// One toggle chip in the search filter panel: the shared
/// `DictionaryBadgeView` reading unselected in grey and selected in the
/// row's semantic color — pink for match tiers, green for COMMON, purple
/// for JLPT and name types — so a live filter wears exactly the color its
/// result badges wear. Offers the link cursor while enabled, like every
/// other control in the panel. File-level rather than nested so the panel's
/// rows stay out of the type-body budget.
private struct FilterBadgeButton: View {
    let text: String
    let selected: Bool
    var selectedColor: Color = Theme.accentPink
    var disabled = false
    var help: String
    var accessibility: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            DictionaryBadgeView(
                text: text, color: selected ? selectedColor : Theme.secondaryText
            )
        }
        .buttonStyle(.plain)
        .modifier(LinkCursor(enabled: !disabled))
        .disabled(disabled)
        .hoverHighlight(Capsule(), isEnabled: !selected && !disabled)
        .help(help)
        .accessibilityLabel(accessibility)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// The link cursor, only while `enabled`: a disabled control must never
/// offer the pointing hand.
private struct LinkCursor: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.pointerStyle(.link)
        } else {
            content
        }
    }
}

/// The scope control: one merged capsule whose selected segment wears the
/// badge look — accent text over an accent-tinted fill and stroke — instead of
/// a solid fill, so it reads as one of the filter chips rather than as a
/// separate control family.
private struct ScopeBadgePicker: View {
    @Binding var selection: DictionarySearchFilters.Scope

    var body: some View {
        HStack(spacing: 2) {
            ForEach(DictionarySearchFilters.Scope.allCases) { scope in
                segment(scope)
            }
        }
        .padding(3)
        .background(Capsule().fill(Theme.cardFill))
        .help("Which entries to search")
    }

    /// One scope segment: the visible label plus a selected trait and a
    /// state-carrying accessibility label, so VoiceOver names the scope and
    /// whether it is the active one.
    private func segment(_ scope: DictionarySearchFilters.Scope) -> some View {
        let isSelected = scope == selection
        return Button {
            selection = scope
        } label: {
            Text(scope.label)
                .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? Theme.accentPink : Theme.secondaryText)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .padding(.horizontal, 4)
                .background {
                    if isSelected {
                        Capsule().fill(Theme.accentPink.opacity(0.14))
                            .overlay(Capsule().stroke(Theme.accentPink.opacity(0.55)))
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .hoverHighlight(Capsule(), isEnabled: !isSelected)
        .accessibilityLabel("\(scope.label) scope")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}
