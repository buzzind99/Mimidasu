import SwiftUI

/// The collapsible filter panel behind the dictionary search field's funnel
/// button: scope + COMMON, then the match, JLPT, and name-type rows. Gone
/// entirely while `filtersExpanded` is false, so the list keeps the room.
///
/// Split from `DictionarySearchView` so both types stay inside the body
/// budget — the rows below are the panel's, and the result list stays the
/// window chrome's.
struct DictionaryFilterPanel: View {
    let state: DictionarySearchState

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
            commonOnlyToggle
            Spacer(minLength: 0)
        }
    }

    /// Which match tiers may answer. Every group toggles independently, and All
    /// switches every group back on; the last enabled group cannot be switched
    /// off, so the row can never narrow the answer to nothing.
    private var matchRow: some View {
        HStack(spacing: 6) {
            caption("Match")
            ForEach(DictionarySearchFilters.MatchGroup.allCases, id: \.self) { group in
                FilterBadgeButton(
                    text: group.label,
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

    /// JLPT levels an entry must carry. Disabled under Names — levels describe
    /// word entries — with the selection kept, so switching back restores it.
    private var jlptRow: some View {
        let disabled = state.filters.scope == .names
        return HStack(spacing: 6) {
            caption("JLPT")
            ForEach(1 ... 5, id: \.self) { level in
                FilterBadgeButton(
                    text: "N\(level)",
                    selected: state.filters.jlptLevels.contains(level),
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
                disabled: disabled,
                help: "All JLPT levels",
                accessibility: "All JLPT levels"
            ) {
                clearJLPTLevels()
            }
            Spacer(minLength: 0)
        }
        .opacity(disabled ? 0.4 : 1)
        .help("JLPT levels apply to word entries")
    }

    /// Name-type badges an entry must carry. Disabled under Words — types
    /// describe name entries — with the selection kept, mirroring the JLPT row.
    /// The chips wrap: twenty-two types plus All never fit one line.
    private var nameTypeRow: some View {
        let disabled = state.filters.scope == .words
        return HStack(alignment: .top, spacing: 6) {
            caption("Names")
            FlowLayout(
                spacing: 6, lineSpacing: 6,
                fingerprint: state.filters.nameTypes.sorted().joined(separator: "\n")
            ) {
                ForEach(DictionaryContent.allNameTypeBadges, id: \.self) { badge in
                    FilterBadgeButton(
                        text: badge,
                        selected: state.filters.nameTypes.contains(badge),
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
                    disabled: disabled,
                    help: "All name types",
                    accessibility: "All name types"
                ) {
                    clearNameTypes()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .opacity(disabled ? 0.4 : 1)
        .help("Name types apply to name entries")
    }

    /// The small leading label each filter row carries, fixed wide so the
    /// chips line up in one column down the panel.
    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Theme.secondaryText)
            .frame(width: 44, alignment: .leading)
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
                filters.scope = newValue
                // Nothing to clear here: `DictionarySearchState.filters`
                // normalizes COMMON away under Names on the way in, for every
                // writer, so the chip below can never be left reading live
                // over a scope that can never satisfy it.
                state.filters = filters
            }
        )
    }

    /// Names are never common in the source data, so "Common only" over Names
    /// is structurally zero rows. `DictionarySearchState` clears the flag on the
    /// way into that scope, so none is left behind reading as a live filter the
    /// user could switch back off.
    private var commonOnlyToggle: some View {
        let disabled = state.filters.scope == .names
        let selected = state.filters.commonOnly && !disabled
        return FilterBadgeButton(
            text: "COMMON",
            selected: selected,
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
        .opacity(disabled ? 0.4 : 1)
    }
}

/// One toggle chip in the search filter panel: a `DictionaryBadgeView` reading
/// selected in accent and unselected in grey, so every row speaks the same
/// selected language as the scope capsule. File-level rather than nested so
/// the panel's rows stay out of the type-body budget.
private struct FilterBadgeButton: View {
    let text: String
    let selected: Bool
    var disabled = false
    var help: String
    var accessibility: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            DictionaryBadgeView(
                text: text, color: selected ? Theme.accentPink : Theme.secondaryText
            )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .hoverHighlight(Capsule(), isEnabled: !selected && !disabled)
        .help(help)
        .accessibilityLabel(accessibility)
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
    }
}
