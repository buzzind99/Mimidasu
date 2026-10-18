import SwiftUI

// The language surfaces of archive mode, kept in one cluster: the capsule
// chip shared by the banner and the archive rows, the row's `+` pill, the
// switch-language popover with its in-popover add chooser, and the provider
// picker behind the banner's Translate button.

/// One language's count chip (`FR 40/183`): the badge code in the plain
/// secondary font, the counts in a monospaced emphasis. A value view with no
/// model, shared by the banner (interactive, with the trailing chevron) and
/// the archive rows (display-only).
struct ArchiveLanguageChip: View {
    let count: ArchiveLanguageCount
    /// The session's sentence count — the chip's denominator.
    let total: Int
    /// A bulk job is translating this language right now: accent tint and the
    /// "· translating…" suffix.
    var busy = false
    /// The viewed language: accent tint (the switch popover's current row).
    var selected = false
    /// Trailing chevron for the interactive form (the banner's chip
    /// advertises its popover); rows keep the plain capsule.
    var showsChevron = false

    /// The accent both label runs take while busy or selected; nil keeps the
    /// default secondary/primary pair.
    private var tint: Color? {
        busy || selected ? Theme.accentPink : nil
    }

    var body: some View {
        HStack(spacing: 5) {
            Text(count.badgeCode)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tint ?? Theme.secondaryText)
            Text("\(count.translated)/\(total)")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(tint ?? Theme.primaryText)
            if busy {
                Text("· translating…")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.accentPink)
            }
            if showsChevron {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Theme.secondaryText)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 3)
        .background(
            Capsule()
                .fill(busy || selected ? Theme.accentPink.opacity(0.12) : Theme.tileFill)
                .overlay(
                    Capsule().stroke(selected ? Theme.accentPink.opacity(0.45) : .clear)
                )
        )
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        busy ? "\(count.chipText(of: total)), translating" : count.chipText(of: total)
    }
}

/// The small dashed-accent `+` pill at the end of a row's chip line: opens
/// the add-language chooser for that session.
struct ArchiveAddLanguagePill: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: 9, weight: .heavy))
                .foregroundStyle(Theme.accentPink)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .stroke(
                            Theme.accentPink.opacity(0.55),
                            style: StrokeStyle(lineWidth: 1, dash: [3, 3])
                        )
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .hoverHighlight(Capsule(), tint: Theme.accentPink, opacity: 0.12)
        .help("Add a language")
        .accessibilityLabel("Add a language")
    }
}

/// The switch-language popover of one stored session: one row per language
/// the archive holds (the stored target first), the viewed one checkmarked,
/// and an "Add language…" row that swaps the popover to the chooser of
/// targets not yet held. The chooser can also be the initial screen — the
/// archive row's `+` pill opens it directly.
struct ArchiveSwitchLanguagePopover: View {
    var model: AppModel
    let summary: ArchivedSessionSummary
    let viewingCode: String?
    let onSelect: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var showingChooser: Bool

    init(
        model: AppModel,
        summary: ArchivedSessionSummary,
        viewingCode: String?,
        onSelect: @escaping (String) -> Void,
        initiallyShowingChooser: Bool = false
    ) {
        self.model = model
        self.summary = summary
        self.viewingCode = viewingCode
        self.onSelect = onSelect
        _showingChooser = State(initialValue: initiallyShowingChooser)
    }

    var body: some View {
        Group {
            if showingChooser {
                chooser
            } else {
                languageList
            }
        }
        .padding(10)
        .frame(width: 260)
    }

    // MARK: - Language list

    private var languageList: some View {
        VStack(alignment: .leading, spacing: 2) {
            header(
                "Languages",
                subtitle: "\(summary.displayTitle) · \(summary.sentenceCountText)"
            )
            ForEach(summary.langs) { count in
                languageRow(count)
            }
            addLanguageRow
        }
    }

