import SwiftUI

/// Archive-scene identity, shared by the scene declaration, the openers
/// (sidebar history button, post-stop toast's View action), and the
/// close-on-open in the window itself.
enum ArchiveWindow {
    static let title = "Session archive"
    static let sceneID = "archive"
}

/// The archive window: the stored sessions split Recent/Saved, newest first.
/// Rows are browsable and manageable at any time; only opening a transcript
/// waits for a non-live phase (the inline hint). Degraded store shows the
/// unavailable state — the window still opens and explains itself.
///
/// The window owns its delete/rename confirmations through
/// `ArchiveWindowState` (one slot each); a row never presents an alert of its
/// own. Opening a session closes this window and leaves the transcript in the
/// main window.
struct ArchiveWindowView: View {
    var model: AppModel
    @State private var state = ArchiveWindowState()
    @AppearanceSetting private var appearance
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if !model.canOpenArchivedSession, !model.archive.isDegraded {
                liveHint
            }
            content
        }
        .frame(width: 640, height: 720, alignment: .top)
        .background(Theme.window)
        .preferredColorScheme($appearance.resolvedColorScheme)
        .alert("Delete this session?", isPresented: deletePresented, presenting: state.pendingDelete) { summary in
            Button("Cancel", role: .cancel) { state.pendingDelete = nil }
            Button("Delete", role: .destructive) {
                state.pendingDelete = nil
                model.deleteArchive(id: summary.id)
            }
        } message: { _ in
            Text("The transcript and its translations will be deleted permanently.")
        }
        .alert("Rename session", isPresented: renamePresented) {
            TextField("Name", text: $state.renameDraft)
            Button("Cancel", role: .cancel) { state.pendingRename = nil }
            Button("Save") {
                if let summary = state.pendingRename {
                    model.renameArchive(id: summary.id, name: state.renameValue)
                }
                state.pendingRename = nil
            }
        }
    }

    // MARK: - Confirmation gates

    private var deletePresented: Binding<Bool> {
        Binding(
            get: { state.pendingDelete != nil },
            set: { isPresented in
                if !isPresented {
                    state.pendingDelete = nil
                }
            }
        )
    }

    private var renamePresented: Binding<Bool> {
        Binding(
            get: { state.pendingRename != nil },
            set: { isPresented in
                if !isPresented {
                    state.pendingRename = nil
                }
            }
        )
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(ArchiveWindow.title)
                .font(.system(size: 15, weight: .heavy))
                .foregroundStyle(Theme.primaryText)
            Spacer()
            Text("\(recentCount) / \(ArchiveStore.recentCap) kept")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Theme.secondaryText)
        }
        .padding(.top, 18)
        .padding(.horizontal, 18)
        .padding(.bottom, 12)
    }

    private var liveHint: some View {
        HStack(alignment: .top, spacing: 9) {
            Circle()
                .fill(Theme.dotYellow)
                .frame(width: 7, height: 7)
                .padding(.top, 4)
            Text("**Live session in progress** — stop the session to open transcripts.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondaryText)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.dotYellow.opacity(0.12))
        )
        .padding(.horizontal, 18)
        .padding(.bottom, 4)
    }

    // MARK: - Body

    /// Revision-observing read of the store: `archiveRevision` gates the
    /// re-evaluation, `list()` is the small sync read.
    private var sessions: [ArchivedSessionSummary] {
        _ = model.archiveRevision
        return model.archive.list()
    }

    private var recentCount: Int {
        sessions.reduce(0) { count, summary in count + (summary.saved ? 0 : 1) }
    }

    @ViewBuilder
    private var content: some View {
        if model.archive.isDegraded {
            unavailableState
        } else if sessions.isEmpty {
            emptyState
        } else {
            sessionList
        }
    }

    private var unavailableState: some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 22))
                .foregroundStyle(Theme.dotYellow)
            Text("Archive unavailable")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Theme.primaryText)
            Text("The session store couldn't be opened. Sessions can't be saved or listed; transcription continues.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 22))
                .foregroundStyle(Theme.secondaryText)
            Text("No sessions yet")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Theme.primaryText)
            Text("Stopped sessions appear here as recents; save the ones you want to keep.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sessionList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if !recents.isEmpty {
                    sectionLabel("RECENT")
                    ForEach(recents) { summary in row(summary) }
                }
                if !savedSessions.isEmpty {
                    sectionLabel("SAVED")
                    ForEach(savedSessions) { summary in row(summary) }
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 18)
        }
    }

    private var recents: [ArchivedSessionSummary] {
        sessions.filter { summary in !summary.saved }
    }

    private var savedSessions: [ArchivedSessionSummary] {
        sessions.filter { summary in summary.saved }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .heavy))
            .tracking(1.4)
            .foregroundStyle(Theme.secondaryText)
            .padding(.top, 8)
    }

    /// The per-row binding for the add-language chooser: true while this row
    /// owns the window's one chooser slot.
    private func chooserPresented(_ summary: ArchivedSessionSummary) -> Binding<Bool> {
        Binding(
            get: { state.chooserPopoverSession == summary.id },
            set: { isPresented in
                if isPresented {
                    state.requestChooser(summary)
                } else {
                    state.clearChooser(summary)
                }
            }
        )
    }

    private func row(_ summary: ArchivedSessionSummary) -> some View {
        let job = model.archiveTranslationJob
        // The scoped activity: this session's claim is visible from the
        // click onward, and progress numbers belong to a started walk.
        let activity = job.activity(for: summary.id)
        let request = activity.request
        return ArchiveRow(
            model: model,
            summary: summary,
            canOpen: model.canOpenArchivedSession,
            isJobRunning: request != nil,
            jobLang: request?.lang,
            jobProgress: activity.progress.map { progress in (progress.processed, progress.total) },
            chooserPresented: chooserPresented(summary),
            onOpen: { open(summary) },
            onDelete: { state.requestDelete(summary) },
            onRename: { state.requestRename(summary) },
            onSave: { model.promoteArchive(id: summary.id) }
        )
    }

    private func open(_ summary: ArchivedSessionSummary) {
        model.openArchiveSession(id: summary.id)
        // Only a successful open swaps the pane; a refusal keeps the window.
        if model.openArchive?.id == summary.id {
            dismissWindow(id: ArchiveWindow.sceneID)
        }
    }
}

