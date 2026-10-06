import Foundation
import Translation

/// How a failure should be treated by the toast system: transient failures
/// surface as a dismissable yellow card (the condition usually clears on
/// retry), permanent ones as a non-dismissable red card carrying the fix
/// action. Classified in the queue where the error identity is known.
enum TranslationFailureSeverity: Equatable, Sendable {
    case transient
    case permanent
}

/// Translation status surfaced to the UI (non-blocking).
enum TranslationStatus: Equatable {
    case idle
    case ready
    case translating
    /// An external engine is retrying a transient failure; the payload is
    /// the footer copy ("External translation failed, N retries left").
    case retrying(String)
    /// The external engine failed out for good and the session latched onto
    /// Apple on-device; the payloads are the footer copy explaining why and
    /// the failure's severity (carried through from the triggering
    /// `.unavailable` for the toast system).
    case degraded(String, TranslationFailureSeverity)
    /// The engine failed out and nothing is translating; the payloads are
    /// the user-facing copy and the failure's severity.
    case unavailable(String, TranslationFailureSeverity)
}

/// Translates finalized sentences ja→the configured target, in order.
///
/// `translate` throws when called concurrently, so all work is funneled
/// through this single worker loop. Untranslated sentences
/// live in the plain `pending` array — always observable on the main actor —
/// and the worker consumes them FIFO. Output order matches input order for a
/// clean run; the two re-ordering paths are a failed batch, which re-queues at
/// the head, and a manual retry (`retranslate`), which re-queues at the tail —
/// so a retried line's result can land after later lines. Sentences are keyed
/// by index; timestamps travel with the sentence. Repeats of already-translated
/// sentences are served from a cache at `enqueue` time and bypass the worker
/// entirely.
///
/// The class is `@MainActor` so that `enqueue` is a synchronous call from the
/// sentence pipeline (also on the main actor): by the time `stop` calls
/// `drain`, every enqueued sentence is visible in `pending`. The worker loop
/// suspends on the engine's `translate` without blocking the main actor.
///
/// The engine is injected at `run(with:)`: the on-device session arrives via
/// `AppleSessionEngine` (see `TranslationSessionHost`, which also drives the
/// one-time OS language-pack download prompt); cloud engines enter through
/// the same seam.
@MainActor
final class TranslationQueue {
    private(set) var status: TranslationStatus = .idle

    /// BCP-47 code stamped onto every `SentenceTranslation` this session
    /// produces. `AppModel` sets it when attaching an engine (reading the
    /// selected target); the default keeps pre-attach runs and tests
    /// coherent with the previous fixed English behavior.
    var targetLangCode = "en"

    /// The single source of truth for untranslated sentences, FIFO order.
    /// Deliberately plain state, not a buffered AsyncStream: a stream's
    /// internal buffer is invisible to `drain` and silently discarded when
    /// the task is cancelled, which would lose the final sentences on stop.
    private var pending: [Sentence] = []
    /// Wake-up signal for the worker loop (carries no data).
    private var wake: AsyncStream<Void>.Continuation?
    /// Guards the reentrancy window between a cancelled run unwinding and a
    /// fresh run starting: only the run holding the current generation may
    /// clear `wake` or update `inFlight`.
    private var generation = 0
    /// Bumped only at a session boundary (`resetForNewSession`). A batch that
    /// is airborne across that boundary has lost its destination — sentence
    /// indexes restart at 0 in the next session — so `pump` compares the
    /// epoch it captured per batch against this and drops the batch's
    /// results and re-queue once they differ. Within a session (engine swap,
    /// Reconnect) the epoch holds and the designed replay stays intact.
    private var sessionEpoch = 0
    /// The generation token of the run whose batch call is suspended inside
    /// the worker, or nil when nothing is airborne. Owned by the *flight*,
    /// not the run: a stale run retires its own token on resolution but
    /// never touches a newer run's, and a newer run is never made to wait on
    /// a stale one — the two failure modes a plain Bool cannot tell apart.
    private var inFlightToken: Int?
    /// True while a `session.translate`/batch call is suspended inside the worker.
    var inFlight: Bool {
        inFlightToken != nil
    }

    /// Sentence ids popped into the worker's current batch — mid-flight,
    /// therefore invisible to `pending`. The manual retry consults these to
    /// stay a no-op while a translation is airborne: a re-queued copy would
    /// translate twice (replace on the first result, append on the second).
    /// Every id in a batch leaves by the time the batch resolves: each result
    /// drops its own as it lands, and the `catch` sweeps the rest, so the set
    /// cannot strand an index once the sentence has been dealt with.
    private var translatingIDs: Set<Int> = []

