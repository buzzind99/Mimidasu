import SwiftUI

/// TARGET LANGUAGE settings card: a two-column grid of language cards comes
/// from the runtime-discovered Apple catalog (`LanguageAvailability` probed by
/// `AppleTranslationAvailability`). The selection is restart-only — the
/// control is disabled while a session is live and a new target applies at
/// the next session start — and the footer explains the OS-dependent set.
struct SettingsTargetLanguageCard: View {
    @Bindable private var model: AppModel
    @Bindable private var settings: TranslationSettings
    /// A non-English pick held until the English-only dictionary notice is
    /// acknowledged; "Understood" completes the selection.
    @State private var awaitingNotice: TargetLanguage?
    /// Fixed card height so the scroll viewport can stop exactly on a card
    /// boundary instead of cutting a partial row.
    private static let cardHeight: CGFloat = 58
    /// Gap between cards, both between the two columns and between rows.
    private static let cardSpacing: CGFloat = 6
    /// Full card rows shown before the rest scrolls; the rest of the
    /// OS-dependent catalog scrolls inside the card.
    private static let visibleRowCount = 4

    /// Exact scroll-viewport height: `min(rows, visibleRowCount)` card rows
    /// plus the gaps between them, so no partial row is ever visible.
    private static func viewportHeight(cardCount: Int) -> CGFloat {
        let rows = (cardCount + 1) / 2
        let visible = min(rows, visibleRowCount)
        return CGFloat(visible) * cardHeight
            + CGFloat(max(visible - 1, 0)) * cardSpacing
    }

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
                if model.appleTranslationAvailability.targets.isEmpty {
                    // The probe can legally yield nothing usable; say so
                    // instead of mounting a 0-height viewport.
                    Text("No compatible target languages found")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.mutedText)
                } else {
                    ScrollView(.vertical) {
                        LazyVGrid(
                            columns: [
                                GridItem(.flexible(), spacing: Self.cardSpacing),
                                GridItem(.flexible())
                            ],
                            spacing: Self.cardSpacing
                        ) {
                            ForEach(model.appleTranslationAvailability.targets) { target in
                                card(target)
                            }
                        }
                    }
                    .frame(height: Self.viewportHeight(
                        cardCount: model.appleTranslationAvailability.targets.count
                    ))
                    // Inert while a session is live: wheel events over the
                    // list scroll the enclosing settings window instead.
                    .scrollDisabled(sessionIsLive)
                    .opacity(sessionIsLive ? 0.45 : 1)
                }
            } else {
                LanguagesLoadingRow(tint: Palette.mutedText)
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
        SessionPhaseMachine.isLiveOrStopping(model.phase)
    }

    private var languagesCountLabel: String {
        let count = model.appleTranslationAvailability.targets.count
        return count == 1 ? "1 language" : "\(count) languages"
    }

    private func card(_ target: TargetLanguage) -> some View {
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
            cardLabel(target, selected: selected)
        }
        .buttonStyle(.plain)
        .disabled(sessionIsLive)
        .hoverHighlight(
            RoundedRectangle(cornerRadius: 9, style: .continuous),
            isEnabled: !selected,
            tint: Palette.primaryText, opacity: 0.05
        )
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private func cardLabel(_ target: TargetLanguage, selected: Bool) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            cardHeader(target, selected: selected)
            Text(target.nativeName)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Palette.primaryText)
                .lineLimit(1)
                .truncationMode(.tail)
            // The international name sits under the endonym; English has
            // no second name, so it explains its role in the catalog.
            Text(
                target.nativeName == target.englishName
                    ? "Default target" : target.englishName
            )
            .font(.system(size: 10))
            .foregroundStyle(Palette.mutedText)
            .lineLimit(1)
            .truncationMode(.tail)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: Self.cardHeight)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(selected ? Palette.accent.opacity(0.12) : Color.clear)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(selected ? Palette.accent : Palette.divider)
        }
        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private func cardHeader(_ target: TargetLanguage, selected: Bool) -> some View {
        HStack(spacing: 6) {
            Text(LanguageBadge.code(for: target.code))
                .font(.system(size: 8.5, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(selected ? Palette.accent : Palette.secondaryText)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(
                            selected
                                ? Palette.accent.opacity(0.14)
                                : Palette.pillFill
                        )
                )
            Spacer(minLength: 4)
            if selected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.accent)
            }
        }
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
                    + "they aren't translated to the selected target language. "
                    + "Only the transcribed text itself is translated."
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
