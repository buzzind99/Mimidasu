import Foundation

// The bulk archive-translation surface of `AppModel`: the job, its engine
// resolver and landing sink, and the archiving toast card.
//
// **Seam rule:** a feature file that outgrows 600 **code** lines splits at the
// next feature boundary — never mid-feature, never because it grew more
// documentation.

// Bulk archive-translation surface of `AppModel`: owns the job, wires its
// engine resolver and landing sink, and turns the job's events into the
// archiving toast card (progress that morphs into the run's summary) and
// the cancel points. The per-row lane stays the single-sentence surface;
// the job owns the batch mode, and `archiveTranslationRunning` keeps the
// two from ever flying through one session-backed engine at once.

extension AppModel {
    /// Wires the bulk job's engine resolver, landing sink, and event
    /// reporter. Called once from `init`, after the coordinators exist.
    func wireArchiveTranslationJob() {
        archiveTranslationJob.resolveEngine = { [weak self] engine, target in
            guard let self else { return .cancelled }
            return await retranslate.resolveArchiveJobEngine(
                selection: archiveJobSelection(for: engine, target: target), target: target,
                shouldAbort: { self.archiveTranslationJob.isCancelled }
            )
        }
        archiveTranslationJob.land = { [weak self] index, translation in
            guard let self else { return false }
            return landArchiveTranslation(index: index, translation: translation)
        }
        archiveTranslationJob.onEvent = { [weak self] event in
            self?.handleArchiveTranslationEvent(event)
        }
    }

    // MARK: - Commands

    /// Starts a bulk run for one language through `engine` — the archive
    /// engine picker's action and the cloud disclosure's confirm callback.
    /// The scope derives from the language's completeness: missing sentences
    /// fill, a complete language re-translates every sentence as a fresh
    /// full pass. The claim refuses while a run is active; a session no
    /// longer in the archive reports that instead of claiming.
    func beginArchiveTranslation(engine: RetranslateEngine, lang: String, sessionID: Int64) {
        let entries: [SessionEntry]
        if let openArchive, openArchive.id == sessionID {
            entries = openArchive.entries
        } else if let stored = archive.load(id: sessionID) {
            entries = stored.entries
        } else {
            toasts.post(
                key: ToastKey.archiveTranslation, style: .yellowAuto,
                title: "Archive translation unavailable",
                body: "This session is no longer in the archive."
            )
            return
        }
        let translated = Self.translatedIndexes(in: entries, lang: lang)
        let scope: ArchiveTranslationJob.Scope =
            translated.count >= entries.count && !entries.isEmpty ? .all : .missing
        claimAndRunArchiveTranslation(
            ArchiveTranslationJob.Request(
                sessionID: sessionID,
                lang: lang,
                engine: engine,
                sentences: entries.map(\.sentence),
                translated: translated,
                scope: scope
            )
        )
    }

    /// The open archive's spelling, for the banner and existing callers.
    func beginArchiveTranslation(engine: RetranslateEngine, lang: String) {
        guard let sessionID = openArchive?.id else { return }
        beginArchiveTranslation(engine: engine, lang: lang, sessionID: sessionID)
    }

    /// The failure summary's Retry action: re-runs the same language and
    /// engine over exactly the failed sentences, in index order, without
    /// re-raising the cloud disclosure. Rebuilt from the previous run's
    /// captured request, so it works whether or not that session is still
    /// open.
    func retryFailedArchiveTranslation() {
        guard archiveTranslationJob.activity == .idle,
              let run = archiveTranslationJob.lastRun,
              !archiveTranslationJob.failureIndexes.isEmpty
        else { return }
        guard archive.load(id: run.request.sessionID) != nil else {
            toasts.post(
                key: ToastKey.archiveTranslation, style: .yellowAuto,
                title: "Archive translation unavailable",
                body: "This session is no longer in the archive."
            )
            return
        }
        claimAndRunArchiveTranslation(
            ArchiveTranslationJob.Request(
                sessionID: run.request.sessionID,
                lang: run.request.lang,
                engine: run.request.engine,
                sentences: run.request.sentences,
                translated: run.request.translated,
                scope: .failedOnly(Set(archiveTranslationJob.failureIndexes))
            )
        )
    }

