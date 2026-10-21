import SwiftUI

/// The opened archive's banner at the top of the transcript pane: title with
/// the rename button, the meta line (start datetime, duration, sentences,
/// characters), and the trailing cluster — the viewed-language chip (the
/// switch-language popover), the Translate/Retranslate button (the engine
/// picker), and the save icon — an outline bookmark that promotes a Recent, a
/// filled accent bookmark once Saved (display only, no demotion).
struct ArchiveBannerView: View {
    var model: AppModel
    /// The rename question's slot, draft and store value — the same state
    /// the archive window's rows use, so both surfaces apply one rename
    /// rule.
    @State private var renameState = ArchiveWindowState()
    @State private var isLanguagePopoverPresented = false
    @State private var isTranslatePopoverPresented = false

    /// The rename button's help and its VoiceOver label — one string, so
    /// the two cannot drift.
    private static let renameHelp = "Rename this session"

    var body: some View {
        if let archive = model.openArchive {
            banner(archive)
        }
    }

    private func banner(_ archive: ArchivedSession) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(archive.summary.displayTitle)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Theme.primaryText)
                        .lineLimit(1)
                    Button {
                        renameState.requestRename(archive.summary)
                    } label: {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.secondaryText)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .hoverHighlight(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .pointerStyle(.link)
                    .help(Self.renameHelp)
                    .accessibilityLabel(Self.renameHelp)
                }
                Text(archive.metaLine)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText)
                    .monospacedDigit()
            }
            Spacer()
            trailingCluster(archive)
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 13)
        .cardSurface(radius: 12)
        .padding(.horizontal, 26)
        .padding(.top, 20)
        .archiveRenameConfirmation(
            model,
            pendingRename: $renameState.pendingRename,
            draft: $renameState.renameDraft,
            renamedName: { renameState.renameValue }
        )
    }

    /// The trailing cluster, left to right: the viewed-language chip, the
    /// Translate button, the save icon.
    private func trailingCluster(_ archive: ArchivedSession) -> some View {
        HStack(spacing: 10) {
            languageChip(archive)
            translateButton(archive)
            saveButton(archive.summary)
        }
    }

    /// The viewed language's chip, in its interactive form: tapping opens
    /// the switch-language popover. Without a held count entry the chip
    /// degrades to the plain code label.
    @ViewBuilder
    private func languageChip(_ archive: ArchivedSession) -> some View {
        let viewedCode = model.archiveViewingCode
        let viewingCount = viewedCode.flatMap { code in
            archive.summary.languageCount(for: code)
        } ?? archive.summary.langs.first
        let busyLang = viewedCode ?? viewingCount?.lang
        Button {
            isLanguagePopoverPresented = true
        } label: {
            if let viewingCount {
                ArchiveLanguageChip(
                    count: viewingCount,
                    total: archive.summary.sentenceCount,
                    busy: jobIsActive(on: archive, lang: busyLang),
                    showsChevron: true
                )
            } else {
                plainCodeChip(viewedCode)
            }
        }
        .buttonStyle(.plain)
        .hoverHighlight(Capsule())
        .pointerStyle(.link)
        .help("Switch the viewed language")
        .accessibilityLabel(viewedLanguageLabel(
            viewingCount, total: archive.summary.sentenceCount,
            busy: jobIsActive(on: archive, lang: busyLang)
        ))
        .popover(isPresented: $isLanguagePopoverPresented, arrowEdge: .bottom) {
            ArchiveSwitchLanguagePopover(
                model: model,
                summary: archive.summary,
                viewingCode: model.archiveViewingCode,
                onSelect: { lang in
                    model.selectArchiveViewingLanguage(lang)
                    isLanguagePopoverPresented = false
                }
            )
        }
    }

    /// The viewed-language chip's VoiceOver label: the chip's own counts
    /// plus the viewed-language hint the button adds.
    private func viewedLanguageLabel(_ count: ArchiveLanguageCount?, total: Int, busy: Bool) -> String {
        guard let count else { return "Viewed language" }
        return "Viewed language: \(count.accessibilityText(of: total, busy: busy))"
    }

    private func plainCodeChip(_ code: String?) -> some View {
        Text((code ?? "—").uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Theme.secondaryText)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(Capsule().fill(Theme.tileFill))
    }

    /// The Translate/Retranslate button: opens the engine picker for the
    /// viewed language. Held back while a bulk run is claimed (one job at a
    /// time) and without a viewed language to translate.
    private func translateButton(_ archive: ArchivedSession) -> some View {
        let disabled = model.archiveTranslationJob.activity != .idle || model.archiveViewingCode == nil
        let isComplete = viewedLanguageIsComplete(archive)
        let title = isComplete ? "Retranslate" : "Translate"
        return Button {
            isTranslatePopoverPresented = true
        } label: {
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Theme.accentPink)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.45 : 1)
        .hoverHighlight(
            RoundedRectangle(cornerRadius: 8, style: .continuous),
            isEnabled: !disabled,
            tint: .white, opacity: 0.15
        )
        .pointerStyle(disabled ? nil : .link)
        .help(
            isComplete
                ? "Retranslate this archive's viewed language"
                : "Translate this archive's viewed language"
        )
        .accessibilityLabel(
            isComplete ? "Retranslate the viewed language" : "Translate the viewed language"
        )
        .popover(isPresented: $isTranslatePopoverPresented, arrowEdge: .bottom) {
            if let code = model.archiveViewingCode {
                ArchiveTranslationEnginePicker(
                    model: model,
                    summary: archive.summary,
                    lang: code,
                    onStart: { engine in startTranslation(engine, lang: code) },
                    isPresented: $isTranslatePopoverPresented
                )
            }
        }
    }

    /// Whether the viewed language has a translation on every sentence — the
    /// button then reads Retranslate, mirroring the picker's action.
    private func viewedLanguageIsComplete(_ archive: ArchivedSession) -> Bool {
        guard let code = model.archiveViewingCode else { return false }
        return model.archiveLanguageIsComplete(summary: archive.summary, lang: code)
    }

    /// Routes the picker's start through the model: the request is refused
    /// while another cloud-disclosure intent is held, an Apple-tier pick
    /// starts its run directly, and an external pick is parked for the
    /// disclosure whose confirm callback starts the run.
    private func startTranslation(_ engine: RetranslateEngine, lang: String) {
        guard let sessionID = model.openArchive?.id else { return }
        model.requestArchiveTranslation(
            engine: engine, lang: lang, sessionID: sessionID, presenter: .mainWindow
        )
    }

    /// Whether the bulk job claims or runs for this session and language —
    /// from the synchronous claim through the run's end. The scoped activity
    /// carries the request throughout, so a foreign session or an idle slot
    /// reads false.
    private func jobIsActive(on archive: ArchivedSession, lang: String?) -> Bool {
        let activity = model.archiveTranslationJob.activity(for: archive.id)
        guard let request = activity.request else { return false }
        return request.lang == lang
    }

    @ViewBuilder
    private func saveButton(_ summary: ArchivedSessionSummary) -> some View {
        if summary.saved {
            ArchiveSaveGlyph(size: 14, isFilled: true)
                .help(ArchiveSaveGlyph.savedHelp)
                .accessibilityLabel(ArchiveSaveGlyph.savedHelp)
        } else {
            Button {
                model.saveOpenArchive()
            } label: {
                ArchiveSaveGlyph(size: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hoverHighlight(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .pointerStyle(.link)
            .help(ArchiveSaveGlyph.saveHelp)
            .accessibilityLabel(ArchiveSaveGlyph.saveHelp)
        }
    }
}

/// The archive save affordance: the bookmark that promotes a stored session
/// to the permanent tier. The opened banner shows it bare — filled in the
/// accent colour once the session is saved — and the archive window's row
/// shows it in the action cluster's card; the wording is one copy.
struct ArchiveSaveGlyph: View {
    /// The glyph's point size: the banner's bare bookmark is larger than
    /// the archive window row's carded icon.
    var size: CGFloat
    /// The saved state: a filled bookmark in the accent colour.
    var isFilled = false

    /// The save button's help and VoiceOver label.
    static let saveHelp = "Save permanently"
    /// The saved session's help and VoiceOver label.
    static let savedHelp = "Saved — kept permanently"

    var body: some View {
        Image(systemName: isFilled ? "bookmark.fill" : "bookmark")
            .font(.system(size: size))
            .foregroundStyle(isFilled ? Theme.accentPink : Theme.secondaryText)
    }
}
