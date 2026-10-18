import Foundation

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
        archiveTranslationJob.resolveEngine = { [weak self] provider, target in
            guard let self else { return .cancelled }
            return await retranslate.resolveArchiveJobEngine(
                selection: archiveJobSelection(for: provider), target: target
            )
        }
        archiveTranslationJob.land = { [weak self] index, translation in
            self?.landArchiveTranslation(index: index, translation: translation)
        }
        archiveTranslationJob.onEvent = { [weak self] event in
            self?.handleArchiveTranslationEvent(event)
        }
    }

    // MARK: - Commands

    /// Starts a bulk run for one language through `provider` — the provider
    /// picker's action and the cloud disclosure's confirm callback. The
    /// scope derives from the language's completeness: missing sentences
    /// fill, a complete language re-translates every sentence as a fresh
    /// full pass. A no-op while a run is claimed or no archive is open.
    func beginArchiveTranslation(provider: TranslationProvider, lang: String) {
        beginArchiveTranslation(provider: provider, lang: lang, scope: nil)
    }

    /// The failure summary's Retry action: re-runs the same language and
    /// provider over exactly the failed sentences, in index order, without
    /// re-raising the cloud disclosure.
    func retryFailedArchiveTranslation() {
        guard !archiveTranslationJob.isActive,
              let previous = archiveTranslationJob.currentRun,
              !archiveTranslationJob.failureIndexes.isEmpty
        else { return }
        beginArchiveTranslation(
            provider: previous.provider,
            lang: previous.lang,
            scope: .failedOnly(Set(archiveTranslationJob.failureIndexes))
        )
    }

    /// Stops the run in flight: no new sentence starts, whatever is
    /// airborne still lands (partial results stay stored), and the toast
    /// dismisses — a canceled run posts no summary.
    func cancelArchiveTranslation() {
        guard archiveTranslationJob.isActive else { return }
        archiveTranslationJob.cancel()
        toasts.dismiss(key: ToastKey.archiveTranslation)
    }

    /// The sentences a run for `lang` would send — the provider picker's
    /// count line and the pending disclosure's body: the missing count, or
    /// the full sentence count when the language is complete (a Retranslate
    /// re-sends every sentence). Nil with no archive open.
    func archiveTranslationSendCount(lang: String) -> Int? {
        guard let summary = openArchive?.summary else { return nil }
        let total = summary.sentenceCount
        let translated = summary.languageCount(for: lang)?.translated ?? 0
        return translated >= total && total > 0 ? total : max(total - translated, 0)
    }

    /// True when the opened archive's `lang` has a translation on every
    /// sentence — the picker's Retranslate mode.
    func archiveLanguageIsComplete(_ lang: String) -> Bool {
        guard let summary = openArchive?.summary, summary.sentenceCount > 0 else { return false }
        let translated = summary.languageCount(for: lang)?.translated ?? 0
        return translated >= summary.sentenceCount
    }

    // MARK: - Internals

    /// The one start path: begin (the derived scope) and retry-failed (the
    /// explicit failure set) both land here.
    private func beginArchiveTranslation(
        provider: TranslationProvider, lang: String, scope: ArchiveTranslationJob.Scope?
    ) {
        guard let archive = openArchive else { return }
        guard archiveTranslationJob.prepare() else { return }
        let translated = Self.translatedIndexes(in: archive.entries, lang: lang)
        let resolvedScope = scope
            ?? (translated.count >= archive.entries.count && !archive.entries.isEmpty
                ? .all : .missing)
        let request = ArchiveTranslationJob.Request(
            sessionID: archive.id,
            lang: lang,
            provider: provider,
            sentences: archive.entries.map { entry in entry.sentence },
            translated: translated,
            scope: resolvedScope
        )
        Task { [archiveTranslationJob] in
            await archiveTranslationJob.run(request)
        }
    }

    /// The run's Apple model: the effective re-translate selection when it
    /// names an Apple model (its known-unavailable degrade included), else
    /// Apple-fast — the archive route's mapping for `.session` and external
    /// selections. The picker's provider, never the settings selection,
    /// decides the branch.
    private func archiveJobSelection(for provider: TranslationProvider) -> RetranslateEngine {
        guard provider == .apple else {
            return RetranslateEngine(provider: provider) ?? .appleFast
        }
        switch retranslate.effectiveRetranslateSelection {
        case .appleFast, .appleHighFidelity:
            return retranslate.effectiveRetranslateSelection
        case .session, .google, .deepl, .openrouter:
            return .appleFast
        }
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

    /// Lands one bulk result: the store upsert keyed by the run's captured
    /// session id (so an airborne result at close time still persists), the
    /// row swap only while the pane still shows that archive, and the
    /// revision bump every archive surface re-reads through.
    private func landArchiveTranslation(index: Int, translation: SentenceTranslation) {
        guard let sessionID = archiveTranslationJob.currentRun?.sessionID else { return }
        archive.upsert(translation: translation, index: index, session: sessionID)
        if openArchive?.id == sessionID, let at = entryPositionBySentence[index] {
            entries[at].replaceTranslation(translation)
        }
        if openArchive?.id == sessionID {
            refreshOpenArchiveLanguages()
        }
        archiveRevision &+= 1
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
            // The lane's unavailable copy, verbatim: the two retry surfaces
            // must not drift.
            toasts.post(
                key: ToastKey.retranslate, style: .yellowAuto,
                title: "Re-translate unavailable", body: reason
            )
        }
    }

    /// The keyed progress card: per-key dedup replaces it in place, so the
    /// bar animates instead of flashing. Cancel keeps partial results.
    private func postArchiveTranslationProgress(processed: Int, total: Int) {
        guard let request = archiveTranslationJob.currentRun else { return }
        let language = TargetLanguage(code: request.lang)
        toasts.post(
            key: ToastKey.archiveTranslation, style: .info,
            title: "Translating to \(language.nativeName)…",
            body: "\(request.provider.displayName) · \(processed)/\(total) sentences",
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
        guard let request = archiveTranslationJob.currentRun else { return }
        let language = TargetLanguage(code: request.lang)
        if failedIndexes.isEmpty {
            toasts.post(
                key: ToastKey.archiveTranslation, style: .info,
                title: "Archive translation finished",
                body: "Translated \(translated) sentences to \(language.nativeName)"
            )
        } else {
            toasts.post(
                key: ToastKey.archiveTranslation, style: .info,
                title: "Archive translation finished",
                body: "\(translated)/\(archiveTranslationJob.total) translated · "
                    + "\(failedIndexes.count) failed",
                action: ToastCenter.Action(label: "Retry failed sentences") { [weak self] in
                    self?.retryFailedArchiveTranslation()
                }
            )
        }
    }
}