    /// App-run-scoped cache: repeated sentences ("よろしくお願いします"…) skip
    /// the session round-trip entirely — the result posts at `enqueue` time.
    /// NSCache's default is UNLIMITED, so `countLimit` is what bounds long
    /// sessions; entries are ≤42-char sentences (`SentenceBuffer.maxChars`).
    private let cache: NSCache<NSString, TranslationBox> = {
        let cache = NSCache<NSString, TranslationBox>()
        cache.countLimit = 200
        return cache
    }()

    /// Called when a translation completes (main-actor context).
    private var onResult: ((Int, SentenceTranslation) -> Void)?
    private var onStatus: ((TranslationStatus) -> Void)?
    /// Called when a run attaches or releases its engine (main-actor
    /// context). `TranslationQueue` is not `@Observable`, so `AppModel`
    /// mirrors this into observable state for the transcript's retry gate.
    private var onWorkerChanged: ((Bool) -> Void)?

    /// Wire callbacks (invoked synchronously on the main actor).
    func setHandlers(
        result: @escaping (Int, SentenceTranslation) -> Void,
        status: @escaping (TranslationStatus) -> Void,
        workerChanged: @escaping (Bool) -> Void = { _ in }
    ) {
        onResult = result
        onStatus = status
        onWorkerChanged = workerChanged
    }

    /// The engine is injected at run start; a new run swaps it wholesale.
    private var engine: (any TranslationEngine)?

    /// SwiftUI hands us a session whenever `.translationTask` (re)fires;
    /// external engines enter through the same seam from `AppModel`.
    func run(with engine: any TranslationEngine) async {
        generation += 1
        let token = generation
        self.engine = engine
        onWorkerChanged?(true)
        setStatus(.ready)
        let (wakeStream, continuation) = AsyncStream<Void>.makeStream()
        wake = continuation
        defer {
            // A stale run (cancelled after a newer one entered) must not
            // clobber the live worker — guard by generation token. `pending`
            // deliberately survives so the next run replays it.
            if token == generation {
                wake = nil
                inFlightToken = nil
                translatingIDs.removeAll()
                self.engine = nil
                onWorkerChanged?(false)
            }
        }

        // Replay anything that arrived before a session existed.
        guard await pump(token: token) else { return }

        // Sleep until signalled; buffered wakeups are harmless no-ops.
        for await _ in wakeStream {
            guard token == generation else { return }
            guard await pump(token: token) else { return }
        }
    }

    /// Translate everything currently in `pending`, FIFO. Returns `false`
    /// when this run must exit (stale generation, cancellation, error).
    /// Bursts (a pause flushes several finals at once) drain in batched
    /// round-trips instead of one call per sentence.
    private func pump(token: Int) async -> Bool {
        while !pending.isEmpty {
            guard token == generation, let engine else { return false }
            // Take a bounded slice: visible progress and a bounded
            // round-trip, while bursts still amortize the engine call.
            let batch = Array(pending.prefix(engine.preferredBatchSize))
            pending.removeFirst(batch.count)
            translatingIDs.formUnion(batch.map(\.id))
            setStatus(.translating)
            inFlightToken = token
            // The session this batch belongs to. `resetForNewSession` bumps
            // the epoch at the session boundary; a batch airborne across it
            // has lost its destination (indexes restart at 0 in the next
            // session) and is dropped at resolution below.
            let epoch = sessionEpoch
            do {
                // `deliver` is deliberately NOT generation-guarded: the batch
                // left `pending` before the flight, so dropping a stale run's
                // results would lose those sentences outright. The shared-state
                // writes are a different matter — a live run owns them, and a
                // dead run clobbering `inFlight` would let `drain` return early
                // (cutting the session tail off) while a stale `.ready` would
                // dismiss a failure card for an engine that is still broken.
                for (sentence, pair) in try await translateBatch(batch, using: engine) {
                    // A session boundary mid-flight retires the whole batch:
                    // its results have no correct row any more, and landing
                    // them would write one session's translations onto the
                    // next session's rows of the same indexes.
                    guard epoch == sessionEpoch else { break }
                    // Drop the id as each result lands, so a retry for a
                    // delivered sentence is a fresh request, not a no-op.
                    translatingIDs.remove(sentence.id)
                    deliver(sentence, pair)
                }
                if token == generation {
                    setStatus(.ready)
                }
            } catch {
                // The flight is over whoever owns it — including a stale
                // run's, which would otherwise leave `inFlight` stuck true
                // and stall `drain` on every later stop.
                if inFlightToken == token {
                    inFlightToken = nil
                }
                recoverFailedBatch(batch, error: error, token: token, engine: engine, epoch: epoch)
                return false
            }
            if inFlightToken == token {
                inFlightToken = nil
            }
        }
        return true
    }

