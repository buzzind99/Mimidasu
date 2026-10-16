import SwiftUI

// The dictionary's small shared chrome, split out of
// `DictionaryLookupViews.swift`: the entry pager a host places on its header
// row and the badge chip every dictionary surface renders.

/// `◀ i/N ▶` walker over the entries a homograph candidate matched — shared
/// by the popover header row and the sidebar card's DICTIONARY label row.
struct DictionaryEntryPager: View {
    /// Row height the pager always occupies (the button circles); hosts
    /// reserve it so their header rows keep a constant height with and
    /// without the pager.
    static let height: CGFloat = 18

    let entryIndex: Int
    let entryCount: Int
    var onStep: (Int) -> Void

    var body: some View {
        HStack(spacing: 4) {
            pagerButton("chevron.left", enabled: entryIndex > 0) {
                onStep(entryIndex - 1)
            }
            Text("\(entryIndex + 1)/\(entryCount)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Theme.secondaryText)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            pagerButton("chevron.right", enabled: entryIndex < entryCount - 1) {
                onStep(entryIndex + 1)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func pagerButton(_ icon: String, enabled: Bool, action: @escaping () -> Void)
        -> some View
    {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(enabled ? Theme.primaryText : Theme.secondaryText.opacity(0.4))
                .frame(width: Self.height, height: Self.height)
                .background(Theme.tileFill.clipShape(Circle()))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .pointerStyle(enabled ? .link : nil)
    }
}

/// One badge chip (COMMON, ≈N5, POS): outlined capsule with a tinted fill,
/// optionally led by a glyph. The icon marks the chips that say *why this row
/// is here* rather than *what this word is* — the dictionary search's
/// EXACT/PREFIX/GLOSS/LEMMA match badges — so the two kinds never read as the
/// same claim.
struct DictionaryBadgeView: View {
    let text: String
    let color: Color
    var compact = false
    var icon: String?

    var body: some View {
        HStack(spacing: 3) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: compact ? 8 : 9, weight: .semibold))
                    .accessibilityHidden(true)
            }
            Text(text)
                .font(.system(size: compact ? 9 : 10, weight: .semibold))
        }
        .fixedSize()
        .padding(.horizontal, compact ? 5 : 7)
        .padding(.vertical, compact ? 2 : 3)
        .background(
            Capsule().fill(color.opacity(0.14))
                .overlay(Capsule().stroke(color.opacity(0.55)))
        )
        .foregroundStyle(color)
    }
}
