import Foundation

// The archive surface of `AppModel`: the live session's continuous persistence,
// the launch sweep, archive mode (open/close in the transcript pane), the
// promote/rename/delete commands, and the single write-back seam every landed
// translation funnels through.
//
// **Seam rule:** a feature file that outgrows 600 **code** lines splits at the
// next feature boundary — never mid-feature, never because it grew more
// documentation.

/// Archive surface of `AppModel`: the live session's continuous persistence,
/// the launch sweep, archive mode (open/close in the transcript pane), and
/// the promote/rename/delete commands behind the archive window and the
/// opened banner.
extension AppModel {

    // MARK: - Continuous persistence (live session)

    /// Persists one finalized sentence of the live session. The first
    /// success creates the `recording` row (empty sessions never create
    /// one); the first failure latches `archiveWriteFailed` for the rest of
    /// the session, posts one warning toast, and keeps transcribing.
    func persistSentence(_ sentence: Sentence) {
        guard !archiveWriteFailed else { return }
        // The metadata is assigned by `SessionController.begin` before any
        // chunk can flow, so it is always present when a sentence lands.
        guard let metadata = sessionController.sessionMetadata else { return }
        guard let id = archiveRead.append(
            sentence: sentence, sessionID: recordingSessionID, metadata: metadata
        ) else {
            latchArchiveWriteFailure(
                body: "The session store couldn't be written to. "
                    + "Sessions can't be saved or listed; transcription continues."
            )
            return
        }
        recordingSessionID = id
    }

    /// Finalizes the live recording as a Recent. Returns whether a row was
    /// finalized — the post-stop toast's gate. Persists nothing once the
    /// session's writes have failed (or the store is terminally degraded).
    @discardableResult
    func finalizeLiveSession(durationMS: Int) -> Bool {
        guard let id = recordingSessionID else { return false }
        recordingSessionID = nil
        guard !archiveWriteFailed, !archive.isDegraded,
              archiveRead.finalize(session: id, durationMS: durationMS, saved: false)
        else {
            if !archiveWriteFailed {
                latchArchiveWriteFailure(
                    body: "The session store couldn't be written to. "
                        + "This session wasn't added to the archive."
                )
            }
            return false
        }
        return true
    }

    /// Launch sweep: a `recording` row left by an unclean exit becomes an
    /// Interrupted recent before anything can list the archive.
    func sweepArchivesOnLaunch() {
        guard archiveRead.sweepInterrupted() else { return }
    }

    /// Whether session persistence can be trusted this session: the terminal
    /// open failure and the per-session write latch both make it false. While
    /// unavailable the stop prompt is skipped and stop persists nothing.
    var archiveAvailable: Bool {
        !archive.isDegraded && !archiveWriteFailed
    }

    /// Latches the live session's write failure — the one-shot warning for a
    /// session whose persistence can no longer be trusted — and posts it.
    /// Internal so the translation write-back can latch through it.
    func latchArchiveWriteFailure(body: String) {
        archiveWriteFailed = true
        postArchiveWriteWarning(body: body)
    }

    /// Posts the archive-unavailable warning without latching: a per-operation
    /// archive-mode write can fail without disabling the live session's
    /// persistence. `isClosable` is opt-in because the live session's warning
    /// is a condition to fix, not a transient card to wave away.
    func postArchiveWriteWarning(body: String, isClosable: Bool = false) {
        toasts.post(
            key: ToastKey.archiveUnavailable, style: .yellowPersistent,
            title: "Archive unavailable", body: body, isClosable: isClosable
        )
    }

    /// The post-stop toast carrying the archive window's View action.
    func postArchivedRecentToast() {
        toasts.post(
            key: ToastKey.archiveRecent, style: .yellowAuto,
            title: "Saved to Recent",
            body: "Kept with the last 10 recent sessions — "
                + "open the archive to save it permanently.",
            action: ToastCenter.Action(label: "View") {
                NotificationCenter.default.post(name: .mimidasuOpenArchiveWindow, object: nil)
            }
        )
    }

    // MARK: - Archive mode

    /// Whether a stored session can be opened right now: browsing and
    /// managing always work, but opening a transcript is blocked while any
    /// session is live-ish (the archive window shows an inline hint then).
    var canOpenArchivedSession: Bool {
        !SessionPhaseMachine.isLiveOrStopping(phase)
    }

    /// Opens a stored session read-only into the transcript pane: rows and
    /// metadata swap, dictionary anchors reset, HUD/overlay force-hide, the
    /// session-clock anchors clear, and the re-translate lane generation
    /// turns over. Re-opening the session already in the pane is a no-op —
    /// its bulk run (and card) stays untouched. A bulk run over a different
    /// archive keeps running (its airborne result still persists under its
    /// own id), and a pending main-window pick for the previous archive
    /// clears with the swap.
    @discardableResult
    func openArchiveSession(id: Int64) -> Bool {
        guard canOpenArchivedSession else { return false }
        // The window's "back to pane" move: nothing swaps, so the running
        // bulk job and its card must survive.
        if openArchive?.id == id {
            return true
        }
        guard let loaded = archive.load(id: id) else { return false }
        // The main window's sheet is leaving the pane with the previous
        // archive; the archive window's own intents and other kinds stay.
        if case .archiveTranslation(_, _, _, .mainWindow) = providerAwaitingDisclosure {
            providerAwaitingDisclosure = nil
        }
        openArchive = loaded
        archiveViewingLanguage = nil
        entries = loaded.entries
        entryPositionBySentence = Dictionary(
            uniqueKeysWithValues: loaded.entries.enumerated().map { position, entry in
                (entry.sentence.index, position)
            }
        )
        sessionCharacterCount = loaded.characterCount
        // The transcript swapped under the pane: the dictionary anchors and
        // any in-flight lookup belong to the previous rows.
        selectedLookup = nil
        pinnedLookup = nil
        lookupGeneration &+= 1
        hudPinnedIndex = nil
        hudVisible = false
        translationOverlayVisible = false
        // The SESSION card is hidden in archive mode; closing restores the
        // idle card state, so the live-session clock anchors go now.
        sessionStartedAt = nil
        sessionEndedAt = nil
        captureLostAt = nil
        retranslate.archiveWillOpen()
        return true
    }

