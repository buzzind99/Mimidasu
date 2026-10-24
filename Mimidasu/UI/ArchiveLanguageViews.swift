import SwiftUI

// The language surfaces of archive mode, kept in one cluster: the capsule
// chip the archive rows show, the row's `+` pill, the switch-language
// popover with its in-popover add chooser, the engine picker behind the
// banner's toolbar and each row language chip, and the loading row the
// Settings target-language card shares.

/// One language's count chip (`FR 40/183`) with a completeness meter under
/// the counts: the badge code in the plain secondary font, the counts in a
/// monospaced emphasis. The archive window renders the chip at its default
/// text scale; the flow layout caches its measurements by content fingerprint.
struct ArchiveLanguageChip: View {
    let count: ArchiveLanguageCount
    /// The session's sentence count — the chip's denominator.
    let total: Int
    /// A bulk job is translating this language right now: accent tint and the
    /// "· translating…" suffix.
    var busy = false
    /// The viewed language: accent tint and a capsule outline.
    var selected = false

    /// The accent both label runs take while busy or selected; nil keeps the
    /// default secondary/primary pair.
    private var tint: Color? {
        busy || selected ? Theme.accentPink : nil
    }

    /// The translated fraction the meter fills, clamped to the capsule.
    private var progress: Double {
        guard total > 0 else { return 0 }
        return min(max(Double(count.translated) / Double(total), 0), 1)
    }

    var body: some View {
        HStack(spacing: 5) {
            Text(count.badgeCode)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tint ?? Theme.secondaryText)
                .lineLimit(1)
                .fixedSize()
            Text("\(count.translated)/\(total)")
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(tint ?? Theme.primaryText)
                .lineLimit(1)
                .fixedSize()
            if busy {
                Text("· translating…")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.accentPink)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 9)
        .padding(.top, 3)
        .padding(.bottom, 5)
        .background {
            GeometryReader { proxy in
                ZStack(alignment: .bottomLeading) {
                    Capsule()
                        .fill(busy || selected ? Theme.accentPink.opacity(0.12) : Theme.tileFill)
                    Rectangle()
                        .fill(tint ?? Theme.meterTeal)
                        .frame(width: proxy.size.width * progress, height: 2)
                }
                .clipShape(Capsule())
                .overlay(
                    Capsule().stroke(selected ? Theme.accentPink.opacity(0.45) : .clear)
                )
            }
        }
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        count.accessibilityText(of: total, busy: busy)
    }
}

/// The "Loading languages…" row the language surfaces show while the OS
/// catalog is still being probed: a mini spinner beside the label. The
/// surfaces grey the label differently — the Settings card's muted token,
/// the archive popover's secondary — so the caller passes the colour in.
struct LanguagesLoadingRow: View {
    /// The label's colour.
    var tint: Color

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.mini)
            Text("Loading languages…")
                .font(.system(size: 11))
                .foregroundStyle(tint)
        }
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
        .pointerStyle(.link)
        .help("Add a language")
        .accessibilityLabel("Add a language")
    }
}

/// The switch-language popover of one stored session: one row per language
/// the archive holds (the stored target first), the viewed one checkmarked,
/// and an "Add language…" row that swaps the popover to the chooser of
/// targets not yet held. The add row drops out once the session holds every
/// language the app can target. The chooser can also be the initial screen —
/// the archive row's `+` pill opens it directly.
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
            // The add path disappears once the session holds every language
            // the app can target.
            if !summary.holdsEveryTargetLanguage {
                addLanguageRow
            }
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
            LanguagesLoadingRow(tint: Theme.secondaryText)
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

/// The engine picker behind the banner's Translate button and each archive
/// row's language chip, for one stored session and language: the two on-device
/// Apple tiers — Apple Intelligence offered and defaulted to whenever the OS
/// can serve the pair, Apple (NMT) otherwise — plus every external provider
/// (configured ones selectable), a count line, and the start action —
/// fill-missing ("Translate N") or a fresh full pass over a complete language
/// ("Retranslate N").
struct ArchiveTranslationEnginePicker: View {
    var model: AppModel
    let summary: ArchivedSessionSummary
    let lang: String
    let onStart: (RetranslateEngine) -> Void
    @Binding var isPresented: Bool

