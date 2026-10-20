import SwiftUI

/// The opened archive's banner at the top of the transcript pane: title with
/// the rename button, the meta line (start datetime, duration, sentences,
/// characters), and the trailing cluster — the viewed-language chip (the
/// switch-language popover), the Translate/Retranslate button (the engine
/// picker), and the save icon — an outline bookmark that promotes a Recent, a
/// filled accent bookmark once Saved (display only, no demotion).
struct ArchiveBannerView: View {
    var model: AppModel
    @State private var isRenaming = false
    @State private var renameDraft = ""
    @State private var isLanguagePopoverPresented = false
    @State private var isTranslatePopoverPresented = false

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
                        renameDraft = archive.summary.name ?? ""
                        isRenaming = true
                    } label: {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.secondaryText)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .hoverHighlight(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .pointerStyle(.link)
                    .help("Rename this session")
                    .accessibilityLabel("Rename this session")
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
        .alert("Rename session", isPresented: $isRenaming) {
            TextField("Name", text: $renameDraft)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                let trimmed = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                model.renameArchive(
                    id: archive.summary.id, name: trimmed.isEmpty ? nil : trimmed
                )
            }
        }
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
        let chip = count.chipText(of: total)
        return "Viewed language: \(busy ? "\(chip), translating" : chip)"
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
            Image(systemName: "bookmark.fill")
                .font(.system(size: 14))
                .foregroundStyle(Theme.accentPink)
                .help("Saved — kept permanently")
                .accessibilityLabel("Saved — kept permanently")
        } else {
            Button {
                model.saveOpenArchive()
            } label: {
                Image(systemName: "bookmark")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.secondaryText)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hoverHighlight(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .pointerStyle(.link)
            .help("Save permanently")
            .accessibilityLabel("Save permanently")
        }
    }
}