    /// Closes the opened archive: the pane empties (no restore) and the
    /// lane generation turns over again so no straggler lands on the next
    /// archive's rows. A bulk run in flight keeps running (its landed rows
    /// stay stored); the viewing language and a pending main-window
    /// archive-translation pick clear with the archive.
    func closeArchive() {
        guard openArchive != nil else { return }
        if case .archiveTranslation(_, _, _, .mainWindow) = providerAwaitingDisclosure {
            providerAwaitingDisclosure = nil
        }
        openArchive = nil
        archiveViewingLanguage = nil
        entries.removeAll()
        entryPositionBySentence.removeAll()
        sessionCharacterCount = 0
        selectedLookup = nil
        pinnedLookup = nil
        lookupGeneration &+= 1
        retranslate.archiveWillClose()
    }

    /// Selects the opened archive's viewing language — view-only: the
    /// stored translations are untouched.
    func selectArchiveViewingLanguage(_ lang: String) {
        guard openArchive != nil else { return }
        archiveViewingLanguage = lang
    }

    /// Adds a language to a stored session: membership persists from this
    /// moment, before any translation lands (a 0/N chip). When the session
    /// is the opened one, the added language also becomes the viewing
    /// language. Returns whether the membership write landed.
    @discardableResult
    func addArchiveLanguage(id: Int64, lang: String) -> Bool {
        guard archiveRead.addLanguage(id: id, lang: lang) else { return false }
        if openArchive?.id == id {
            archiveViewingLanguage = lang
            refreshOpenArchiveLanguages()
        }
        return true
    }

    /// Re-reads the opened archive's language payload from the store — the
    /// banner chip's refresh after a membership add or a landed result.
    func refreshOpenArchiveLanguages() {
        guard let id = openArchive?.id, let refreshed = archive.summary(id: id) else { return }
        openArchive?.summary.langs = refreshed.langs
    }

    // MARK: - Archive window commands

    /// Promotes a recent to the permanent Saved tier. One click, no
    /// confirmation; updates the opened banner in place when it is the same
    /// session.
    func promoteArchive(id: Int64) {
        guard archiveRead.promote(id: id) else {
            postArchiveWriteWarning(
                body: "The session store couldn't be written to. This session wasn't saved.",
                isClosable: true
            )
            return
        }
        if openArchive?.id == id {
            openArchive?.summary.saved = true
        }
    }

    /// The opened banner's save icon: promotes whatever it displays, when it
    /// is still a Recent.
    func saveOpenArchive() {
        guard let summary = openArchive?.summary, !summary.saved else { return }
        promoteArchive(id: summary.id)
    }

    /// Renames a stored session (Recent or Saved alike); an empty name
    /// clears back to the auto-title. Tier, eviction, ordering, and
    /// timestamps are unaffected.
    func renameArchive(id: Int64, name: String?) {
        guard archiveRead.rename(id: id, name: name) else {
            postArchiveWriteWarning(
                body: "The session store couldn't be written to. This rename wasn't applied.",
                isClosable: true
            )
            return
        }
        if openArchive?.id == id {
            openArchive?.summary.name = ArchiveStore.normalizedName(name)
        }
    }

    /// Deletes a stored session, closing it first when it is the one open.
    /// Refused while that session is the run's target: the walk would lose
    /// its rows mid-flight.
    func deleteArchive(id: Int64) {
        guard archiveTranslationJob.activity.request?.sessionID != id else { return }
        if openArchive?.id == id {
            closeArchive()
        }
        guard archiveRead.delete(id: id) else {
            postArchiveWriteWarning(
                body: "The session store couldn't be written to. This session wasn't deleted.",
                isClosable: true
            )
            return
        }
    }
}

// The single write-back seam every landed translation funnels through —
// per-row re-translate, bulk runs, and the live recording alike: one upsert
// through the archive read model, whose landed write bumps the revision,
// plus one conditional refresh of the opened archive's languages and one
// landed report. Callers keep their row swaps and their own warning
// policies (archive-mode cards closable; the live latch persistent).

extension AppModel {
    /// The one shared body for a translation whose store write was lost —
    /// the archive-mode card's copy. The live latch names its own, wider
    /// consequence instead.
    static let lostTranslationWriteWarning =
        "The session store couldn't be written to. "
            + "This translation wasn't added to the archive."

    /// Writes one landed translation through to `session` via the archive
    /// read model: its upsert first, whose landed write bumps the revision,
    /// then the opened archive's language payload refreshes when the write
    /// targeted it. Reports whether the write landed — a lost write changes
    /// nothing (no refresh, no bump), and the caller's policy decides the
    /// warning and whether its row keeps its previous text.
    @discardableResult
    func writeBackTranslation(
        _ translation: SentenceTranslation, index: Int, session: Int64
    ) -> Bool {
        guard archiveRead.upsert(translation: translation, index: index, session: session) else {
            return false
        }
        if openArchive?.id == session {
            refreshOpenArchiveLanguages()
        }
        return true
    }
}
