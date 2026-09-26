import SwiftUI

/// TARGET LANGUAGE settings card: rows come from the runtime-discovered
/// Apple catalog (`LanguageAvailability` probed by
/// `AppleTranslationAvailability`), the selection is restart-only — the
/// control is disabled while a session is live and a new target applies at
/// the next session start — and the footer explains the OS-dependent set.
struct SettingsTargetLanguageCard: View {
    @Bindable private var model: AppModel
    @Bindable private var settings: TranslationSettings
    /// A non-English pick held until the English-only dictionary notice is
    /// acknowledged; "Understood" completes the selection.
    @State private var awaitingNotice: TargetLanguage?
    /// Horizontal inset shared by the row bands and the dividers so every
    /// band edge and line end aligns.
    private static let bandInset: CGFloat = 14

    init(model: AppModel, settings: TranslationSettings) {
        _model = Bindable(wrappedValue: model)
        _settings = Bindable(wrappedValue: settings)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                KickerLabel("TARGET LANGUAGE", color: Palette.label)
                Spacer()
                if model.appleTranslationAvailability.isLoaded {
                    Text(languagesCountLabel)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Palette.mutedText)
                }
            }
            if model.appleTranslationAvailability.isLoaded {
                // ~5 rows in view; the rest of the OS-dependent catalog
                // scrolls inside the card.
                ScrollView(.vertical) {
                    VStack(spacing: 0) {
                        let targets = model.appleTranslationAvailability.targets
                        ForEach(targets) { target in
                            row(target)
                            if target != targets.last {
                                settingsDivider().padding(.horizontal, Self.bandInset)
                            }
                        }
                    }
                }
                .frame(maxHeight: 200)
                .opacity(sessionIsLive ? 0.45 : 1)
            } else {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Loading languages…")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.mutedText)
                }
            }
            Text(
                "On-device languages depend on your macOS version; selecting one may "
                    + "download a language pack on first use."
            )
            .font(.system(size: 10.5))
            .foregroundStyle(Palette.mutedText)
        }
        .padding(16)
        .cardSurface(shadow: Palette.cardShadow)
        .task { await model.appleTranslationAvailability.refreshIfNeeded() }
        .sheet(item: $awaitingNotice) { target in
            DictionaryEnglishNoticeSheet {
                awaitingNotice = nil
                settings.select(target)
            }
        }
    }

    /// True in the phases where a session is live (or on its way in/out):
    /// the target-language control is disabled there — restart-only by
    /// design, the new target applies at the next session start.
    private var sessionIsLive: Bool {
        switch model.phase {
        case .running, .starting, .stopping, .sourceLost: true
        case .needsModel, .idle, .failed: false
        }
    }

    private var languagesCountLabel: String {
        let count = model.appleTranslationAvailability.targets.count
        return count == 1 ? "1 language" : "\(count) languages"
    }

    private func row(_ target: TargetLanguage) -> some View {
        let selected = settings.targetLanguage == target
        return Button {
            guard !selected else { return }
            // English needs no notice; a non-English pick is held for the
            // dictionary acknowledgment first.
            if target == .english {
                settings.select(target)
            } else {
                awaitingNotice = target
            }
        } label: {
            HStack(spacing: 10) {
                Text(target.nativeName)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Palette.primaryText)
                    .lineLimit(1)
                // English/international name in grey beside the native
                // name ("Deutsch German"); hidden when the two coincide.
                if target.nativeName != target.englishName {
                    Text(target.englishName)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.secondaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: 12)
                Text(Self.badgeCode(for: target))
                    .font(.system(size: 9.5, weight: .bold))
                    .tracking(0.5)
                    .foregroundStyle(selected ? Palette.accent : Palette.secondaryText)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(selected ? Palette.accent.opacity(0.14) : Palette.pillFill)
                    )
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(Palette.accent)
                }
            }
            .padding(.horizontal, Self.bandInset + 12)
            .padding(.vertical, 9)
            .background {
                if selected {
                    RowBand(inset: Self.bandInset)
                        .fill(Palette.accent.opacity(0.12))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(sessionIsLive)
        .hoverHighlight(
            RowBand(inset: Self.bandInset),
            isEnabled: !selected,
            tint: Palette.primaryText, opacity: 0.05
        )
    }

    /// Uppercase primary subtag for the row badge ("en" → "EN",
    /// "zh-Hans" → "ZH").
    private static func badgeCode(for target: TargetLanguage) -> String {
        guard let primary = target.code.split(separator: "-").first else {
            return target.code.uppercased()
        }
        return primary.uppercased()
    }
}

/// Square-cornered band behind a picker row (hover and selected): inset from
/// the row's edges so it stops exactly at the divider lines.
private struct RowBand: Shape {
    var inset: CGFloat

    func path(in rect: CGRect) -> Path {
        Path(CGRect(
            x: rect.minX + inset,
            y: rect.minY,
            width: rect.width - inset * 2,
            height: rect.height
        ))
    }
}

/// Acknowledgment raised when a non-English translation target is picked:
/// the built-in dictionary explains words in English only, whatever the
/// target. "Understood" completes the held selection; like the cloud
/// disclosure there is no persisted acknowledgment — the sheet reappears on
/// each non-English pick.
struct DictionaryEnglishNoticeSheet: View {
    let onUnderstood: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            KickerLabel("DICTIONARY", color: Palette.label)
            Text("Dictionary is English-only")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Palette.primaryText)
            Text(
                "Word lookups in the transcript are explained in English only — "
                    + "they aren't translated to the selected target language."
            )
            .font(.system(size: 12))
            .foregroundStyle(Palette.secondaryText)
            HStack {
                Spacer()
                SettingsPill(label: "Understood", prominent: true) {
                    onUnderstood()
                }
            }
        }
        .padding(24)
        .frame(width: 360)
        .background(Palette.window)
    }
}
