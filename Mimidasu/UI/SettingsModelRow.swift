import SwiftUI

/// A model card in the Settings Speech Model card (see
/// `SettingsView.modelCard`). Owns one `ModelDownloader` per choice so
/// downloads run (and resume) independently; a completed Settings download
/// auto-selects the model.
@MainActor
struct SettingsModelRow: View {
    let choice: ASRModelChoice
    var model: AppModel
    @State private var downloader: ModelDownloader

    init(choice: ASRModelChoice, model: AppModel) {
        self.choice = choice
        self.model = model
        _downloader = State(initialValue: ModelDownloader(choice: choice))
    }

    var resolvedURL: URL? {
        model.modelAvailability[choice]
    }

    /// Whether this choice is the model in use.
    var isInUse: Bool {
        model.asrModelSettings.selected == choice
    }

    /// A selection change applies at the next session start; mid-session
    /// (.running/.starting) it is disabled.
    var selectionDisabled: Bool {
        resolvedURL == nil || model.phase == .running || model.phase == .paused || model.phase == .starting
    }

    var body: some View {
        ModelChoiceCard(
            choice: choice,
            resolvedURL: resolvedURL,
            downloader: downloader,
            isSelected: isInUse,
            selectionDisabled: selectionDisabled,
            onSelect: { model.selectModel(choice) },
            showsSelectionBadge: Self.showsSelectionBadge,
            showsDownloadControls: Self.showsDownloadControls,
            statusOnlyWhenSelected: Self.statusOnlyWhenSelected,
            footerStyle: Self.footerStyle
        )
        .onChange(of: downloader.state) { _, state in
            // A finished Settings download is explicit intent: verify the
            // new file and auto-select it (see `adoptDownloadedModel`).
            if case .done = state {
                Task { await model.adoptDownloadedModel(choice) }
            }
        }
    }
}

extension SettingsModelRow {
    /// The Settings card badges the model in use.
    static let showsSelectionBadge = true
    /// The Settings card always shows the download overlay.
    static let showsDownloadControls = true
    /// The Settings card always shows the download status in its footer.
    static let statusOnlyWhenSelected = false
    /// The Settings card's resting footer line reads the size and the
    /// downloaded state.
    static let footerStyle: ModelChoiceCard.FooterStyle = .sizeAndStatus
}
