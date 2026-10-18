import Foundation
import Observation

/// The bulk archive-translation job: one engine per run, walking a stored
/// session's sentences in index order — filling a language's missing
/// translations or re-running a complete one as a fresh full pass. The job
/// is a main-actor state machine whose engine resolver and landing sink are
/// injected closures, so it touches neither the store, the coordinators,
/// nor SwiftUI; the app model wires all three.
@Observable
@MainActor
final class ArchiveTranslationJob {
    /// What a run translates.
    enum Scope: Equatable, Sendable {
        /// The indexes without a translation for the run's language — the
        /// fill-missing mode; a re-run resumes for free because landed rows
        /// drop out.
        case missing
        /// Every index, a fresh full pass (Retranslate).
        case all
        /// Exactly the reported failures, in index order (Retry failed).
        case failedOnly(Set<Int>)
    }

    /// One run's inputs, captured at start. `translated` is the snapshot of
    /// existing translations for `lang` — what `.missing` filters by.
    struct Request: Equatable, Sendable {
        let sessionID: Int64
        let lang: String
        let provider: TranslationProvider
        let sentences: [Sentence]
        let translated: Set<Int>
        let scope: Scope
    }

    /// The run's engine, resolved once per run; `kind` stamps every landed
    /// result so the row's provenance marker follows.
    enum EngineResolution: Sendable {
        case ready(engine: any TranslationEngine, kind: TranslationEngineKind)
        case unavailable(reason: String)
        /// The arm window was cut short by a lane teardown (the archive
        /// closed): no job starts and nothing reports — the surface that
        /// would have shown it is gone.
        case cancelled
    }

    /// What the job reports: the toast surface mirrors these, tests assert
    /// them.
    enum Event: Equatable, Sendable {
        case started(total: Int)
        case progress(processed: Int, total: Int)
        case finished(translated: Int, failedIndexes: [Int])
        case cancelled(translated: Int)
        case unavailable(reason: String)
    }

    /// True from the synchronous `prepare()` claim until the run ends —
    /// engine resolution included. The app model's per-row retry guard and
    /// its one-job-at-a-time refusal read this.
    private(set) var isActive = false

    /// True from the moment the engine resolves until the loop exits (or a
    /// cancel lands mid-flight).
    private(set) var isRunning = false

    /// The run in flight, or the last finished one — the retry-failed read.
    private(set) var currentRun: Request?

    /// The claimed run awaiting engine resolution — the request becomes
    /// visible the moment `run` starts resolving (the claim precedes it
    /// only synchronously), and `beginRun` moves it into `currentRun`. Nil
    /// while idle, while a run executes, and after every early return.
    private(set) var pendingRequest: Request?

    /// The current (or last) run's resolved engine kind.
    private(set) var kind: TranslationEngineKind?

    private(set) var total = 0
    private(set) var processed = 0
    private(set) var translatedCount = 0

    /// The run's failed indexes, in index order (the summary's retry set);
    /// in-memory only — a relaunch loses the retry affordance, never the
    /// translations.
    private(set) var failureIndexes: [Int] = []

    private var isCancelled = false

    /// Resolves the run's engine — the coordinator's archive-job route.
    /// Injected by the app model; the default refuses, so an unwired job
    /// can never fly.
    @ObservationIgnored var resolveEngine:
        @MainActor (TranslationProvider, TargetLanguage) async -> EngineResolution = { _, _ in
            .unavailable(reason: "No translation engine attached — try again in a moment.")
        }

    /// Lands one fresh translation: the caller (the app model) owns the
    /// store upsert, the row swap, and the refresh revision, and reports
    /// whether the result actually landed — a false return records the
    /// index as a retryable failure instead of counting success.
    @ObservationIgnored var land: @MainActor (Int, SentenceTranslation) -> Bool = { _, _ in true }

    /// Progress/finish notifications; nil stays silent (tests).
    @ObservationIgnored var onEvent: (@MainActor (Event) -> Void)?

    /// Claims the job slot synchronously, before the async run's engine
    /// resolution: per-row retries are refused from the click onward, so a
    /// session-backed engine never sees concurrent calls. Returns false when
    /// a run is already claimed. Clears a cancel left over from a previous
    /// generation, so the claim is always fresh.
    func prepare() -> Bool {
        guard !isActive else { return false }
        isActive = true
        isCancelled = false
        return true
    }