    /// The archive picker's start request: refused while a run is claimed or
    /// another cloud-disclosure intent is held (the raise would clobber it
    /// and swap the presented sheet's content mid-flight). An Apple-tier
    /// engine pick starts its run directly, and an external engine pick
    /// stages the run for the disclosure whose confirm callback starts it.
    func requestArchiveTranslation(
        engine: RetranslateEngine, lang: String, sessionID: Int64,
        presenter: ArchiveDisclosurePresenter
    ) {
        guard archiveTranslationJob.activity == .idle, providerAwaitingDisclosure == nil else {
            return
        }
        if let provider = engine.provider {
            providerAwaitingDisclosure = .archiveTranslation(
                provider, lang: lang, session: sessionID, presenter: presenter
            )
        } else {
            beginArchiveTranslation(engine: engine, lang: lang, sessionID: sessionID)
        }
    }

    /// The open archive's spelling at the main window, for the banner.
    func requestArchiveTranslation(engine: RetranslateEngine, lang: String) {
        guard let sessionID = openArchive?.id else { return }
        requestArchiveTranslation(
            engine: engine, lang: lang, sessionID: sessionID, presenter: .mainWindow
        )
    }

    /// Stops the run in flight — no new sentence starts, whatever is
    /// airborne still lands (partial results stay stored) — and dismisses
    /// the run's card: a canceled run posts no summary. The dismissal is
    /// unconditional, because the failure summary card outlives the finished
    /// run.
    func cancelArchiveTranslation() {
        if archiveTranslationJob.activity != .idle {
            archiveTranslationJob.cancel()
        }
        toasts.dismiss(key: ToastKey.archiveTranslation)
    }

    /// The sentences a run for `lang` would send in `summary` — the engine
    /// picker's count line and the pending disclosure's body: the missing
    /// count, or the full sentence count when the language is complete (a
    /// Retranslate re-sends every sentence).
    func archiveTranslationSendCount(summary: ArchivedSessionSummary, lang: String) -> Int {
        let total = summary.sentenceCount
        let translated = summary.languageCount(for: lang)?.translated ?? 0
        return translated >= total && total > 0 ? total : max(total - translated, 0)
    }

    /// The opened archive's spelling: nil with no archive open.
    func archiveTranslationSendCount(lang: String) -> Int? {
        guard let summary = openArchive?.summary else { return nil }
        return archiveTranslationSendCount(summary: summary, lang: lang)
    }

    /// True when `summary`'s `lang` has a translation on every sentence —
    /// the picker's Retranslate mode.
    func archiveLanguageIsComplete(summary: ArchivedSessionSummary, lang: String) -> Bool {
        guard summary.sentenceCount > 0 else { return false }
        let translated = summary.languageCount(for: lang)?.translated ?? 0
        return translated >= summary.sentenceCount
    }

    /// The opened archive's spelling: false with no archive open.
    func archiveLanguageIsComplete(_ lang: String) -> Bool {
        guard let summary = openArchive?.summary else { return false }
        return archiveLanguageIsComplete(summary: summary, lang: lang)
    }

    // MARK: - Internals

    /// The one start path: begin (the derived scope) and retry-failed (the
    /// explicit failure set) both land here. A live capture refuses: the
    /// run's writes belong to stored rows, and the archive surfaces are
    /// blocked anyway. The request is built first, then claimed
    /// synchronously — the run reads as claimed from this instant — and
    /// finally the async walk starts.
    private func claimAndRunArchiveTranslation(_ request: ArchiveTranslationJob.Request) {
        guard canOpenArchivedSession, archiveTranslationJob.claim(request) else { return }
        Task { [archiveTranslationJob] in
            await archiveTranslationJob.run()
        }
    }

    /// The archive window's close declines only the intents its own rows
    /// staged; a main-window intent stays for its sheet.
    func declineArchiveWindowDisclosure() {
        if case .archiveTranslation(_, _, _, .archiveWindow) = providerAwaitingDisclosure {
            declineCloudDisclosure()
        }
    }

    /// The run's engine: the picker's explicit selection, passed through —
    /// Apple high fidelity degrades to the fast model only on pair-scoped
    /// evidence that the strategy can't be served for the run's target
    /// (the OS lacks the strategy API, or the probe landed not-installed for
    /// exactly that pair). The settings re-translate selection plays no part:
    /// the picker's own row decides the tier.
    private func archiveJobSelection(
        for engine: RetranslateEngine, target: TargetLanguage
    ) -> RetranslateEngine {
        retranslate.effectiveAppleTier(engine, targetCode: target.code)
    }

    /// Whether the archive engine picker offers — and defaults to — the
    /// Apple Intelligence tier for `lang`: the strategy API exists and the
    /// pair isn't known unavailable. Probe evidence is pair-scoped, so an
    /// unprobed pair stays offered; the framework's silent fast fallback
    /// covers the remainder.
    func archiveHighFidelityOffered(for lang: String) -> Bool {
        translationSession.tierAvailability.offersHighFidelity(for: lang)
    }