    /// Re-queues a failed batch for the next run — unless a session boundary
    /// passed mid-flight, in which case the batch is dropped: its sentences
    /// belong to a discarded transcript (indexes restart at 0 in the next
    /// session), and re-queuing them would replay old-session indexes onto
    /// new-session rows. A stale run that did re-queue nudges the newer run,
    /// which owns `wake` now, so the batch replays.
    private func recoverFailedBatch(
        _ batch: [Sentence], error: Error, token: Int,
        engine: any TranslationEngine, epoch: Int
    ) {
        guard epoch == sessionEpoch else { return }
        translatingIDs.subtract(batch.map(\.id))
        pending.insert(contentsOf: batch, at: 0)
        if token == generation {
            if error is CancellationError {
                setStatus(.idle)
            } else {
                setStatus(
                    .unavailable(
                        Self.describe(error),
                        Self.severity(of: error, engine: engine)
                    )
                )
            }
        } else {
            wake?.yield(())
        }
    }

    /// Enqueue a finalized sentence for translation. A repeat of an
    /// already-translated sentence posts its cached result synchronously and
    /// never enters `pending` (or the session round-trip).
    ///
    /// Empty/whitespace sentences are dropped here: they have nothing
    /// to translate, so sending them to a provider wastes a round-trip.
    /// They keep their transcript row untranslated.
    func enqueue(_ sentence: Sentence) {
        guard !sentence.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        if let hit = cache.object(forKey: sentence.text as NSString) {
            onResult?(sentence.index, hit.value)
            return
        }
        pending.append(sentence)
        wake?.yield(())
    }

    /// Retry after a failure: clears error state; the UI re-activates the
    /// configuration, `.translationTask` fires again, and `run(with:)`
    /// replays the backlog.
    func resetForRetry() {
        setStatus(.idle)
    }

    /// Session boundary: drops the untranslated backlog. `pending` outlives a
    /// *run* by design — an engine swap (the latched Apple fallback, Reconnect)
    /// must replay onto the new engine — but it must not outlive a *session*:
    /// `Sentence.index` restarts at 0 in each one, and the transcript that
    /// would have received these results is discarded at the same boundary, so
    /// a carried backlog has no correct destination. It would only ever append
    /// one session's translation onto the next session's row of the same index.
    /// `translatingIDs` goes with it: an id left by a torn-down run would
    /// otherwise read as "airborne" and disable retries for that index forever.
    /// The epoch bump retires any batch already *airborne* across the boundary
    /// (it left `pending` before its flight, so the clears above cannot reach
    /// it): `pump` drops its results and skips its re-queue once epochs
    /// differ. The app-run cache stays — a sentence repeated in a new session
    /// is exactly what it is for.
    func resetForNewSession() {
        pending.removeAll()
        translatingIDs.removeAll()
        sessionEpoch += 1
    }

    /// True while a run holds an engine, i.e. a worker that would service a
    /// fresh `enqueue`. `pending` survives a run by design, so "queued" alone
    /// does not mean "will be delivered": the manual retry gates on this, or a
    /// click made before `.translationTask` fires (or while the language pack
    /// is absent) would park a dimmed row behind a worker that does not exist.
    var hasWorker: Bool {
        engine != nil
    }

    /// True while the sentence is already being handled: mid-flight in the
    /// worker's current batch, or queued behind a live worker (engine
    /// attached — it nils when a run exits). The manual retry must no-op
    /// for such sentences, so a click can never double-translate a line.
    /// A sentence parked in `pending` with no worker (a failed-out
    /// backlog) is *not* awaiting — retrying it is the user's explicit
    /// re-run intent.
    func isAwaitingTranslation(_ sentence: Sentence) -> Bool {
        translatingIDs.contains(sentence.id)
            || (engine != nil && pending.contains { queued in queued.id == sentence.id })
    }

    /// Manual retry for one sentence (the transcript row's hover button).
    /// No-op while `isAwaitingTranslation` holds — the sentence is already
    /// translating, and a second copy would fly twice (replace on the
    /// first result, append on the second). Otherwise: any stale `pending`
    /// copy (a failed batch re-queues at the front) is dropped, the cache
    /// entry is evicted (it would otherwise serve the old translation
    /// synchronously), and the sentence re-enters the normal worker path.
    func retranslate(_ sentence: Sentence) {
        guard !isAwaitingTranslation(sentence) else { return }
        pending.removeAll { queued in queued.id == sentence.id }
        cache.removeObject(forKey: sentence.text as NSString)
        enqueue(sentence)
    }

    /// Reports an external engine's transient-retry progress to the footer
    /// (wired from the engine's `onRetry`, hopped to the main actor). The
    /// retry hop is asynchronous, so a late report can land outside the
    /// live batch window — only `.translating`/`.retrying` accept it. A
    /// report arriving after the batch resolved is stale: it must not
    /// clobber a post-batch `.ready`/`.idle`, a latched `.degraded`, or a
    /// terminal `.unavailable`.
    func noteRetry(_ progress: RetryProgress) {
        switch status {
        case .translating, .retrying:
            setStatus(.retrying(Self.retryCopy(attemptsLeft: progress.attemptsLeft)))
        case .idle, .ready, .unavailable, .degraded:
            return
        }
    }

