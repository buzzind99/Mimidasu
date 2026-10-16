import SwiftUI

/// The collapsible filter panel behind the dictionary search field's funnel
/// button: scope + reset, then the match, JLPT (+ COMMON), POS, and name-type
/// rows. Gone entirely while `filtersExpanded` is false, so the
/// list keeps the room.
///
/// Split from `DictionarySearchView` so both types stay inside the body
/// budget — the rows below are the panel's, and the result list stays the
/// window chrome's.
struct DictionaryFilterPanel: View {
    let state: DictionarySearchState
    /// The Names row's disclosure. Local chrome state, not a search filter:
    /// the panel is torn down whenever `filtersExpanded` flips false (and
    /// with the close), so this always returns to collapsed — which is the
    /// specified default.
    @State private var namesExpanded = false
    /// The POS row's disclosure. Same chrome-state contract as above.
    @State private var posExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            scopeRow
            matchRow
            jlptRow
            posRow
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
        // (JLPT/POS under Names, name types under Words) only exists alongside a
        // non-default scope, which narrows on its own — so Reset is never
        // enabled over a search identical to the defaults.
        let isDefault = state.filters == DictionarySearchFilters()
        return Button {
            state.apply(.reset)
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
        let disabled = !state.filters.scope.answersJLPT
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
        let disabled = !state.filters.scope.answersNameTypes
        return HStack(alignment: .top, spacing: 6) {
            // Same vertical padding as the POS caption below: the box matches
            // a chip's height so the text centers on the first chip line.
            caption("Names").padding(.vertical, 3)
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

    /// POS groups an entry must carry. Disabled under Names — POS describes
    /// word entries — with the selection kept, mirroring the JLPT row.
    /// Collapsible: eleven groups never fit one line, so the collapsed row
    /// shows only the pinned VERB / ADJECTIVE / NOUN / ADVERB chips (plus any
    /// active selection the pins would hide, plus All), with a chevron flowing
    /// right after the last badge toggling the full list.
    private var posRow: some View {
        let disabled = !state.filters.scope.answersPOS
        return HStack(alignment: .top, spacing: 6) {
            // The caption wears the badge chips' own vertical padding, so its
            // box matches a chip's height and the text centers inside it — on
            // the first chip line in both states, like the Match/JLPT rows.
            // A conditional HStack alignment instead visibly jumps the caption
            // on expand; top alignment never moves it, the list only grows
            // downward.
            caption("POS").padding(.vertical, 3)
            FlowLayout(spacing: 6, lineSpacing: 6, fingerprint: posFingerprint) {
                ForEach(visiblePOSGroups, id: \.self) { group in
                    FilterBadgeButton(
                        text: group.label,
                        selected: state.filters.posGroups.contains(group),
                        selectedColor: Theme.brandViolet,
                        disabled: disabled,
                        help: "Only \(group.label) entries",
                        accessibility: "\(group.label) only"
                    ) {
                        togglePOS(group)
                    }
                }
                FilterBadgeButton(
                    text: "All",
                    selected: state.filters.posGroups.isEmpty,
                    selectedColor: Theme.brandViolet,
                    disabled: disabled,
                    help: "All parts of speech",
                    accessibility: "All parts of speech"
                ) {
                    clearPOS()
                }
                posDisclosureButton
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .opacity(disabled ? 0.4 : 1)
        .help("POS groups apply to word entries")
    }

    /// The pinned chips the collapsed POS row keeps, in display order:
    /// verb, adjective, noun, adverb.
    private static let pinnedPOSGroups: [DictionarySearchFilters.POSGroup] = [.verb, .adjective, .noun, .adverb]

    /// The group chips on screen now. Collapsed: the pins in pinned order,
    /// plus any selected group the pins would otherwise hide — a live filter
    /// must never vanish behind the disclosure — in `POSGroup.allCases`
    /// order. Expanded: all.
    private var visiblePOSGroups: [DictionarySearchFilters.POSGroup] {
        guard !posExpanded else { return DictionarySearchFilters.POSGroup.allCases }
        let selected = state.filters.posGroups
        let extras = DictionarySearchFilters.POSGroup.allCases.filter { group in
            selected.contains(group) && !Self.pinnedPOSGroups.contains(group)
        }
        return Self.pinnedPOSGroups + extras
    }

    /// Keys the `FlowLayout` cache on what it lays out: the disclosure state,
    /// the chips on screen, and the selection (which recolors them).
    private var posFingerprint: String {
        let expanded = posExpanded ? "open" : "shut"
        let visible = visiblePOSGroups.map(\.label).joined(separator: "\n")
        let selected = state.filters.posGroups.map(\.label).sorted().joined(separator: "\n")
        return "\(expanded)\n\(visible)\n\(selected)"
    }

    /// The chevron toggling the POS row. A child of the flow, so it sits
    /// right after the last badge rather than pinned to the window's
    /// trailing edge. Chrome, not a filter, so it stays enabled while the
    /// chips themselves are disabled under Names.
    private var posDisclosureButton: some View {
        Button {
            posExpanded.toggle()
        } label: {
            Image(systemName: posExpanded ? "chevron.up" : "chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 20, height: 20)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .hoverHighlight(Circle())
        .help(posExpanded ? "Collapse parts of speech" : "Show all parts of speech")
        // No expanded trait exists in SwiftUI — the label itself carries the
        // state, the same pattern the row chevrons use.
        .accessibilityLabel(posExpanded ? "Collapse parts of speech" : "Show all parts of speech")
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
        state.apply(.toggleMatchGroup(group))
    }

    private func selectAllMatchGroups() {
        state.apply(.selectAllMatchGroups)
    }

    private func toggleJLPTLevel(_ level: Int) {
        state.apply(.toggleJLPTLevel(level))
    }

    private func clearJLPTLevels() {
        state.apply(.clearJLPTLevels)
    }

    private func toggleNameType(_ badge: String) {
        state.apply(.toggleNameType(badge))
    }

    private func clearNameTypes() {
        state.apply(.clearNameTypes)
    }

    private func togglePOS(_ group: DictionarySearchFilters.POSGroup) {
        state.apply(.togglePOS(group))
    }

    private func clearPOS() {
        state.apply(.clearPOS)
    }

    private var scope: Binding<DictionarySearchFilters.Scope> {
        Binding(
            get: { state.filters.scope },
            set: { newValue in
                // The Filter transition owns every carry-over and exclusion
                // rule, entering All included.
                state.apply(.setScope(newValue))
            }
        )
    }

    /// Names are never common in the source data, so "Common only" over Names
    /// is structurally zero rows. The Filter transition canonicalizes the flag
    /// away on the way into that scope, so none is left behind reading as a
    /// live filter the user could switch back off. Lives in the JLPT row past
    /// the divider, so the row's own dimming covers the disabled state — no
    /// local opacity here, or Names would double-dim the chip.
    private var commonOnlyToggle: some View {
        let disabled = !state.filters.scope.answersCommon
        return FilterBadgeButton(
            text: "COMMON",
            selected: state.filters.commonOnly,
            selectedColor: Theme.dotGreen,
            disabled: disabled,
            help: disabled
                ? "Name entries are never marked common"
                : "Only entries the dictionary marks common",
            accessibility: "Common entries only"
        ) {
            state.apply(.toggleCommonOnly)
        }
    }
}

/// One toggle chip in the search filter panel: the shared
/// `DictionaryBadgeView` reading unselected in grey and selected in the
/// row's semantic color — pink for match tiers, green for COMMON, purple
/// for JLPT, POS, and name types — so a live filter wears the row color its
/// result badges wear (POS has no search-row badge; its sense pills wear
/// pink, while the violet chip marks it word-side like JLPT). Offers the
/// link cursor while enabled, like every other control in the panel.
/// File-level rather than nested so the panel's rows stay out of the
/// type-body budget.
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
