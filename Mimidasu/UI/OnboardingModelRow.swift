import SwiftUI

/// The onboarding variant of the settings model card (`SettingsModelRow`):
/// selection is always allowed (it picks the download target, not a
/// ready-to-run model), the shared `downloader` follows the picked card, and
/// download affordances appear only on the picked card. The picked state
/// shows as the card's accent fill/stroke — no "In use" pill or checkmark —
/// and the footer shows only the size (no downloaded/not-downloaded story).
struct OnboardingModelRow: View {
    let choice: ASRModelChoice
    var model: AppModel
    /// Shared with `OnboardingView`, which resets it when the selection
    /// changes: switching targets abandons any in-flight download.
    let downloader: ModelDownloader

    var resolvedURL: URL? {
        model.modelAvailability[choice]
    }

    /// Whether this choice is the download target.
    var isPicked: Bool {
        model.asrModelSettings.selected == choice
    }

    var body: some View {
        ModelChoiceCard(
            choice: choice,
            resolvedURL: resolvedURL,
            downloader: downloader,
            isSelected: isPicked,
            // Picking the download target is always allowed here.
            selectionDisabled: false,
            onSelect: { model.asrModelSettings.select(choice) },
            showsSelectionBadge: Self.showsSelectionBadge,
            showsDownloadControls: showsDownloadControls,
            statusOnlyWhenSelected: Self.statusOnlyWhenSelected,
            footerStyle: Self.footerStyle
        )
    }
}

extension OnboardingModelRow {
    /// The onboarding card shows no badge.
    static let showsSelectionBadge = false
    /// The onboarding card shows the download status on the picked card
    /// only: both cards observe the same shared downloader.
    static let statusOnlyWhenSelected = true
    /// The onboarding card's resting footer line is the size alone.
    static let footerStyle: ModelChoiceCard.FooterStyle = .sizeOnly

    /// The download overlay renders on the picked card only.
    var showsDownloadControls: Bool {
        isPicked
    }
}
