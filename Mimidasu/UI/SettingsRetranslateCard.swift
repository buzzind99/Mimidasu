import SwiftUI

/// RE-TRANSLATE settings card: which engine the transcript row's
/// re-translate button uses, as a custom dropdown. The collapsed control is
/// the selection card — the current option's title over its description —
/// and clicking it opens a popover of option cards. The session engine is
/// always offered; every other option lists only while it differs from the
/// live session engine — an Apple model hides while the live Apple session
/// runs that same model de facto, and a configured external hides while it
/// is the attached provider. The marker toggle controls the muted
/// "· via <engine>" provenance suffix on retried rows.
struct SettingsRetranslateCard: View {
    @Bindable private var model: AppModel
    @Bindable private var settings: TranslationSettings
    @State private var showsOptions = false

    /// One engine option in the dropdown.
    private struct Option: Identifiable {
        let engine: RetranslateEngine
        let title: String
        let subtitle: String
        var id: String {
            engine.rawValue
        }
    }

    init(model: AppModel, settings: TranslationSettings) {
        _model = Bindable(wrappedValue: model)
        _settings = Bindable(wrappedValue: settings)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            KickerLabel("RE-TRANSLATE", color: Palette.label)
            selectionCard
            Text("Only providers with a configured API key appear here.")
                .font(.system(size: 10.5))
                .foregroundStyle(Palette.mutedText)
            settingsDivider()
            markerToggle
        }
        .padding(16)
        .cardSurface(shadow: Palette.cardShadow)
    }

    /// The provenance marker switch, drawn with the accent checkbox style.
    private var markerToggle: some View {
        Toggle(isOn: $settings.showsRetranslateMarker) {
            Text("Show engine on re-translated lines")
                .font(.system(size: 12.5))
                .foregroundStyle(Palette.secondaryText)
        }
        .toggleStyle(AccentCheckboxStyle())
    }

    // MARK: - Selection card

    /// The collapsed control: the current option's title on top, its
    /// description underneath, and a chevron that flips while the popover is
    /// up.
    private var selectionCard: some View {
        Button {
            showsOptions = true
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(displayedOption.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Palette.primaryText)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Palette.mutedText)
                        .rotationEffect(.degrees(showsOptions ? 180 : 0))
                }
                Text(displayedOption.subtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Palette.mutedText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .cardSurface(
            radius: 11,
            fill: Palette.tileFill,
            stroke: showsOptions ? Palette.accent.opacity(0.55) : Palette.cardStroke
        )
        .hoverHighlight(
            RoundedRectangle(cornerRadius: 11, style: .continuous),
            tint: Palette.accent, opacity: 0.06
        )
        .accessibilityLabel("Re-translate engine: \(displayedOption.title)")
        .popover(isPresented: $showsOptions, arrowEdge: .bottom) {
            optionsMenu
        }
    }

    /// The option the selection card renders: the persisted selection while
    /// it's listed, otherwise the session engine — a filtered-out selection
    /// (it duplicates the live session engine) resolves to the session path
    /// anyway.
    private var displayedOption: Option {
        engineOptions.first(where: { option in option.engine == settings.retranslateEngine })
            ?? sessionOption
    }

    // MARK: - Options popover

    private var optionsMenu: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(engineOptions) { option in
                optionCard(option)
            }
        }
        .padding(10)
        .frame(width: 300)
    }

    /// One option card: title over description, checkmarked while selected.
    private func optionCard(_ option: Option) -> some View {
        let isSelected = option.engine == settings.retranslateEngine
        return Button {
            model.selectRetranslateEngine(option.engine)
            showsOptions = false
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(option.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Palette.primaryText)
                    Spacer()
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(Palette.accent)
                    }
                }
                Text(option.subtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Palette.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .cardSurface(
            radius: 10,
            fill: isSelected ? Palette.accent.opacity(0.08) : Palette.cardFill,
            stroke: isSelected ? Palette.accent.opacity(0.55) : Palette.cardStroke
        )
        .hoverHighlight(
            RoundedRectangle(cornerRadius: 10, style: .continuous),
            isEnabled: !isSelected,
            tint: Palette.accent, opacity: 0.06
        )
        .accessibilityLabel("\(option.title). \(option.subtitle)")
    }

    // MARK: - Options

    private var engineOptions: [Option] {
        var options: [Option] = [sessionOption]
        if !model.liveSessionRunsKind(.appleFast) {
            options.append(appleFastOption)
        }
        if #available(macOS 26.4, *), !model.liveSessionRunsKind(.appleHighFidelity) {
            options.append(appleIntelligenceOption)
        }
        options.append(
            contentsOf: TranslationProvider.allCases
                .filter { provider in
                    provider.isExternal
                        && settings.hasKey(for: provider)
                        && provider != model.activeExternalProvider
                }
                .compactMap(externalOption)
        )
        return options
    }

    private var sessionOption: Option {
        Option(
            engine: .session,
            title: "Session engine",
            subtitle: "Same as active engine"
        )
    }

    private var appleFastOption: Option {
        Option(
            engine: .appleFast,
            title: "Apple (MTL)",
            subtitle: "Traditional machine translation engine — may need to download a language pack on first use"
        )
    }

    private var appleIntelligenceOption: Option {
        Option(
            engine: .appleHighFidelity,
            title: "Apple Intelligence",
            subtitle: "On-device Apple Intelligence model — different phrasing than the traditional engine"
        )
    }

    private func externalOption(for provider: TranslationProvider) -> Option? {
        guard let engine = RetranslateEngine(provider: provider) else { return nil }
        return Option(
            engine: engine,
            title: provider.displayName,
            subtitle: "External — retranslates the sentence over the internet"
        )
    }
}

/// Checkbox toggle style in the settings palette: an accent-filled box with
/// a white checkmark when on, a card-fill box with a hairline stroke when
/// off. The whole row is the hit target.
private struct AccentCheckboxStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 8) {
                box(checked: configuration.isOn)
                configuration.label
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func box(checked: Bool) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(checked ? Palette.accent : Palette.cardFill)
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .stroke(checked ? Palette.accent : Palette.cardStroke)
            if checked {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 15, height: 15)
    }
}