    /// Starts a prepared run. Refused — no event — when the slot wasn't
    /// claimed (`prepare`) or a run is already executing. A cancel landing
    /// during engine resolution discards the run silently: the surface that
    /// would have reported it is already gone.
    func run(_ request: Request) async {
        guard isActive, !isRunning else { return }
        let indexes = Self.indexes(for: request)
        guard !indexes.isEmpty else {
            isActive = false
            onEvent?(.finished(translated: 0, failedIndexes: []))
            return
        }
        pendingRequest = request
        let resolution = await resolveEngine(request.provider, TargetLanguage(code: request.lang))
        guard !isCancelled else {
            pendingRequest = nil
            isActive = false
            return
        }
        let engine: any TranslationEngine
        let resolvedKind: TranslationEngineKind
        switch resolution {
        case let .ready(resolvedEngine, engineKind):
            engine = resolvedEngine
            resolvedKind = engineKind
        case let .unavailable(reason):
            pendingRequest = nil
            isActive = false
            onEvent?(.unavailable(reason: reason))
            return
        case .cancelled:
            pendingRequest = nil
            isActive = false
            return
        }
        beginRun(request, kind: resolvedKind, total: indexes.count)
        await translateAll(indexes, of: request, through: engine, kind: resolvedKind)
        finishRun()
    }

    /// Cooperative cancel: no new sentence starts; whatever is airborne
    /// finishes and lands.
    func cancel() {
        isCancelled = true
    }

    // MARK: - Run internals

    private func beginRun(_ request: Request, kind: TranslationEngineKind, total: Int) {
        isRunning = true
        currentRun = request
        pendingRequest = nil
        self.kind = kind
        self.total = total
        processed = 0
        translatedCount = 0
        failureIndexes = []
        onEvent?(.started(total: total))
    }

    /// Walks the run's indexes, one engine call at a time, publishing
    /// progress per completed sentence.
    private func translateAll(
        _ indexes: [Int], of request: Request,
        through engine: any TranslationEngine, kind: TranslationEngineKind
    ) async {
        let sentenceByIndex = Dictionary(
            uniqueKeysWithValues: request.sentences.map { sentence in (sentence.index, sentence) }
        )
        for index in indexes {
            if isCancelled || Task.isCancelled {
                break
            }
            guard let sentence = sentenceByIndex[index] else { continue }
            if await translateOne(sentence, of: request, through: engine, kind: kind) {
                break
            }
            processed = translatedCount + failureIndexes.count
            onEvent?(.progress(processed: processed, total: total))
        }
    }

    /// One engine call. Returns true when the loop must stop without a
    /// progress publication (a cancellation of this job or its task); a
    /// failed call — including a lost store write — is recorded and the
    /// walk continues.
    private func translateOne(
        _ sentence: Sentence, of request: Request,
        through engine: any TranslationEngine, kind: TranslationEngineKind
    ) async -> Bool {
        do {
            let results = try await engine.translate([sentence.text])
            guard let text = results.first, !text.isEmpty else {
                throw TranslationEngineError.badResponse(
                    "Expected 1 non-empty translation, got 0"
                )
            }
            // A result that arrived after a cancel still lands: partial
            // results stay stored, and a fill-missing re-run resumes for
            // free. A sink reporting a lost write makes the sentence a
            // retryable failure instead of a phantom success.
            let landed = land(
                sentence.index,
                SentenceTranslation(lang: request.lang, text: text, engine: kind)
            )
            if landed {
                translatedCount += 1
            } else {
                failureIndexes.append(sentence.index)
            }
            return false
        } catch is CancellationError {
            // An engine-reported cancellation without a cancel request is
            // just one sentence's failure — only a real cancel stops the
            // walk.
            guard isCancelled || Task.isCancelled else {
                failureIndexes.append(sentence.index)
                return false
            }
            return true
        } catch {
            failureIndexes.append(sentence.index)
            return false
        }
    }

    private func finishRun() {
        isRunning = false
        isActive = false
        if isCancelled || Task.isCancelled {
            onEvent?(.cancelled(translated: translatedCount))
        } else {
            onEvent?(.finished(translated: translatedCount, failedIndexes: failureIndexes))
        }
    }

    /// A run's indexes in sentence order — the scope computation, pure and
    /// pinned by tests.
    static func indexes(for request: Request) -> [Int] {
        let all = request.sentences.map(\.index)
        switch request.scope {
        case .missing:
            return all.filter { index in !request.translated.contains(index) }
        case .all:
            return all
        case let .failedOnly(failed):
            return all.filter { index in failed.contains(index) }
        }
    }
}
