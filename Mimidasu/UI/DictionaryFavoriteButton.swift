import SwiftUI

/// Which header the favorite star sits in. Both variants are one glyph in one
/// 22×22 frame, and both follow the copy control — only the size and the tile
/// differ, so neither changes the header row's height and the romaji below
/// never moves.
enum DictionaryFavoriteStyle {
    /// Sidebar card: 14pt glyph on the `tileFill` rounded-rect the copy icon
    /// uses, so the two tiles read as one control pair.
    case card
    /// Popover: 18pt glyph, no tile — a tile behind a star reads as a button
    /// next to another button.
    case popover
}

/// The star behind both dictionary hosts, so the popover and the card can
/// never disagree about membership. Never disabled at the cap: a dead-looking
/// star is worse than a press that explains itself, and a full list answers
/// with the amber notice instead.
struct DictionaryFavoriteButton: View {
    let isFavorite: Bool
    /// The displayed entry's headword, named in the help and accessibility
    /// strings so both hosts phrase the same action identically.
    let subject: String
    var style: DictionaryFavoriteStyle = .card
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            switch style {
            case .card:
                glyph(size: 14, tiled: true)
            case .popover:
                glyph(size: 18, tiled: false)
            }
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .help(help)
        // The glyph alone announces as "star", which is worse than nothing.
        .accessibilityLabel(help)
    }

    /// Filled when starred, outline when not — `Theme.secondaryText` reads as
    /// "available", the star tint as "yours".
    @ViewBuilder
    private func glyph(size: CGFloat, tiled: Bool) -> some View {
        let star = Image(systemName: isFavorite ? "star.fill" : "star")
            .font(.system(size: size))
            .foregroundStyle(isFavorite ? Theme.favoriteStarYellow : Theme.secondaryText)
            .frame(width: 22, height: 22)
        if tiled {
            // Byte-identical to `DictionaryCopyButton.iconLabel`.
            star.background(Theme.tileFill.clipShape(RoundedRectangle(cornerRadius: 6)))
        } else {
            star
        }
    }

    private var help: String {
        isFavorite
            ? "Remove \"\(subject)\" from favorites"
            : "Add \"\(subject)\" to favorites"
    }
}