    private static func translatedIndexes(
        in entries: [SessionEntry], lang: String
    ) -> Set<Int> {
        Set(entries.filter { entry in
            entry.translation(for: lang) != nil
        }.map { entry in
            entry.sentence.index
        })
    }

    /// Lands one bulk result through the one write-back seam, keyed by the
    /// run's captured session id (so an airborne result at close time still
    /// persists): the row swap happens only when the write landed and the
    /// pane still shows that archive. Returns whether the write landed; a
    /// lost write posts the run's archive warning and makes the sentence a
    /// retryable failure in the job's accounting — the row keeps its
    /// previous text, so the display never claims a translation the store
    /// lacks.
    private func landArchiveTranslation(index: Int, translation: SentenceTranslation) -> Bool {
        guard let sessionID = archiveTranslationJob.activity.request?.sessionID else { return false }
        guard writeBackTranslation(translation, index: index, session: sessionID) else {
            // The run's row vanishing mid-flight is expected when the run was
            // cancelled; only a genuine fault reports.
            if !archiveTranslationJob.isCancelled {
                reportArchiveWriteFailure()
            }
            return false
        }
        if openArchive?.id == sessionID, let at = entryPositionBySentence[index] {
            entries[at].replaceTranslation(translation)
        }
        return true
    }

    /// Posts the archive warning once per run: repeats are skipped while the
    /// card is up, and nothing latches — the per-session write latch belongs
    /// to the live recording, so a later run reports its own failures.
    private func reportArchiveWriteFailure() {
        let warningVisible = toasts.toasts.contains { toast in
            toast.key == ToastKey.archiveUnavailable
        }
        guard !warningVisible else { return }
        postArchiveWriteWarning(
            body: Self.lostTranslationWriteWarning,
            isClosable: true
        )
    }

    // MARK: - Event reporting

    private func handleArchiveTranslationEvent(_ event: ArchiveTranslationJob.Event) {
        switch event {
        case let .started(total):
            postArchiveTranslationProgress(processed: 0, total: total)
        case let .progress(processed, total):
            postArchiveTranslationProgress(processed: processed, total: total)
        case let .finished(translated, failedIndexes):
            postArchiveTranslationSummary(translated: translated, failedIndexes: failedIndexes)
        case .cancelled:
            toasts.dismiss(key: ToastKey.archiveTranslation)
        case let .unavailable(reason):
            // The run's own card, not the lane's retry key: a first-time
            // Translate must not read as a re-translation.
            toasts.post(
                key: ToastKey.archiveTranslation, style: .yellowAuto,
                title: "Archive translation unavailable", body: reason
            )
        }
    }

    /// The keyed progress card: per-key dedup replaces it in place, so the
    /// bar animates instead of flashing. Cancel keeps partial results.
    private func postArchiveTranslationProgress(processed: Int, total: Int) {
        guard case let .running(request, progress) = archiveTranslationJob.activity else { return }
        let language = TargetLanguage(code: request.lang)
        toasts.post(
            key: ToastKey.archiveTranslation, style: .info,
            title: "Translating to \(language.nativeName)…",
            body: "\(progress.kind.markerName) · "
                + "\(processed)/\(ArchivedSessionSummary.sentenceCountText(total))",
            action: ToastCenter.Action(label: "Cancel") { [weak self] in
                self?.cancelArchiveTranslation()
            },
            progress: ToastCenter.ToastProgress(done: processed, total: total)
        )
    }

    /// The same card, morphed into the run's summary: the all-success
    /// variant auto-dismisses; a failure summary carries the retry action
    /// over exactly the failed sentences.
    private func postArchiveTranslationSummary(translated: Int, failedIndexes: [Int]) {
        guard let run = archiveTranslationJob.lastRun else { return }
        let language = TargetLanguage(code: run.request.lang)
        if failedIndexes.isEmpty {
            toasts.post(
                key: ToastKey.archiveTranslation, style: .info,
                title: "Archive translation finished",
                body: "Translated \(ArchivedSessionSummary.sentenceCountText(translated)) "
                    + "to \(language.nativeName)"
            )
        } else {
            toasts.post(
                key: ToastKey.archiveTranslation, style: .info,
                title: "Archive translation finished",
                body: "\(translated)/\(run.total) translated to "
                    + "\(language.nativeName) · \(failedIndexes.count) failed",
                action: ToastCenter.Action(label: "Retry failed sentences") { [weak self] in
                    self?.retryFailedArchiveTranslation()
                }
            )
        }
    }
}
