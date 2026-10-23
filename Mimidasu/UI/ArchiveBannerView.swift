import SwiftUI

/// The opened archive's banner at the top of the transcript pane: the date
/// and tier kicker, the title with the rename button, the duration, sentence,
/// and character stats, and a toolbar that holds the viewed-language switch,
/// the translate action, and the save bookmark.
///
/// The banner belongs to the transcript pane, so its type follows the pane's
/// UI scale: the same factor the transcript rows render at, applied to the
/// banner's own sizes. Padding and control chrome stay fixed. The other
/// archive surfaces — the popovers this banner opens and the archive list
/// window — keep their own fixed metrics.
struct ArchiveBannerView: View {
    var model: AppModel
    /// The rename question's slot, draft and store value — the same state
    /// the archive window's rows use, so both surfaces apply one rename
    /// rule.
    @State private var renameState = ArchiveWindowState()
    @State private var isLanguagePopoverPresented = false
    @State private var isTranslatePopoverPresented = false
    /// The pane's text scale: the banner's type and glyphs multiply by it.
    @AppStorage(UIScale.storageKey) private var uiScale = UIScale.default

    /// The rename button's help and its VoiceOver label — one string, so
    /// the two cannot drift.
    private static let renameHelp = "Rename this session"

    var body: some View {
        if let archive = model.openArchive {
            banner(archive)
        }
    }

