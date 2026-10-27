import SwiftUI

// The pure content assembly (`DictionaryContent`) lives in
// `DictionaryContent.swift`; this file holds the view types both dictionary
// hosts render through. The favorite star lives in
// `DictionaryFavoriteButton.swift`, the pager and badge chip in
// `DictionaryChromeViews.swift`.

/// One row of tappable result pills under a mono label — the entry view's
/// "also:" fallback hits and the not-found view's "related:" suggestions
/// render through the same component so they can never diverge. Pills flow
/// and wrap: a tap resolves up to `JMDictExpansion.maxCandidates` candidates
/// and a found tap's "also:" row shows at most `DictionaryContent.maxAlsoPills`
/// pills (the display result takes one), more than fit one line.
struct DictionaryResultPillRow: View {
    let label: String
    let results: [LookupResult]
    var onSelect: (LookupResult) -> Void
    /// Favorites probe behind the pill star: true when the result leads with
    /// a favorited entry. Promotion already moved an eligible favorite to the
    /// front, so a favorited lead is the pill's starred word. nil keeps the
    /// pills starless — the not-found host passes nothing.
    var isFavoriteLead: ((LookupResult) -> Bool)?

    var body: some View {
        let pills = DictionaryContent.truncatedAlso(results)
        if !pills.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: label)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.secondaryText)
                FlowLayout(spacing: 6, lineSpacing: 4, fingerprint: fingerprint(pills)) {
                    ForEach(Array(pills.enumerated()), id: \.offset) { _, result in
                        pill(result)
                    }
                }
            }
        }
    }

    /// FlowLayout's cache key. A closure has no value identity, so the star
    /// flags ride the fingerprint by value: adding or dropping one re-measures
    /// exactly like a label change, and steady renders reuse the sizes.
    private func fingerprint(_ pills: ArraySlice<LookupResult>) -> String {
        pills.map { result in
            let starred = isFavoriteLead?(result) == true
            return (starred ? "★" : "") + DictionaryContent.pillLabel(for: result)
        }
        .joined(separator: "\n")
    }

    private func pill(_ result: LookupResult) -> some View {
        let label = DictionaryContent.pillLabel(for: result)
        let starred = isFavoriteLead?(result) == true
        let lookupA11yLabel = starred ? "Look up “\(label)”, favorited" : "Look up “\(label)”"
        return Button {
            onSelect(result)
        } label: {
            HStack(spacing: 3) {
                if starred {
                    Image(systemName: "star.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.favoriteStarYellow)
                        .accessibilityHidden(true)
                }
                Text(verbatim: label)
                    .font(.system(size: 12))
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Capsule().fill(Theme.accentPink.opacity(0.16)))
            .foregroundStyle(Theme.annotationPink)
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .accessibilityLabel(lookupA11yLabel)
        .help("Look up “\(label)”")
    }
}

/// The not-found card and popover content: the tapped surface with its
/// copy control and a plain "no entry" line — the lookup never promotes a
/// kanji-split fallback to the display result — and the split hits demoted
/// to "related:" pills (tapping one promotes it to the card's primary
/// result).
struct DictionaryNotFoundView: View {
    let surface: String
    let related: [LookupResult]
    var copyPlacement: DictionaryCopyPlacement = .none
    var onSelectRelated: (LookupResult) -> Void = { _ in }
    var onCopy: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(verbatim: surface)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(Theme.primaryText)
                        .lineLimit(1)
                        .textSelection(.disabled)
                    Spacer(minLength: 8)
                    DictionaryCopyButton(
                        placement: copyPlacement, help: "Copy the text", action: onCopy
                    )
                }
                Text("No dictionary entry")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.secondaryText)
                    .textSelection(.disabled)
            }
            DictionaryResultPillRow(
                label: "related:", results: related, onSelect: onSelectRelated
            )
        }
    }
}

// MARK: - Shared entry content view

/// Where the host places the copy control in the shared dictionary content.
enum DictionaryCopyPlacement {
    /// Small icon top-trailing of the header row.
    case icon
    /// No copy control.
    case none
}

/// The copy control behind `DictionaryCopyPlacement`: the compact icon tile,
/// shared by the found entry header and the not-found surface header so the
/// two hosts can never diverge.
struct DictionaryCopyButton: View {
    let placement: DictionaryCopyPlacement
    let help: String
    let action: () -> Void

    var body: some View {
        switch placement {
        case .icon:
            styled(iconLabel)
        case .none:
            EmptyView()
        }
    }