    private func languageRow(_ count: ArchiveLanguageCount) -> some View {
        let isViewing = count.lang == viewingCode
        return Button {
            onSelect(count.lang)
        } label: {
            HStack(spacing: 8) {
                Text(TargetLanguage(code: count.lang).nativeName)
                    .font(.system(size: 12.5, weight: isViewing ? .semibold : .regular))
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(count.chipText(of: summary.sentenceCount))
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.secondaryText)
                    .monospacedDigit()
                if isViewing {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.accentPink)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isViewing ? Theme.accentPink.opacity(0.08) : .clear)
        )
        .hoverHighlight(
            RoundedRectangle(cornerRadius: 8, style: .continuous),
            tint: Theme.accentPink, opacity: 0.08
        )
        .accessibilityAddTraits(isViewing ? [.isSelected] : [])
    }

    private var addLanguageRow: some View {
        Button {
            showingChooser = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.accentPink)
                    .frame(width: 14, height: 14)
                    .background(Circle().fill(Theme.accentPink.opacity(0.15)))
                Text("Add language…")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.accentPink)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverHighlight(
            RoundedRectangle(cornerRadius: 8, style: .continuous),
            tint: Theme.accentPink, opacity: 0.08
        )
    }

    // MARK: - Add-language chooser

    private var chooser: some View {
        VStack(alignment: .leading, spacing: 2) {
            header("Add language", subtitle: "Target languages not yet in this archive")
            chooserRows
        }
        .task { await model.appleTranslationAvailability.refreshIfNeeded() }
    }

    /// Targets the session doesn't hold yet. Membership is the filter —
    /// an already-added language never appears here, translated or not.
    /// The OS catalog lands asynchronously, so the probe's pending state
    /// gets its own row instead of reading as "none available".
    @ViewBuilder
    private var chooserRows: some View {
        let held = Set(summary.langs.map(\.lang))
        let available = model.appleTranslationAvailability.targets.filter { target in
            !held.contains(target.code)
        }
        if !model.appleTranslationAvailability.isLoaded {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.mini)
                Text("Loading languages…")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 8)
        } else if available.isEmpty {
            Text("No other languages available")
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondaryText)
                .padding(.horizontal, 9)
                .padding(.vertical, 8)
        } else {
            ForEach(available) { target in
                chooserRow(target)
            }
        }
    }

    private func chooserRow(_ target: TargetLanguage) -> some View {
        Button {
            // Membership persists from this moment; when this session is the
            // opened one the add also selects the language for viewing (the
            // model's call). The chooser closes only on a landed write — a
            // failed one keeps it open for another pick.
            if model.addArchiveLanguage(id: summary.id, lang: target.code) {
                dismiss()
            }
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(target.nativeName)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Theme.primaryText)
                        .lineLimit(1)
                    // The grey English name beside the native one
                    // ("Deutsch German"); hidden when the two coincide.
                    if target.nativeName != target.englishName {
                        Text(target.englishName)
                            .font(.system(size: 10.5))
                            .foregroundStyle(Theme.secondaryText)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverHighlight(
            RoundedRectangle(cornerRadius: 8, style: .continuous),
            tint: Theme.accentPink, opacity: 0.08
        )
        .accessibilityLabel(
            target.nativeName == target.englishName
                ? target.nativeName
                : "\(target.nativeName) \(target.englishName)"
        )
    }

    // MARK: - Shared pieces

    private func header(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Theme.primaryText)
            Text(subtitle)
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .padding(.bottom, 5)
    }
}

/// The provider picker behind the banner's Translate button, for the viewed
/// language: Apple on-device plus every external provider (configured ones
/// selectable), a count line, and the start action — fill-missing
/// ("Translate N") or a fresh full pass over a complete language
/// ("Retranslate N").
struct ArchiveTranslationProviderPicker: View {
    var model: AppModel
    let lang: String
    let language: TargetLanguage
    let onStart: (TranslationProvider) -> Void
    @Binding var isPresented: Bool

    @State private var provider: TranslationProvider = .apple

