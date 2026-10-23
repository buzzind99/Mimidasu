import Foundation
import SwiftUI

/// One stored-session row in the archive window: the date rail, the title
/// (user name or first-sentence quote), the excerpt under a renamed title,
/// the time/duration/sentence meta line, the language chips, and the action
/// cluster.
struct ArchiveSessionRow: View {
    var model: AppModel
    let summary: ArchivedSessionSummary
    let canOpen: Bool
    /// The bulk job claims this session (the chip line's busy state, from
    /// the claim onward); the progress bar renders once the run starts.
    /// `jobLang` names the language it walks.
    let isJobRunning: Bool
    let jobLang: String?
    /// The run's `(processed, total)`, for the progress bar.
    let jobProgress: (Int, Int)?
    /// The add-language chooser's presentation, anchored on the `+` pill.
    @Binding var chooserPresented: Bool
    /// The translate picker's presentation for one row language, anchored on
    /// its chip.
    let translationPickerPresented: (String) -> Binding<Bool>
    let onOpen: () -> Void
    let onDelete: () -> Void
    let onRename: () -> Void
    let onSave: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            dateRail
            VStack(alignment: .leading, spacing: 3) {
                titleLine
                if let excerpt = summary.rowExcerpt {
                    Text(excerpt)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Text(summary.rowMetaLine)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.secondaryText)
                    .padding(.top, 1)
                chipLine
                if let jobProgress {
                    ProgressView(
                        value: Double(jobProgress.0),
                        total: Double(max(jobProgress.1, 1))
                    )
                    .progressViewStyle(.linear)
                    .tint(Theme.accentPink)
                    .frame(width: 150)
                    .padding(.top, 3)
                }
            }
            actionColumn
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 12)
        .cardSurface(radius: 12)
        .onDisappear {
            if chooserPresented {
                chooserPresented = false
            }
            for count in summary.langs {
                translationPickerPresented(count.lang).wrappedValue = false
            }
        }
    }

    // MARK: - Title and date

    private var dateRail: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(dateKicker)
                .font(.system(size: 8.5, weight: .heavy))
                .tracking(0.8)
                .foregroundStyle(isToday ? Theme.accentPink : Theme.secondaryText)
                .lineLimit(1)
            Text(dayText)
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(isToday ? Theme.accentPink : Theme.primaryText)
                .monospacedDigit()
        }
        .frame(width: 56, alignment: .leading)
        .padding(.top, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(dateAccessibilityText)
    }

    private var isToday: Bool {
        Calendar.current.isDateInToday(summary.startedAt)
    }

    private var dateAccessibilityText: String {
        if isToday {
            return "Today"
        }
        return summary.startedAt.formatted(.dateTime.month(.wide).day().year())
    }

    private var dateKicker: String {
        summary.rowDateLabel
    }

    private var dayText: String {
        String(Calendar.current.component(.day, from: summary.startedAt))
    }

    private var titleLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(summary.rowTitle)
                .font(.system(size: summary.hasUserName ? 18.5 : 17.5, weight: .semibold))
                .foregroundStyle(Theme.primaryText)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .layoutPriority(1)
            if summary.status == .interrupted {
                interruptedBadge
            }
            Spacer(minLength: 0)
        }
    }

    private var interruptedBadge: some View {
        Text("INTERRUPTED")
            .font(.system(size: 8.5, weight: .heavy))
            .tracking(0.6)
            .foregroundStyle(Theme.dotYellow)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Capsule().fill(Theme.dotYellow.opacity(0.12)))
            .fixedSize(horizontal: true, vertical: false)
    }

    // MARK: - Actions

    private var actionColumn: some View {
        VStack(alignment: .trailing, spacing: 8) {
            actionButtons
            Button(action: onOpen) {
                Text("Open")
                    .font(.system(size: 11.5, weight: .bold))
                    .foregroundStyle(Theme.accentPink)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Theme.accentPink.opacity(0.12))
                    )
            }
            .buttonStyle(.plain)
            .disabled(!canOpen)
            .opacity(canOpen ? 1 : 0.45)
            .help(canOpen ? "Open this transcript" : "Stop the session to open transcripts")
            .onHover { _ in }
            .pointerStyle(canOpen ? .link : nil)
        }
    }

    /// The Delete/Rename/Save cluster. Delete is refused while this session's
    /// run is walking it: no click, no link cursor, and the help says why.
    private var actionButtons: some View {
        HStack(spacing: 6) {
            actionButton(
                "trash",
                help: isJobRunning
                    ? "Can't delete while this session is translating"
                    : "Delete",
                isEnabled: !isJobRunning,
                showsLink: !isJobRunning,
                action: onDelete
            )
            actionButton("square.and.pencil", help: "Rename", action: onRename)
            if !summary.saved {
                ArchiveActionButton(help: ArchiveSaveGlyph.saveHelp, action: onSave) {
                    ArchiveSaveGlyph(size: 12)
                }
            }
        }
    }

    private func actionButton(
        _ systemImage: String,
        help: String,
        isEnabled: Bool = true,
        showsLink: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        ArchiveActionButton(
            help: help,
            isEnabled: isEnabled,
            showsLink: showsLink,
            action: action
        ) {
            Image(systemName: systemImage)
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
        }
    }

    // MARK: - Language chips

    /// The row's language chips, each a button opening the translate picker
    /// for its language, with the `+` pill that opens the add-language
    /// chooser for this session. The chips flow: a long language list wraps
    /// to a second row instead of squeezing the pills. The `+` pill drops
    /// out once the session holds every language the app can target.
    private var chipLine: some View {
        FlowLayout(spacing: 6, lineSpacing: 4, fingerprint: chipFingerprint) {
            ForEach(summary.langs) { count in
                languageChipButton(count)
            }
            if !summary.holdsEveryTargetLanguage {
                ArchiveAddLanguagePill {
                    chooserPresented = true
                }
                .popover(isPresented: $chooserPresented, arrowEdge: .bottom) {
                    ArchiveSwitchLanguagePopover(
                        model: model,
                        summary: summary,
                        viewingCode: model.openArchive?.id == summary.id
                            ? model.archiveViewingCode : nil,
                        onSelect: { lang in
                            // Never mutates another archive's viewing
                            // language: a row picker only serves its own
                            // (opened) session.
                            guard model.openArchive?.id == summary.id else { return }
                            model.selectArchiveViewingLanguage(lang)
                        },
                        initiallyShowingChooser: true
                    )
                }
            }
        }
        .padding(.top, 4)
    }

    /// The flow layout's cache key: the chips' content and state. Counts
    /// change as translations land and the busy/selected flags change the
    /// chip's own width, so both ride the fingerprint.
    private var chipFingerprint: String {
        var parts = ["total:\(summary.sentenceCount)"]
        for count in summary.langs {
            let busy = isJobRunning && count.lang == jobLang
            let selected = model.openArchive?.id == summary.id
                && count.lang == model.archiveViewingCode
            parts.append("\(count.lang):\(count.translated):\(busy ? 1 : 0):\(selected ? 1 : 0)")
        }
        return parts.joined(separator: "|")
    }

    /// One language chip as a button: opens the translate/re-translate
    /// picker for this session and language. No chevron — the hover
    /// highlight and link cursor advertise the click.
    private func languageChipButton(_ count: ArchiveLanguageCount) -> some View {
        let isPresented = translationPickerPresented(count.lang)
        return Button {
            isPresented.wrappedValue = true
        } label: {
            ArchiveLanguageChip(
                count: count,
                total: summary.sentenceCount,
                busy: isJobRunning && count.lang == jobLang,
                selected: model.openArchive?.id == summary.id
                    && count.lang == model.archiveViewingCode
            )
        }
        .buttonStyle(.plain)
        .hoverHighlight(Capsule())
        .pointerStyle(.link)
        .help("Translate or re-translate this language")
        .popover(isPresented: isPresented, arrowEdge: .bottom) {
            ArchiveTranslationEnginePicker(
                model: model,
                summary: summary,
                lang: count.lang,
                onStart: { engine in
                    model.requestArchiveTranslation(
                        engine: engine, lang: count.lang, sessionID: summary.id,
                        presenter: .archiveWindow
                    )
                },
                isPresented: isPresented
            )
        }
    }
}

/// The carded icon button behind the archive row's action cluster: the
/// delete, rename and save controls, each an icon in its own small card.
private struct ArchiveActionButton<Label: View>: View {
    let help: String
    var isEnabled = true
    var showsLink = true
    let action: () -> Void
    @ViewBuilder var label: () -> Label

    var body: some View {
        Button(action: action) {
            label()
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Theme.cardFill)
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .stroke(Theme.cardStroke)
                        )
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
        .hoverHighlight(
            RoundedRectangle(cornerRadius: 7, style: .continuous),
            isEnabled: isEnabled
        )
        .pointerStyle(showsLink ? .link : nil)
        .help(help)
        .accessibilityLabel(help)
    }
}
