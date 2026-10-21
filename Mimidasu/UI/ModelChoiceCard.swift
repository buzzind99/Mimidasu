import SwiftUI

/// The shared model-choice card: one card per ASR model choice, rendered by
/// the Settings model row and the onboarding model row alike.
///
/// The card owns the chrome — the title, the surface, the hover treatment,
/// the download overlay and the footer — and none of the decisions: the
/// selection action arrives as a closure, the downloader arrives injected,
/// and every difference between the two surfaces arrives as a flag.
///
/// The card never sees `AppModel`: it takes the resolved model URL, the
/// selection state, the disabled state and the action.
@MainActor
struct ModelChoiceCard: View {

    // MARK: - Types

    /// How the footer's resting line reads.
    enum FooterStyle: Equatable {
        /// `size · downloaded` / `size · not downloaded`.
        case sizeAndStatus
        /// The size alone.
        case sizeOnly
    }

    /// The footer's content, as data.
    enum Footer: Equatable {
        /// A download in flight.
        case progress(bytes: Int64, total: Int64?)
        /// A failed download.
        case error(message: String)
        /// The size alone.
        case sizeOnly(size: String)
        /// The size plus whether the model is downloaded.
        case sizeAndStatus(size: String, downloaded: Bool)
    }

    /// The card's chrome decisions, as data: what the flags mean, in one
    /// place.
    struct Chrome: Equatable {
        /// The title carries the "In use" badge.
        var showsSelectionBadge: Bool
        /// The card's button is unpressable.
        var isDisabled: Bool
        /// The hover wash shows.
        var showsHover: Bool
        /// The download overlay renders.
        var showsDownloadOverlay: Bool
        /// What the footer shows.
        var footer: Footer
    }

    // MARK: - Parameters

    /// The choice this card stands for.
    let choice: ASRModelChoice
    /// The resolved model file, or `nil` while it is missing.
    let resolvedURL: URL?
    /// The downloader this card reports on. Injected, never created here:
    /// the Settings row owns one per choice, the onboarding row shares one
    /// across both cards.
    let downloader: ModelDownloader
    /// Whether this choice is the selected one.
    ///
    /// Settings reads it as "this is the model in use"; onboarding reads it
    /// as "this is the download target". The expression is the same
    /// (`asrModelSettings.selected == choice`), the meaning is not.
    let isSelected: Bool
    /// Whether the card may not be selected right now.
    let selectionDisabled: Bool
    /// The selection action.
    let onSelect: () -> Void
    /// Whether the title carries the selection badge. The badge marks the
    /// *selected* card, so it needs the flag and the selection.
    let showsSelectionBadge: Bool
    /// Whether the download overlay renders.
    let showsDownloadControls: Bool
    /// Whether the footer's progress/error branch is limited to the selected
    /// card.
    let statusOnlyWhenSelected: Bool
    /// How the footer's resting line reads.
    let footerStyle: FooterStyle

    // MARK: - Body

    var body: some View {
        card
            .overlay(alignment: .topTrailing) {
                if chrome.showsDownloadOverlay {
                    downloadControls.padding(12)
                }
            }
    }

    // MARK: - Chrome

    /// The badge marks the *selected* card: it needs the flag and the
    /// selection.
    private var showsBadge: Bool {
        showsSelectionBadge && isSelected
    }

    /// The hover wash never shows while the card is disabled or already
    /// selected.
    private var showsHover: Bool {
        !selectionDisabled && !isSelected
    }

    /// The footer's progress/error branch, gated on the selection.
    private var showsDownloadStatus: Bool {
        statusOnlyWhenSelected ? isSelected : true
    }

    /// The chrome decisions, as data.
    var chrome: Chrome {
        Chrome(
            showsSelectionBadge: showsBadge,
            isDisabled: selectionDisabled,
            showsHover: showsHover,
            showsDownloadOverlay: showsDownloadControls,
            footer: footerPlan
        )
    }

    /// The footer's content, as data.
    private var footerPlan: Footer {
        guard showsDownloadStatus else { return restingFooter }
        switch downloader.state {
        case let .downloading(_, bytes, total):
            return .progress(bytes: bytes, total: total)
        case let .failed(message):
            return .error(message: message)
        default:
            // A stale `.done` (the file deleted after a completed download)
            // must not read "downloaded": it falls through to the resting
            // line, which reads the resolved URL.
            return restingFooter
        }
    }

    /// The footer's resting line.
    private var restingFooter: Footer {
        switch footerStyle {
        case .sizeAndStatus:
            .sizeAndStatus(size: choice.approximateSize, downloaded: resolvedURL != nil)
        case .sizeOnly:
            .sizeOnly(size: choice.approximateSize)
        }
    }

    // MARK: - Card

    private var card: some View {
        selectableButton
            .cardSurface(
                radius: 12,
                fill: isSelected ? Palette.accent.opacity(0.08) : Palette.cardFill,
                stroke: isSelected ? Palette.accent.opacity(0.55) : Palette.cardStroke
            )
            .hoverHighlight(
                RoundedRectangle(cornerRadius: 12, style: .continuous),
                isEnabled: chrome.showsHover,
                tint: Palette.accent, opacity: 0.06
            )
    }

    /// The card's button, disabled only when it really is disabled: a
    /// `.disabled(false)` would re-enable the card under a disabled
    /// ancestor, so the modifier is applied only when the card is disabled.
    @ViewBuilder
    private var selectableButton: some View {
        if chrome.isDisabled {
            button.disabled(true)
        } else {
            button
        }
    }

    private var button: some View {
        Button {
            guard !selectionDisabled, !isSelected else { return }
            onSelect()
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                title
                Text(choice.modelName)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Palette.primaryText)
                Text(choice.blurb)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                footer
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 148, alignment: .topLeading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The title, with the selection badge on the surfaces that show one.
    @ViewBuilder
    private var title: some View {
        if showsSelectionBadge {
            HStack(spacing: 6) {
                Text(choice.displayName)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Palette.primaryText)
                if chrome.showsSelectionBadge {
                    Label("In use", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Palette.accent)
                }
            }
        } else {
            Text(choice.displayName)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Palette.primaryText)
        }
    }

    // MARK: - Download controls

    /// Download affordances for a missing model; these stay enabled even
    /// while selection is disabled (mid-session or not-yet-downloaded).
    @ViewBuilder
    private var downloadControls: some View {
        switch downloader.state {
        case .downloading:
            SettingsPill(label: "Cancel") { downloader.cancel() }
        case .failed:
            SettingsPill(label: "Retry") { downloader.start() }
        default:
            if resolvedURL == nil {
                Button {
                    downloader.start()
                } label: {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 14))
                        .foregroundStyle(Palette.accent)
                        .padding(6)
                        .background(Circle().fill(Palette.pillFill))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .hoverHighlight(Circle(), tint: Palette.accent, opacity: 0.12)
                .help("Download \(choice.displayName) model (\(choice.approximateSize))")
            }
        }
    }

    // MARK: - Footer

    @ViewBuilder
    private var footer: some View {
        switch chrome.footer {
        case let .progress(bytes, total):
            ModelDownloadProgressView(bytes: bytes, total: total)
        case let .error(message):
            Text(message)
                .font(.system(size: 10.5))
                .foregroundStyle(Palette.statusRed)
                .fixedSize(horizontal: false, vertical: true)
        case let .sizeOnly(size):
            Text(size)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(Palette.mutedText)
        case let .sizeAndStatus(size, downloaded):
            Text("\(size) · \(downloaded ? "downloaded" : "not downloaded")")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(downloaded ? Palette.mutedText : Palette.statusRed)
        }
    }
}