    private func styled(_ label: some View) -> some View {
        Button(action: action) {
            label
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .help(help)
        .accessibilityLabel(help)
    }

    private var iconLabel: some View {
        Image(systemName: "doc.on.doc")
            .font(.system(size: 11))
            .foregroundStyle(Theme.secondaryText)
            .frame(width: 22, height: 22)
            .background(Theme.tileFill.clipShape(RoundedRectangle(cornerRadius: 6)))
    }
}

/// The full dictionary entry composition — headword (+ reading), romaji,
/// badge row, pitch pill, numbered POS-labeled senses, "also:" pills, entry
/// pager — rendered by the popover, the sidebar card, and the two list
/// hosts. What each host *decides* (pager visibility, headword/badge
/// suppression, star style, copy placement, sense/gloss limits, sense-POS
/// wrapping) arrives as one `DictionaryDefinitionPlan`; what each host
/// *supplies* is the data this render shows — the entry its selection
/// policy resolved, its count and page, the "also:" hits, the badge origin,
/// the live star membership — and, from the sidebar card, the viewport: the
/// senses frame height and the three height probes its scroll math feeds.
struct DictionaryEntryContentView: View {
    /// This host's rendering stance, resolved from its mode. The host never
    /// re-states these decisions as flags.
    let plan: DictionaryDefinitionPlan
    /// The entry this render shows — the one the plan's entry-selection
    /// policy resolved at the call site (direct page, promoted lead, or the
    /// row's validated fallback).
    let entry: JMDictEntry
    let entryCount: Int
    /// The displayed entry's page within `entryCount` — the pager's `i` in
    /// `i/N`.
    let entryIndex: Int
    let also: [LookupResult]
    /// The candidate role the display result came from. A join lead shows
    /// the joined-match badge — the compound matched, not the tapped word.
    var displayOrigin: ExpansionOrigin?
    /// Membership of the displayed entry's headword. Recomputed by each host
    /// on every render rather than carried across lookups — a related-pill
    /// promotion repins both hosts to a *different* entry, and a cached value
    /// would show the previous one's membership until it happened to be
    /// replaced.
    var isFavorite = false
    /// When set, the sense rows render inside a vertical ScrollView framed
    /// to exactly this height — they scroll only when taller than it. The
    /// host derives it from the free sidebar space minus the fixed chrome.
    var sensesViewportHeight: CGFloat?
    /// Natural height of the fixed top section (header/romaji/badges/pitch).
    var onTopSectionHeightChange: (CGFloat) -> Void = { _ in }
    /// Natural height of the "also:" row (0 when absent).
    var onAlsoHeightChange: (CGFloat) -> Void = { _ in }
    /// Natural height of every sense row — the unclamped content height the
    /// viewport clamps against.
    var onSensesHeightChange: (CGFloat) -> Void = { _ in }
    var onToggleFavorite: () -> Void = {}
    var onCopy: () -> Void = {}
    var onSelectAlso: (LookupResult) -> Void = { _ in }
    /// Favorites probe for the "also:" pill row's star (nil = starless) —
    /// forwarded to `DictionaryResultPillRow.isFavoriteLead` unchanged.
    var isFavoritePillLead: ((LookupResult) -> Bool)?
    /// The header pager's step target. Reachable only while the plan puts
    /// the pager in this view's own header row; a host-placed pager (the
    /// sidebar card's label row) is the host's chrome and never routes
    /// here.
    var onStepEntry: (Int) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            topSection
                .onHeightChange { height in onTopSectionHeightChange(height) }
            sensesSection
            alsoSection
        }
    }

    private var headword: String {
        entry.headword ?? entry.reb ?? "—"
    }

    private var reading: String? {
        entry.keb != nil ? entry.reb : nil
    }

    private var headwordText: some View {
        Text(verbatim: headword)
            .font(.system(size: 26))
            .foregroundStyle(Theme.primaryText)
            .lineLimit(1)
            .textSelection(.disabled)
    }

    private var headerRow: some View {
        // Center alignment keeps the row exactly the headword's height: the
        // 18pt pager buttons hang well below a text baseline and would
        // otherwise stretch the header whenever a multi-entry lookup shows
        // them.
        HStack(spacing: 8) {
            // Inline reading beside the kanji while the pair fits; when it
            // doesn't, the furigana-style stack moves the reading above the
            // (still truncating) headword instead of eclipsing it.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    headwordText
                        .fixedSize(horizontal: true, vertical: false)
                    if let reading {
                        Text(verbatim: reading)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Theme.annotationPink)
                            .lineLimit(1)
                            .textSelection(.disabled)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
                stackedHeadword
            }
            Spacer(minLength: 8)
            if entryCount > 1, plan.showsEntryPager {
                entryPager
            }
            // Both hosts lead with copy and follow with the star, so the reading order
            // is the same in the narrow sidebar column and the wider popover.
            // Only the glyph differs by the plan's star style: the card's is a
            // tiled 14pt mark that pairs with the copy tile, the popover's a
            // bare 18pt glyph that keeps the header one line so the romaji
            // below never moves.
            copyButton
            favoriteButton
        }
    }

    /// Furigana-style fallback: the kana reading above the headword, leading
    /// aligned with it, which keeps its own truncation — the reading never
    /// competes for the kanji's line.
    private var stackedHeadword: some View {
        VStack(alignment: .leading, spacing: 1) {
            if let reading {
                Text(verbatim: reading)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.annotationPink)
                    .lineLimit(1)
                    .textSelection(.disabled)
            }
            headwordText
        }
    }

    /// `◀ i/N ▶` walker over the entries a homograph candidate matched.
    private var entryPager: some View {
        DictionaryEntryPager(
            entryIndex: entryIndex,
            entryCount: entryCount,
            onStep: onStepEntry
        )
    }

    private var copyButton: some View {
        DictionaryCopyButton(
            placement: plan.copyPlacement, help: "Copy the headword", action: onCopy
        )
    }

    private var favoriteButton: some View {
        DictionaryFavoriteButton(
            isFavorite: isFavorite,
            subject: headword,
            style: plan.favoriteStyle,
            action: onToggleFavorite
        )
    }

    /// The badge row: the joined-match badge (when the displayed result came
    /// from a forward join) leading the shared tail — commonness, the JLPT
    /// level, and the name types. The joined-match badge wears the popover's
    /// own violet and carries no match icon: it names where the *result*
    /// came from, which is not the same claim a search row's match badge
    /// makes.
    private var badgeRow: some View {
        DictionaryBadgeRow(
            badges: dictionaryBadges(
                leading: joinedMatchBadge,
                common: entry.common,
                jlpt: entry.jlpt,
                namePosTokens: JMDictNameEntries.isName(entry) ? entry.senses.map(\.pos) : []
            )
        )
    }

    /// The joined-match chip the display result carries, or nil for a result
    /// that matched the tapped word's own surface or lemma.
    private var joinedMatchBadge: DictionaryBadge? {
        guard let text = displayOrigin.flatMap(DictionaryContent.joinedMatchBadge(for:)) else {
            return nil
        }
        return DictionaryBadge(text: text, color: DictionaryBadgeChip.metaColor)
    }

    private func pitchPill(_ pitch: DictionaryContent.PitchPill) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "speaker.wave.2")
                .font(.system(size: 9))
                .foregroundStyle(Theme.secondaryText)
            if let hatsuon = pitch.hatsuon {
                Text(verbatim: hatsuon)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.primaryText)
                Text(verbatim: "·")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.secondaryText)
            }
            if let zo = pitch.zoPatts {
                Text(verbatim: zo)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.primaryText)
                    .kerning(1)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Capsule().fill(Theme.tileFill))
    }

    /// Everything above the senses: header (+ pager/copy/star), romaji, badges,
    /// pitch pill — never scrolls in the card host. Nested `spacing: 8`
    /// matches the outer VStack so the inline (popover) layout is unchanged.
    private var topSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if plan.showsHeadword {
                VStack(alignment: .leading, spacing: 2) {
                    headerRow
                    if let romaji = DictionaryContent.romaji(for: entry) {
                        Text(romaji)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Theme.secondaryText)
                            .lineLimit(1)
                            .textSelection(.disabled)
                    }
                }
            }
            if plan.showsBadges {
                badgeRow
            }
            if let pitch = DictionaryContent.pitchPill(for: entry) {
                pitchPill(pitch)
            }
        }
    }

    /// Sense rows inside the host-chosen container: a viewport-clamped
    /// ScrollView for the card, inline for the popover. The zero-spacing
    /// wrapper keeps the height probe live even when the rows are empty.
    @ViewBuilder
    private var sensesSection: some View {
        let measuredRows = VStack(spacing: 0) { senseRows }
            .onHeightChange { height in onSensesHeightChange(height) }
        if let viewport = sensesViewportHeight {
            ScrollView(.vertical) {
                measuredRows
            }
            .frame(height: max(0, viewport))
            .scrollBounceBehavior(.basedOnSize)
        } else {
            measuredRows
        }
    }

    @ViewBuilder
    private var senseRows: some View {
        if entry.isName {
            nameGlossRows
        } else {
            let truncated = DictionaryContent.truncated(entry.senses, limit: plan.senseLimit)
            if !truncated.visible.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(truncated.visible.enumerated()), id: \.offset) { index, sense in
                        senseRow(number: index + 1, sense: sense)
                    }
                    if truncated.hidden > 0 {
                        Text("+ \(truncated.hidden) more senses")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Theme.secondaryText)
                    }
                }
            }
        }
    }

    /// A name sense's remaining glosses as numbered rows — the type badge
    /// moved to the badge row and the romanization echo dropped, so what's
    /// left is real content only.
    @ViewBuilder
    private var nameGlossRows: some View {
        let truncated = DictionaryContent.truncated(
            DictionaryContent.nameGlosses(for: entry), limit: plan.glossLimit
        )
        if !truncated.visible.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(truncated.visible.enumerated()), id: \.offset) { index, gloss in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        senseNumber(index + 1)
                        Text(verbatim: gloss)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.primaryText)
                            .textSelection(.disabled)
                    }
                }
                if truncated.hidden > 0 {
                    Text("+ \(truncated.hidden) more")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.secondaryText)
                }
            }
        }
    }

    @ViewBuilder
    private func senseRow(number: Int, sense: JMDictSense) -> some View {
        let labels = DictionaryContent.posLabels(sense.pos)
        let glosses = DictionaryContent.truncated(sense.glosses, limit: plan.glossLimit)
        // Visible glosses join into one text; a hidden tail closes with an
        // ellipsis. The inline form holds it to one line, the stacked form
        // lets it wrap beneath the tags.
        let gloss = Text(
            glosses.visible.joined(separator: "; ")
                + (glosses.hidden > 0 ? "; …" : "")
        )
        .font(.system(size: 12))
        .foregroundStyle(Theme.primaryText)
        .textSelection(.disabled)
        if plan.wrapsSensePOS, labels.count > 1 {
            // Inline while the number, tags, and whole gloss fit one line;
            // only then does the row fall back to the stacked form. The
            // number leads the tag line only; the gloss starts at the tags'
            // leading edge — after the number column, not back under the
            // number — and keeps that inset on every wrapped line.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    senseNumber(number)
                    posBadges(labels)
                    gloss.lineLimit(1)
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    senseNumber(number)
                    VStack(alignment: .leading, spacing: 3) {
                        // FlowLayout for the reason the badge row uses it: a
                        // long tag set wraps inside the card instead of
                        // clipping at its trailing edge.
                        FlowLayout(
                            spacing: 6, lineSpacing: 4,
                            fingerprint: labels.joined(separator: "\n")
                        ) {
                            posBadges(labels)
                        }
                        gloss
                    }
                }
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                senseNumber(number)
                posBadges(labels)
                gloss
            }
        }
    }

    /// The leading "1." column every numbered row shares.
    private func senseNumber(_ number: Int) -> some View {
        Text("\(number).")
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(Theme.secondaryText)
    }

    private func posBadges(_ labels: [String]) -> some View {
        ForEach(labels, id: \.self) { label in
            DictionaryBadgeView(text: label, color: Theme.accentPink, compact: true)
        }
    }

    /// "also:" pills — always rendered below the senses viewport, never
    /// scrolled. The zero-spacing wrapper keeps the height probe at 0 when
    /// the row is absent (no stale measurement on entry switches).
    private var alsoSection: some View {
        VStack(spacing: 0) {
            DictionaryResultPillRow(
                label: "also:", results: also, onSelect: onSelectAlso,
                isFavoriteLead: isFavoritePillLead
            )
        }
        .onHeightChange { height in onAlsoHeightChange(height) }
    }
}

extension Collection where Index == Int {
    /// The element at `index` when in bounds — the search row reads a
    /// validated page against a promoted list a star press may have
    /// reordered concurrently.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

extension View {
    /// Height probe used by the dictionary card's scroll sizing: reports
    /// the view's own height through `onGeometryChange`.
    func onHeightChange(_ action: @escaping (CGFloat) -> Void) -> some View {
        onGeometryChange(for: CGFloat.self, of: \.size.height, action: action)
    }
}

// The card surface (fill + stroke) is `View.cardSurface` in Theme.swift.
