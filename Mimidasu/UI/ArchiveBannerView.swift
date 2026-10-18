import SwiftUI

/// The opened archive's banner at the top of the transcript pane: title with
/// the rename pencil, the meta line (start datetime, duration, sentences,
/// characters), and the trailing cluster — the viewed-language chip (the
/// switch-language popover), the Translate button (the provider picker), and
/// the save icon — an outline bookmark that promotes a Recent, a filled
/// accent bookmark once Saved (display only, no demotion).
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
                        Image(systemName: "pencil")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.secondaryText)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .hoverHighlight(RoundedRectangle(cornerRadius: 6, style: .continuous))
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
            translateButton
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
                    busy: jobIsRunning(on: archive, lang: busyLang),
                    showsChevron: true
                )
            } else {
                plainCodeChip(viewedCode)
            }
        }
        .buttonStyle(.plain)
        .hoverHighlight(Capsule())
        .help("Switch the viewed language")
        .accessibilityLabel("Viewed language")
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

    private func plainCodeChip(_ code: String?) -> some View {
        Text((code ?? "—").uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Theme.secondaryText)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(Capsule().fill(Theme.tileFill))
    }

    /// The Translate button: opens the provider picker for the viewed
    /// language. Held back while a bulk run is claimed (one job at a time)
    /// and without a viewed language to translate.
    private var translateButton: some View {
        let disabled = model.archiveTranslationJob.isActive || model.archiveViewingCode == nil
        return Button {
            isTranslatePopoverPresented = true
        } label: {
            Text("Translate")
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
        .help("Translate this archive's viewed language")
        .accessibilityLabel("Translate the viewed language")
        .popover(isPresented: $isTranslatePopoverPresented, arrowEdge: .bottom) {
            if let code = model.archiveViewingCode {
                ArchiveTranslationProviderPicker(
                    model: model,
                    lang: code,
                    language: TargetLanguage(code: code),
                    onStart: { provider in startTranslation(provider, lang: code) },
                    isPresented: $isTranslatePopoverPresented
                )
            }
        }
    }

    /// Routes the picker's start: Apple runs begin here; an external pick is
    /// held for the cloud disclosure, whose confirm callback starts the run.
    private func startTranslation(_ provider: TranslationProvider, lang: String) {
        if provider == .apple {
            model.beginArchiveTranslation(provider: .apple, lang: lang)
        } else {
            model.providerAwaitingDisclosure = .archiveTranslation(provider, lang: lang)
        }
    }

    /// Whether the bulk job is running for this session and language.
    private func jobIsRunning(on archive: ArchivedSession, lang: String?) -> Bool {
        guard let run = model.archiveTranslationJob.currentRun else { return false }
        return model.archiveTranslationJob.isRunning
            && run.sessionID == archive.id
            && run.lang == lang
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
            .help("Save permanently")
            .accessibilityLabel("Save permanently")
        }
    }
}