    /// The user's pick; nil until they choose — the offered default applies.
    @State private var selection: RetranslateEngine?

    private var language: TargetLanguage {
        TargetLanguage(code: lang)
    }

    /// Whether the OS can serve the high-fidelity tier for this language.
    private var hifiOffered: Bool {
        model.archiveHighFidelityOffered(for: lang)
    }

    private var defaultEngine: RetranslateEngine {
        hifiOffered ? .appleHighFidelity : .appleFast
    }

    private var selectedEngine: RetranslateEngine {
        selection ?? defaultEngine
    }

    /// High fidelity first (the preferred tier), then NMT, then the
    /// externals in picker order.
    private var engineOptions: [RetranslateEngine] {
        var engines: [RetranslateEngine] = []
        if hifiOffered {
            engines.append(.appleHighFidelity)
        }
        engines.append(.appleFast)
        engines.append(
            contentsOf: TranslationProvider.allCases
                .filter { provider in provider.isExternal }
                .compactMap { provider in RetranslateEngine(provider: provider) }
        )
        return engines
    }

    /// The sentences a run would send: missing count, or the full sentence
    /// count when the language is complete.
    private var sendCount: Int {
        model.archiveTranslationSendCount(summary: summary, lang: lang)
    }

    private var isComplete: Bool {
        model.archiveLanguageIsComplete(summary: summary, lang: lang)
    }

    private var jobIsActive: Bool {
        model.archiveTranslationJob.activity != .idle
    }

    /// The start action is held back while a run is claimed (one job at a
    /// time), while the shared disclosure slot holds an intent, and while a
    /// live session blocks archive starts — a pick then would be refused, so
    /// the button must not look live.
    private var actionDisabled: Bool {
        jobIsActive || model.providerAwaitingDisclosure != nil
            || !model.canOpenArchivedSession
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.primaryText)
                Text("Pick a translation provider")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.secondaryText)
            }
            // The engine list grows with the provider catalog; cap it so the
            // picker never runs off the screen.
            ScrollView(.vertical) {
                VStack(spacing: 2) {
                    ForEach(engineOptions, id: \.rawValue) { engine in
                        engineRow(engine)
                    }
                }
            }
            .frame(maxHeight: 360)
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
        // A run that reaches its engine is what closes the picker: an Apple
        // tier starts immediately, an external one after the cloud
        // disclosure is confirmed.
        .onChange(of: model.archiveTranslationJob.activity.isRunning) { _, isRunning in
            if isRunning {
                isPresented = false
            }
        }
        // Every dismissal clears the pick: reopening always shows the
        // offered default instead of the previous run's engine.
        .onDisappear { selection = nil }
    }

    private var title: String {
        isComplete
            ? "\(language.nativeName) — all translated"
            : "\(language.nativeName) — \(sendCount) untranslated"
    }

    private var countLine: String {
        isComplete
            ? "All \(ArchivedSessionSummary.sentenceCountText(sendCount)) translated"
            : "\(ArchivedSessionSummary.sentenceCountText(sendCount)) untranslated"
    }

    private var actionLabel: String {
        isComplete ? "Retranslate \(sendCount)" : "Translate \(sendCount)"
    }

    // MARK: - Engine rows

    private func engineRow(_ engine: RetranslateEngine) -> some View {
        let configured = isConfigured(engine)
        let isSelected = selectedEngine == engine
        return Button {
            guard configured else { return }
            selection = engine
        } label: {
            HStack(spacing: 9) {
                radio(selected: isSelected)
                Text(engine.displayName)
                    .font(.system(size: 12.5, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(Theme.primaryText)
                Spacer(minLength: 8)
                Text(tailText(engine, configured: configured))
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

    /// On-device tiers need no key; an external row is usable only while its
    /// provider has a stored key.
    private func isConfigured(_ engine: RetranslateEngine) -> Bool {
        guard let provider = engine.provider else { return true }
        return model.translationSettings.hasKey(for: provider)
    }

    private func tailText(_ engine: RetranslateEngine, configured: Bool) -> String {
        guard engine.provider != nil else { return "On-device" }
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
            onStart(selectedEngine)
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
        .pointerStyle(actionDisabled ? nil : .link)
        .accessibilityLabel(actionLabel)
    }
}