    private func banner(_ archive: ArchivedSession) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 0) {
                Text(kicker(archive.summary))
                    .font(.system(size: 10 * uiScale.factor, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .textCase(.uppercase)
                titleRow(archive.summary)
                    .padding(.top, 5)
                statsRow(archive)
                    .padding(.top, 11)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            toolbar(archive)
                .fixedSize(horizontal: true, vertical: false)
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

    /// The status line above the title: the start datetime and the stored
    /// tier. The date moved out of the title so an unnamed session can show
    /// its first sentence as the title.
    private func kicker(_ summary: ArchivedSessionSummary) -> String {
        let tier = summary.saved ? "SAVED" : "RECENT"
        return "\(ArchivedSessionSummary.dateTimeText(summary.startedAt)) · \(tier)"
    }

    private func titleRow(_ summary: ArchivedSessionSummary) -> some View {
        HStack(spacing: 8) {
            Text(summary.rowTitle)
                .font(.system(size: 24 * uiScale.factor, weight: .bold))
                .foregroundStyle(Theme.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .layoutPriority(1)
            Button {
                renameState.requestRename(summary)
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 13 * uiScale.factor))
                    .foregroundStyle(Theme.secondaryText)
                    .frame(minWidth: 22, minHeight: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hoverHighlight(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .pointerStyle(.link)
            .help(Self.renameHelp)
            .accessibilityLabel(Self.renameHelp)
        }
    }

    private func statsRow(_ archive: ArchivedSession) -> some View {
        HStack(alignment: .top, spacing: 0) {
            stat("DURATION", archive.summary.durationText ?? "—")
            statDivider
            stat("SENTENCES", archive.summary.sentenceCount.formatted())
            statDivider
            stat("CHARACTERS", archive.characterCount.formatted())
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 9 * uiScale.factor, weight: .heavy))
                .tracking(1)
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Text(value)
                .font(.system(size: 12.5 * uiScale.factor, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
    }

    private var statDivider: some View {
        Rectangle()
            .fill(Theme.divider)
            .frame(width: 1, height: 24 * uiScale.factor)
            .padding(.horizontal, 16)
    }

    // MARK: - Toolbar

    /// One control on the banner's right: the viewed-language switch, the
    /// translate/retranslate action, and the save bookmark. The three
    /// segments share one rounded toolbar so the right side reads as a single object.
    private func toolbar(_ archive: ArchivedSession) -> some View {
        let viewedCode = model.archiveViewingCode
        let viewingCount = viewedCode.flatMap { code in
            archive.summary.languageCount(for: code)
        } ?? archive.summary.langs.first
        let busy = jobIsActive(on: archive, lang: viewedCode ?? viewingCount?.lang)
        return HStack(spacing: 0) {
            languageSegment(archive, count: viewingCount, busy: busy)
            toolbarDivider
            translateSegment(archive)
            toolbarDivider
            saveSegment(archive.summary)
        }
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Theme.cardFill)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .inset(by: 0.5)
                .stroke(Theme.cardStroke, lineWidth: 1)
                .allowsHitTesting(false)
        }
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    /// The toolbar's shared content height: the save glyph's 14pt at 100%,
    /// so every segment fills the same 32pt (content plus the 9pt vertical
    /// padding) and the hover wash spans the toolbar's full height.
    private var segmentContentHeight: CGFloat {
        14 * uiScale.factor
    }

    private var toolbarDivider: some View {
        Rectangle()
            .fill(Theme.divider)
            .frame(width: 1, height: 16 * uiScale.factor)
    }

    /// The viewed-language segment: badge code, translated count, and the
    /// chevron that opens the switch-language popover. A bulk run tints the
    /// counts and shows a spinner.
    private func languageSegment(
        _ archive: ArchivedSession,
        count: ArchiveLanguageCount?,
        busy: Bool
    ) -> some View {
        Button {
            isLanguagePopoverPresented = true
        } label: {
            HStack(spacing: 6) {
                if busy {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(uiScale.factor)
                        .frame(width: 12 * uiScale.factor, height: 12 * uiScale.factor)
                        .accessibilityHidden(true)
                }
                if let count {
                    Text(count.badgeCode)
                        .font(.system(size: 10 * uiScale.factor, weight: .heavy))
                        .foregroundStyle(busy ? Theme.accentPink : Theme.secondaryText)
                    Text("\(count.translated)/\(archive.summary.sentenceCount)")
                        .font(
                            .system(
                                size: 10.5 * uiScale.factor,
                                weight: .semibold,
                                design: .monospaced
                            )
                        )
                        .foregroundStyle(busy ? Theme.accentPink : Theme.primaryText)
                } else {
                    Text((model.archiveViewingCode ?? "—").uppercased())
                        .font(.system(size: 10 * uiScale.factor, weight: .heavy))
                        .foregroundStyle(Theme.secondaryText)
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 8 * uiScale.factor, weight: .semibold))
                    .foregroundStyle(Theme.secondaryText)
            }
            .frame(height: segmentContentHeight)
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .toolbarHover()
        .pointerStyle(.link)
        .help("Switch the viewed language")
        .accessibilityLabel(
            viewedLanguageLabel(
                count,
                total: archive.summary.sentenceCount,
                busy: busy
            )
        )
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

    /// The viewed-language chip's VoiceOver label: the counts plus the
    /// viewed-language hint the segment adds.
    private func viewedLanguageLabel(
        _ count: ArchiveLanguageCount?,
        total: Int,
        busy: Bool
    ) -> String {
        guard let count else { return "Viewed language" }
        return "Viewed language: \(count.accessibilityText(of: total, busy: busy))"
    }

    /// The Translate/Retranslate segment: opens the engine picker for the
    /// viewed language. Held back while a bulk run is claimed (one job at a
    /// time) and without a viewed language to translate.
    private func translateSegment(_ archive: ArchivedSession) -> some View {
        let disabled = model.archiveTranslationJob.activity != .idle
            || model.archiveViewingCode == nil
        let isComplete = viewedLanguageIsComplete(archive)
        let title = isComplete ? "Retranslate" : "Translate"
        return Button {
            isTranslatePopoverPresented = true
        } label: {
            Text(title)
                .font(.system(size: 11.5 * uiScale.factor, weight: .bold))
                .foregroundStyle(Theme.accentPink)
                .frame(height: segmentContentHeight)
                .padding(.horizontal, 11)
                .padding(.vertical, 9)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.45 : 1)
        .toolbarHover(isEnabled: !disabled)
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

    /// The save segment: an interactive outline bookmark for a Recent, a
    /// filled accent bookmark for a Saved session (display only, no
    /// demotion).
    @ViewBuilder
    private func saveSegment(_ summary: ArchivedSessionSummary) -> some View {
        if summary.saved {
            ArchiveSaveGlyph(size: 14 * uiScale.factor, isFilled: true)
                .frame(height: segmentContentHeight)
                .padding(.horizontal, 11)
                .padding(.vertical, 9)
                .help(ArchiveSaveGlyph.savedHelp)
                .accessibilityLabel(ArchiveSaveGlyph.savedHelp)
        } else {
            Button {
                model.saveOpenArchive()
            } label: {
                ArchiveSaveGlyph(size: 14 * uiScale.factor)
                    .frame(height: segmentContentHeight)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 9)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .toolbarHover()
            .pointerStyle(.link)
            .help(ArchiveSaveGlyph.saveHelp)
            .accessibilityLabel(ArchiveSaveGlyph.saveHelp)
        }
    }

    /// Whether the viewed language has a translation on every sentence — the
    /// segment then reads Retranslate, mirroring the picker's action.
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
}

/// The archive save affordance: the bookmark that promotes a stored session
/// to the permanent tier. The opened banner's toolbar shows it bare — filled
/// in the accent colour once the session is saved — and the archive window's
/// row shows it in the action cluster's card; the wording is one copy.
struct ArchiveSaveGlyph: View {
    /// The glyph's point size: the banner's bare bookmark scales with the
    /// UI scale and stays at least as large as the archive window row's
    /// carded icon at 100% and above; the row passes its own fixed size.
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

/// The toolbar segment's hover wash: painted behind the label at the
/// segment's full height, so the text stays crisp and the three segments
/// read as one uniform row. The toolbar stroke draws over it.
private struct ToolbarHoverFill: ViewModifier {
    var isEnabled = true

    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background {
                Rectangle()
                    .fill(Theme.tileFill)
                    .opacity(hovering && isEnabled ? 1 : 0)
            }
            .onHover { isHovering in hovering = isHovering }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

private extension View {
    func toolbarHover(isEnabled: Bool = true) -> some View {
        modifier(ToolbarHoverFill(isEnabled: isEnabled))
    }
}
