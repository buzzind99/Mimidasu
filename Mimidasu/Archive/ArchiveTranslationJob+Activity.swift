// The job's transition state and its history record, kept beside the scoped
// read every per-session surface uses: `Activity` answers whether the job is
// idle, claimed, or running for a session — while the separate `runProgress`
// carries the per-tick counts — and `LastRun` keeps the last begun run's
// inputs and final counts.

extension ArchiveTranslationJob {
    /// The run's public identity while claimed or running. Deliberately
    /// excludes the run inputs; views must never depend on the sentence
    /// payload.
    struct RunStatus: Equatable, Sendable {
        let sessionID: Int64
        let lang: String
        let engine: RetranslateEngine
    }

    /// The job's transition state. Per-tick progress lives in `runProgress`;
    /// assigning this property only happens on idle → claimed → running →
    /// idle transitions.
    enum Activity: Equatable, Sendable {
        /// No run claimed: the slot is free.
        case idle
        /// Claimed for `status`: from the synchronous claim through engine
        /// resolution. The session and language are visible; nothing runs.
        case claimed(RunStatus)
        /// The walk executes for `status`; the per-sentence counts live in
        /// the job's `runProgress`.
        case running(RunStatus)
    }

    /// One running step's facts. Published separately from `Activity`, so a
    /// per-tick update never republishes the transition value.
    struct RunProgress: Equatable, Sendable {
        let kind: TranslationEngineKind
        let processed: Int
        let total: Int
    }

    /// The last begun run's record: inputs, resolved kind, final counts.
    struct LastRun: Equatable, Sendable {
        let request: Request
        let kind: TranslationEngineKind
        let total: Int
        var processed: Int
    }

    /// The activity as it concerns `sessionID`: `.idle` unless the claimed
    /// or running run targets that session.
    func activity(for sessionID: Int64) -> Activity {
        switch activity {
        case let .claimed(status) where status.sessionID == sessionID:
            .claimed(status)
        case let .running(status) where status.sessionID == sessionID:
            .running(status)
        default:
            .idle
        }
    }

    /// True while claimed or running, regardless of session.
    var isBusy: Bool {
        activity.isBusy
    }

    /// The caller-facing scoped gate.
    func isBusy(sessionID: Int64, lang: String? = nil) -> Bool {
        activity.isBusy(sessionID: sessionID, lang: lang)
    }
}

extension ArchiveTranslationJob.RunStatus {
    init(_ request: ArchiveTranslationJob.Request) {
        self.init(
            sessionID: request.sessionID,
            lang: request.lang,
            engine: request.engine
        )
    }
}

extension ArchiveTranslationJob.Activity {
    /// The run's identity while claimed or running; nil when idle.
    var runStatus: ArchiveTranslationJob.RunStatus? {
        switch self {
        case .idle: nil
        case let .claimed(status): status
        case let .running(status): status
        }
    }

    /// True while claimed or running.
    var isBusy: Bool {
        self != .idle
    }

    /// True only while the walk executes.
    var isRunning: Bool {
        if case .running = self {
            return true
        }
        return false
    }

    /// The one scoped busy rule. A non-nil `lang` additionally matches the
    /// run's language; a nil `lang` matches any language.
    func isBusy(sessionID: Int64, lang: String? = nil) -> Bool {
        guard let status = runStatus, status.sessionID == sessionID else { return false }
        guard let lang else { return true }
        return status.lang == lang
    }
}