    private static func retryCopy(attemptsLeft: Int) -> String {
        "External translation failed, \(attemptsLeft) retries left"
    }

    /// Waits until `pending` is empty and no translation is in flight,
    /// bounded by `timeout`. Returns `true` when everything drained in time.
    /// Used on stop so the final sentences finish translating before teardown.
    /// `pending` is plain main-actor state, so this check observes reality.
    /// The deadline is monotonic (`ContinuousClock`) — wall-clock `Date`
    /// would skew on NTP/timezone/manual clock changes.
    func drain(timeout: TimeInterval) async -> Bool {
        let deadline = ContinuousClock.now + Duration.seconds(timeout)
        while !pending.isEmpty || inFlight {
            // A failed translator will never drain — don't make stop hang.
            if case .unavailable = status {
                return false
            }
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return true
    }

    /// Translates one batch in a single engine round-trip (batches amortize
    /// the call during bursts). Returns sentences paired with translations;
    /// each result is stamped with the session's target language code.
    ///
    /// A count mismatch is a failed batch, not a short answer: pairing with
    /// `zip` would silently drop the unmatched sentences, and — because their
    /// ids would never be released — leave them permanently un-retryable.
    /// Throwing instead sends the whole batch down the failure path, which
    /// re-queues it at the front of `pending` for the next run.
    private func translateBatch(
        _ batch: [Sentence], using engine: any TranslationEngine
    ) async throws -> [(Sentence, SentenceTranslation)] {
        let translations = try await engine.translate(batch.map(\.text))
        guard translations.count == batch.count else {
            throw TranslationEngineError.badResponse(
                "Expected \(batch.count) translations, got \(translations.count)"
            )
        }
        return zip(batch, translations).map { sentence, text in
            (sentence, SentenceTranslation(lang: targetLangCode, text: text))
        }
    }

    /// Posts a result and seeds the repeat-sentence cache.
    private func deliver(_ sentence: Sentence, _ pair: SentenceTranslation) {
        cache.setObject(TranslationBox(pair), forKey: sentence.text as NSString)
        onResult?(sentence.index, pair)
    }

    private func setStatus(_ newStatus: TranslationStatus) {
        status = newStatus
        onStatus?(newStatus)
    }

    private static func describe(_ error: TranslationEngineError) -> String {
        switch error {
        case .invalidKey:
            "Invalid API key. Check the key in Settings, then reconnect."
        case .quotaExceeded:
            "The provider's API quota is exhausted. Retry later or switch provider."
        case .rateLimited:
            "The provider is rate limiting requests. Retry shortly."
        case let .serverError(code):
            "Provider server error (\(code)). Retry shortly."
        case let .badResponse(detail):
            "The provider returned an unexpected response: \(detail)"
        case .network:
            "Network error reaching the provider. Check the connection, then reconnect."
        case .cancelled:
            "Translation was cancelled."
        }
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case let engineError as TranslationEngineError:
            return describe(engineError)
        case let translationError as TranslationError:
            if #available(macOS 26.0, *) {
                switch translationError {
                case TranslationError.notInstalled:
                    return "The ja→en translation pack is not installed. Allow the download "
                        + "prompt (or install it in System Settings), then reconnect."
                default:
                    break
                }
            }
            return translationError.errorDescription ?? "Translation failed."
        default:
            return "Translation failed: \(error.localizedDescription)"
        }
    }

    /// Classifies a failure for the toast system. `.invalidKey` /
    /// `.quotaExceeded` are fixed-contract permanent; `.badResponse` follows
    /// the engine (`transientBadResponse` — LLM output may improve on
    /// re-ask, a fixed-contract API never does); everything the ladder
    /// treats as retryable is transient. Note: "transient" here means a
    /// yellow toast, not "still retrying" — by the time an LLM
    /// `.badResponse` reaches `.unavailable`, its own ladder already
    /// exhausted its retries.
    private static func severity(
        of error: Error, engine: any TranslationEngine
    ) -> TranslationFailureSeverity {
        switch TransientRetryLadder.engineError(of: error) {
        case .invalidKey, .quotaExceeded:
            .permanent
        case .badResponse:
            engine.transientBadResponse ? .transient : .permanent
        case .rateLimited, .serverError, .network, .cancelled:
            .transient
        }
    }
}

/// NSCache stores class instances only; boxes the value-type translation.
private final class TranslationBox {
    let value: SentenceTranslation

    init(_ value: SentenceTranslation) {
        self.value = value
    }
}