    /// The sentences a run would send: missing count, or the full sentence
    /// count when the language is complete.
    private var sendCount: Int {
        model.archiveTranslationSendCount(lang: lang) ?? 0
    }

    private var isComplete: Bool {
        model.archiveLanguageIsComplete(lang)
    }

    private var jobIsActive: Bool {
        model.archiveTranslationJob.isActive
    }

    /// The start action is held back while a run is claimed (one job at a
    /// time) and while the shared disclosure slot holds an intent — a pick
    /// then would be refused, so the button must not look live.
    private var actionDisabled: Bool {
        jobIsActive || model.providerAwaitingDisclosure != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.primaryText)
                Text(isComplete
                    ? "Pick a provider, then press Retranslate"
                    : "Pick a provider, then press Translate")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.secondaryText)
            }
            VStack(spacing: 2) {
                ForEach(TranslationProvider.allCases) { option in
                    providerRow(option)
                }
            }
            Rectangle()
                .fill(Theme.divider)
                .frame(height: 1)
            Text(countLine)
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.secondaryText)
                .monospacedDigit()
            actionButton
        }
        .padding(12)
        .frame(width: 300)
        // A run that reaches its engine is what closes the picker: the
        // Apple path starts immediately, the external one after the cloud
        // disclosure is confirmed.
        .onChange(of: model.archiveTranslationJob.isRunning) { _, isRunning in
            if isRunning {
                isPresented = false
            }
        }
    }

    private var title: String {
        isComplete
            ? "\(language.nativeName) — all translated"
            : "\(language.nativeName) — \(sendCount) untranslated"
    }

    private var countLine: String {
        isComplete
            ? "All \(sendCount) sentences translated"
            : "\(sendCount) untranslated sentences"
    }

    private var actionLabel: String {
        isComplete ? "Retranslate \(sendCount)" : "Translate \(sendCount)"
    }

    // MARK: - Provider rows

    private func providerRow(_ option: TranslationProvider) -> some View {
        let configured = option == .apple || model.translationSettings.hasKey(for: option)
        let isSelected = provider == option
        return Button {
            guard configured else { return }
            provider = option
        } label: {
            HStack(spacing: 9) {
                radio(selected: isSelected)
                Text(option == .apple ? "Apple" : option.displayName)
                    .font(.system(size: 12.5, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(Theme.primaryText)
                Spacer(minLength: 8)
                Text(tailText(option, configured: configured))
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.secondaryText)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!configured)
        .opacity(configured ? 1 : 0.45)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(isSelected ? Theme.accentPink.opacity(0.08) : .clear)
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(isSelected ? Theme.accentPink.opacity(0.4) : .clear)
                )
        )
        .hoverHighlight(
            RoundedRectangle(cornerRadius: 9, style: .continuous),
            isEnabled: configured && !isSelected,
            tint: Theme.accentPink, opacity: 0.08
        )
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private func tailText(_ option: TranslationProvider, configured: Bool) -> String {
        if option == .apple {
            return "On-device"
        }
        return configured ? "Configured" : "Not configured"
    }

    private func radio(selected: Bool) -> some View {
        ZStack {
            Circle()
                .stroke(
                    selected ? Theme.accentPink : Theme.secondaryText.opacity(0.6),
                    lineWidth: 1.5
                )
            if selected {
                Circle()
                    .fill(Theme.accentPink)
                    .padding(4)
            }
        }
        .frame(width: 14, height: 14)
    }

    // MARK: - Action

    private var actionButton: some View {
        Button {
            onStart(provider)
        } label: {
            Text(actionLabel)
                .font(.system(size: 11.5, weight: .bold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Theme.accentPink)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(actionDisabled)
        .opacity(actionDisabled ? 0.45 : 1)
        .hoverHighlight(
            RoundedRectangle(cornerRadius: 8, style: .continuous),
            isEnabled: !actionDisabled,
            tint: .white, opacity: 0.15
        )
        .accessibilityLabel(actionLabel)
    }
}
