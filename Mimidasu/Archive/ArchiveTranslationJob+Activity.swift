// The job's present tense and its history record, kept beside the scoped
// read every per-session surface uses: `Activity` answers what the job is
// doing right now — idle, claimed for a session, or running with progress —
// while `LastRun` keeps the last begun run's inputs and final counts.

extension ArchiveTranslationJob {
    /// What the job is doing right now.
    enum Activity: Equatable, Sendable {
        /// No run claimed: the slot is free.
        case idle
        /// Claimed for `request`: from the synchronous claim through engine
        /// resolution. The session and language are visible; nothing runs.
        case claimed(Request)
        /// The walk executes for `request`; `progress` carries the resolved
        /// kind and the processed/total counts.
        case running(Request, progress: RunProgress)
    }

    /// One running step's facts.
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
        case let .claimed(request) where request.sessionID == sessionID:
            .claimed(request)
        case let .running(request, progress) where request.sessionID == sessionID:
            .running(request, progress: progress)
        default:
            .idle
        }
    }
}

extension ArchiveTranslationJob.Activity {
    /// The run's request while claimed or running; nil when idle.
    var request: ArchiveTranslationJob.Request? {
        switch self {
        case .idle: nil
        case let .claimed(request): request
        case let .running(request, _): request
        }
    }

    /// Live progress while the walk executes; nil while claimed or idle.
    var progress: ArchiveTranslationJob.RunProgress? {
        guard case let .running(_, progress) = self else { return nil }
        return progress
    }

    /// True only while the walk executes.
    var isRunning: Bool {
        if case .running = self {
            return true
        }
        return false
    }
}
