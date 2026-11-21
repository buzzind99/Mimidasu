/// A strictly ordered writer for the live session's archive persistence.
///
/// The live path must never run SQLite on the main actor, but its writes have
/// to land in one exact order: the first sentence's append creates the
/// `recording` row, and the pause sync and translation upserts that follow
/// only have a row to write to because that append ran first. One
/// `AsyncStream` of commands consumed by a single detached task is the
/// simplest mechanism that guarantees it — `yield` is a non-blocking call
/// from the main actor, the consumer handles commands in submission order,
/// and no task is spawned per sentence. The `.drain` command carries a
/// continuation, so a caller can await "everything enqueued before this point
/// has landed" without a second synchronization primitive.
///
/// The writer owns the recording row id: the first successful append resolves
/// it, later commands write against it, and the main actor learns it only
/// through the adoption callback. A lost write reports through the failure
/// callback and stops the writer for the rest of the session (a reset starts
/// the next one), so a latched session cannot keep writing into a row whose
/// earlier writes are gone. Both callbacks are invoked on the main actor from
/// inside the command loop, which is what lets `drain()` promise that the
/// caller observes the adopted id and any reported failure before it resumes.
///
/// The live upsert writes straight through `ArchiveStore`: a `recording` row
/// is never listed in the archive window and is never the open summary, so
/// `ArchiveProjection` holds no cached copy of it to refresh. Archive-mode and
/// bulk-run writes keep going through `AppModel.writeBackTranslation`, whose
/// projection refresh is real.
final class ArchiveWriteLane: Sendable {
    /// One unit of work, processed in submission order. `reset` forgets the
    /// previous session's row id and failure latch; `drain` is the ordering
    /// barrier.
    enum Command: Sendable {
        case append(sentence: Sentence, metadata: SessionMetadata)
        case upsert(translation: SentenceTranslation, index: Int)
        case syncPaused(pausedMS: Int)
        case reset
        case drain(CheckedContinuation<Void, Never>)
    }

    /// The owner's main-actor observers, set once by `bind`. Main-actor
    /// isolated, so the consumer reaches them only inside its callback hop.
    @MainActor
    private final class HandlerBox {
        var recordingIDAdopted: (@MainActor @Sendable (Int64) -> Void)?
        var writeFailed: (@MainActor @Sendable () -> Void)?
    }

    private let store: ArchiveStore
    private let commands: AsyncStream<Command>.Continuation
    private let handlers: HandlerBox
    /// Held so the consumer lives exactly as long as the lane: it ends when
    /// the continuation above is released.
    private let writer: Task<Void, Never>

    @MainActor
    init(store: ArchiveStore) {
        self.store = store
        let (stream, commands) = AsyncStream.makeStream(of: Command.self)
        self.commands = commands
        let handlers = HandlerBox()
        self.handlers = handlers
        // `.utility`: archive persistence is background work that only the
        // stop-time drain waits on, never a piece of the live transcript.
        writer = Task.detached(priority: .utility) { [store, handlers] in
            await ArchiveWriteLane.run(stream: stream, store: store, handlers: handlers)
        }
    }

    /// Binds the owner's main-actor observers. Called once, before any
    /// command is enqueued.
    @MainActor
    func bind(
        recordingIDAdopted: @escaping @MainActor @Sendable (Int64) -> Void,
        writeFailed: @escaping @MainActor @Sendable () -> Void
    ) {
        handlers.recordingIDAdopted = recordingIDAdopted
        handlers.writeFailed = writeFailed
    }

    // MARK: - Producer side (non-blocking, main actor)

    /// Queues one sentence append.
    @MainActor
    func append(sentence: Sentence, metadata: SessionMetadata) {
        commands.yield(.append(sentence: sentence, metadata: metadata))
    }

    /// Queues one landed translation's upsert.
    @MainActor
    func upsert(translation: SentenceTranslation, index: Int) {
        commands.yield(.upsert(translation: translation, index: index))
    }

    /// Queues the live row's accumulated paused time.
    @MainActor
    func syncPaused(pausedMS: Int) {
        commands.yield(.syncPaused(pausedMS: pausedMS))
    }

    /// Forgets the previous session before the next one's first append: the
    /// writer drops the old row id and the failure latch.
    @MainActor
    func reset() {
        commands.yield(.reset)
    }

    /// Awaits every command enqueued before this call; commands enqueued
    /// after it are not covered.
    func drain() async {
        await withCheckedContinuation { continuation in
            commands.yield(.drain(continuation))
        }
    }

    // MARK: - Consumer side (one detached task)

    /// The writer's session-local state: the row every write targets and
    /// whether a lost write already ended the session's writes.
    private struct WriterState {
        var recordingID: Int64?
        var failed = false
    }

    private static func run(
        stream: AsyncStream<Command>,
        store: ArchiveStore,
        handlers: HandlerBox
    ) async {
        var state = WriterState()
        for await command in stream {
            switch command {
            case let .append(sentence, metadata):
                state = await append(
                    sentence: sentence, metadata: metadata,
                    state: state, store: store, handlers: handlers
                )
            case let .upsert(translation, index):
                state = await upsert(
                    translation: translation, index: index,
                    state: state, store: store, handlers: handlers
                )
            case let .syncPaused(pausedMS):
                syncPaused(pausedMS: pausedMS, state: state, store: store)
            case .reset:
                state = WriterState()
            case let .drain(continuation):
                continuation.resume()
            }
        }
    }

    private static func append(
        sentence: Sentence,
        metadata: SessionMetadata,
        state: WriterState,
        store: ArchiveStore,
        handlers: HandlerBox
    ) async -> WriterState {
        guard !state.failed else { return state }
        guard let resolved = store.append(
            sentence: sentence, sessionID: state.recordingID, metadata: metadata
        ) else {
            await reportFailure(handlers)
            return WriterState(recordingID: state.recordingID, failed: true)
        }
        // Only the append that created the row changes the id; later appends
        // reuse the one the main actor already mirrors.
        guard state.recordingID == nil else { return state }
        await adopt(recordingID: resolved, handlers: handlers)
        return WriterState(recordingID: resolved)
    }

    private static func upsert(
        translation: SentenceTranslation,
        index: Int,
        state: WriterState,
        store: ArchiveStore,
        handlers: HandlerBox
    ) async -> WriterState {
        guard !state.failed, let recordingID = state.recordingID else { return state }
        guard store.upsert(
            translation: translation, index: index, session: recordingID
        ) else {
            await reportFailure(handlers)
            return WriterState(recordingID: recordingID, failed: true)
        }
        return state
    }

    /// Pause bookkeeping stays best-effort: a lost paused-time write costs a
    /// duration estimate, not the session's rows, so it never latches.
    private static func syncPaused(
        pausedMS: Int,
        state: WriterState,
        store: ArchiveStore
    ) {
        guard !state.failed, let recordingID = state.recordingID else { return }
        store.syncPaused(session: recordingID, pausedMS: pausedMS)
    }

    /// Main-actor hop for the resolved row id. Awaiting it inside the loop is
    /// what orders the adoption ahead of a later `.drain` resuming.
    private static func adopt(
        recordingID: Int64, handlers: HandlerBox
    ) async {
        await MainActor.run {
            handlers.recordingIDAdopted?(recordingID)
        }
    }

    /// Main-actor hop for the session's first lost write, delivered under the
    /// same ordering rule as the adoption.
    private static func reportFailure(_ handlers: HandlerBox) async {
        await MainActor.run {
            handlers.writeFailed?()
        }
    }
}
