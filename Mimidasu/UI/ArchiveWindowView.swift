import AppKit
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
/// waits for a non-live phase (the inline hint). The read model's typed
/// availability drives the unavailable state — the window still opens and
/// explains itself, and retries a faulted read when it appears again.
///
/// The window owns its delete/rename confirmations, the row add-language
/// chooser, and the row translate picker through `ArchiveWindowState` (one
/// slot each); the popovers attach to row controls but read that shared
/// state. Opening a session closes this window and leaves the transcript in
/// the main window.
struct ArchiveWindowView: View {
    var model: AppModel
    @State private var state = ArchiveWindowState()
    @AppearanceSetting private var appearance
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if !model.canOpenArchivedSession, model.archiveRead.isAvailable {
                liveHint
            }
            content
        }
        .frame(width: 640, height: 720, alignment: .top)
        .background(Theme.window)
        .preferredColorScheme($appearance.resolvedColorScheme)
        .onAppear { model.archiveRead.reloadIfUnavailable() }
        .alert("Delete this session?", isPresented: deletePresented, presenting: state.pendingDelete) { summary in
            Button("Cancel", role: .cancel) { state.pendingDelete = nil }
            Button("Delete", role: .destructive) {
                state.pendingDelete = nil
                model.deleteArchive(id: summary.id)
            }
        } message: { _ in
            Text("The transcript and its translations will be deleted permanently.")
        }
        .archiveRenameConfirmation(
            model,
            pendingRename: $state.pendingRename,
            draft: $state.renameDraft,
            renamedName: { state.renameValue }
        )
        // The bulk run's cloud disclosure: this window presents only the
        // intents raised from its own rows, and the sheet's dismissal
        // declines the held slot.
        .sheet(item: archiveDisclosure) { disclosure in
            CloudDisclosureSheet(
                intent: disclosure,
                sentenceCount: disclosureSentenceCount(disclosure),
                onConfirm: { model.confirmCloudDisclosure(disclosure) },
                onDecline: { model.declineCloudDisclosure() }
            )
        }
        // A SwiftUI scene close does not reliably reach `onDisappear`, so the
        // AppKit close notification owns the decline. A sheet's close is not
        // the window's close; the sheet-parent guard rejects it.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { note in
            guard let window = note.object as? NSWindow,
                  window.sheetParent == nil,
                  window.title == ArchiveWindow.title
            else { return }
            model.declineArchiveWindowDisclosure()
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

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .bottom, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(ArchiveWindow.title)
                    .font(.system(size: 17, weight: .heavy))
                    .foregroundStyle(Theme.primaryText)
                Text("Transcripts kept on this Mac")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText)
            }
            Spacer()
            HStack(spacing: 16) {
                countBlock("RECENT", value: recentCount, limit: ArchiveStore.recentCap)
                countBlock("SAVED", value: savedSessions.count, limit: nil)
            }
        }
        .padding(.top, 18)
        .padding(.horizontal, 20)
        .padding(.bottom, 13)
    }

    private func countBlock(_ label: String, value: Int, limit: Int?) -> some View {
        let accessibilityText = if let limit {
            "\(label) \(value) of \(limit)"
        } else {
            "\(label) \(value)"
        }
        return VStack(alignment: .trailing, spacing: 2) {
            Text(label)
                .font(.system(size: 9, weight: .heavy))
                .tracking(0.9)
                .foregroundStyle(Theme.secondaryText)
            HStack(spacing: 0) {
                Text("\(value)")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.primaryText)
                if let limit {
                    Text(" / \(limit)")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(Theme.gutterText)
                }
            }
            .monospacedDigit()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
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
        .padding(.horizontal, 20)
        .padding(.bottom, 4)
    }

    // MARK: - Body

    private var recentCount: Int {
        model.archiveRead.summaries.reduce(0) { count, summary in
            count + (summary.saved ? 0 : 1)
        }
    }

    @ViewBuilder
    private var content: some View {
        if !model.archiveRead.isAvailable {
            unavailableState
        } else if model.archiveRead.summaries.isEmpty {
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
            LazyVStack(alignment: .leading, spacing: 8, pinnedViews: [.sectionHeaders]) {
                if !recents.isEmpty {
                    Section {
                        ForEach(recents) { summary in
                            row(summary)
                                .padding(.horizontal, 20)
                        }
                    } header: {
                        sectionHeader("RECENT", count: recents.count)
                    }
                }
                if !savedSessions.isEmpty {
                    Section {
                        ForEach(savedSessions) { summary in
                            row(summary)
                                .padding(.horizontal, 20)
                        }
                    } header: {
                        sectionHeader("SAVED", count: savedSessions.count)
                    }
                }
            }
            .padding(.bottom, 18)
        }
    }

    private var recents: [ArchivedSessionSummary] {
        model.archiveRead.summaries.filter { summary in !summary.saved }
    }

    private var savedSessions: [ArchivedSessionSummary] {
        model.archiveRead.summaries.filter { summary in summary.saved }
    }

    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 12.5, weight: .heavy))
                .tracking(1.6)
                .foregroundStyle(Theme.primaryText)
            Text("\(count)")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.secondaryText)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .overlay(Capsule().stroke(Theme.dividerStrong, lineWidth: 1))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 15)
        .padding(.bottom, 13)
        .background(Theme.window)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Theme.dividerStrong)
                .frame(height: 1)
                .padding(.horizontal, 20)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title) \(count)")
        .accessibilityAddTraits(.isHeader)
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

    /// The per-row binding for the translate picker: true while this row and
    /// language own the window's one picker slot.
    private func translationPickerPresented(
        summary: ArchivedSessionSummary, lang: String
    ) -> Binding<Bool> {
        Binding(
            get: {
                state.translationPicker
                    == ArchiveWindowState.TranslationPickerTarget(
                        sessionID: summary.id, lang: lang
                    )
            },
            set: { isPresented in
                if isPresented {
                    state.requestTranslationPicker(summary, lang: lang)
                } else {
                    state.clearTranslationPicker(sessionID: summary.id, lang: lang)
                }
            }
        )
    }

    /// The shared disclosure slot, filtered to this window's bulk-run
    /// intents: the main window and Settings present their own. Writing nil —
    /// the sheet's dismissal — declines the held slot; decline is idempotent,
    /// so a dismissal after an explicit Decline changes nothing.
    private var archiveDisclosure: Binding<PendingCloudDisclosure?> {
        Binding(
            get: {
                guard let pending = model.providerAwaitingDisclosure,
                      case .archiveTranslation(_, _, _, .archiveWindow) = pending
                else { return nil }
                return pending
            },
            set: { newValue in
                if newValue == nil {
                    model.declineCloudDisclosure()
                }
            }
        )
    }

    /// The sentences the row-started run would send — the disclosure body's
    /// count line, read from the pending session's summary. Nil when the
    /// summary is no longer listed.
    private func disclosureSentenceCount(_ disclosure: PendingCloudDisclosure) -> Int? {
        guard case let .archiveTranslation(_, lang, session, .archiveWindow) = disclosure,
              let summary = model.archiveRead.summaries.first(where: { summary in
                  summary.id == session
              })
        else { return nil }
        return model.archiveTranslationSendCount(summary: summary, lang: lang)
    }

    private func row(_ summary: ArchivedSessionSummary) -> some View {
        let job = model.archiveTranslationJob
        // The scoped activity: this session's claim is visible from the
        // click onward, and progress numbers belong to a started walk.
        let activity = job.activity(for: summary.id)
        let request = activity.request
        return ArchiveSessionRow(
            model: model,
            summary: summary,
            isJobRunning: request != nil,
            jobLang: request?.lang,
            jobProgress: activity.progress.map { progress in (progress.processed, progress.total) },
            chooserPresented: chooserPresented(summary),
            translationPickerPresented: { lang in
                translationPickerPresented(summary: summary, lang: lang)
            },
            onOpen: { open(summary) },
            onDelete: { state.requestDelete(summary) },
            onRename: { state.requestRename(summary) },
            onSave: { model.promoteArchive(id: summary.id) }
        )
    }

    private func open(_ summary: ArchivedSessionSummary) {
        // Only a successful open swaps the pane; a refusal keeps the window.
        if model.openArchiveSession(id: summary.id) {
            dismissWindow(id: ArchiveWindow.sceneID)
        }
    }
}