/// One stored-session row: title (name or auto-title), meta line, the
/// language chip line with its `+` add pill, Interrupted badge, the
/// Delete/Rename/Save cluster, and the text-only Open button. While a bulk
/// run claims this session the running language's chip reports it, and a
/// thin progress bar renders under the chips once the run itself starts.
private struct ArchiveRow: View {
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
    let onOpen: () -> Void
    let onDelete: () -> Void
    let onRename: () -> Void
    let onSave: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(summary.displayTitle)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Theme.primaryText)
                        .lineLimit(1)
                    if summary.status == .interrupted {
                        Text("INTERRUPTED")
                            .font(.system(size: 9.5, weight: .heavy))
                            .tracking(0.5)
                            .foregroundStyle(Theme.dotYellow)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Theme.dotYellow.opacity(0.12)))
                    }
                    Spacer()
                }
                Text(summary.metaLine)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.secondaryText)
                    .monospacedDigit()
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
            VStack(alignment: .trailing, spacing: 10) {
                HStack(spacing: 6) {
                    actionButton("trash", help: "Delete", action: onDelete)
                    actionButton("pencil", help: "Rename", action: onRename)
                    if !summary.saved {
                        actionButton("bookmark", help: "Save permanently", action: onSave)
                    }
                }
                Button(action: onOpen) {
                    Text("Open")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.accentPink)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Theme.accentPink.opacity(0.12))
                        )
                }
                .buttonStyle(.plain)
                .disabled(!canOpen)
                .opacity(canOpen ? 1 : 0.45)
                .help(canOpen ? "Open this transcript" : "Stop the session to open transcripts")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .cardSurface(radius: 12)
    }

    /// The row's language chips, display-only, with the `+` pill that opens
    /// the add-language chooser for this session — the only interactive
    /// element on the line.
    private var chipLine: some View {
        HStack(spacing: 6) {
            ForEach(summary.langs) { count in
                ArchiveLanguageChip(
                    count: count,
                    total: summary.sentenceCount,
                    busy: isJobRunning && count.lang == jobLang,
                    selected: model.openArchive?.id == summary.id
                        && count.lang == model.archiveViewingCode
                )
            }
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
                        // Never mutates another archive's viewing language:
                        // a row picker only serves its own (opened) session.
                        guard model.openArchive?.id == summary.id else { return }
                        model.selectArchiveViewingLanguage(lang)
                    },
                    initiallyShowingChooser: true
                )
            }
        }
        .padding(.top, 4)
    }

    private func actionButton(
        _ systemImage: String, help: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondaryText)
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
        .hoverHighlight(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .help(help)
        .accessibilityLabel(help)
    }
}
