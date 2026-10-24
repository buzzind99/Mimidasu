import Foundation
import Observation
import Translation

/// Session lifecycle phases.
enum SessionPhase: Equatable {
    case needsModel
    case idle
    case starting
    case running
    /// Capture suspended while the session stays live: the IOProc is stopped,
    /// the timeline and duration freeze, and `resume()` returns to `.running`.
    case paused
    case sourceLost
    case stopping
    case failed(String)
}

/// Orchestrates capture → ASR → sentence buffering → translation, and owns
/// the published UI state. All public state is @MainActor. The mechanics of
/// a live session (engine, capture, buffering, timers) live in
/// `SessionController`.
@Observable
@MainActor
final class AppModel {
    /// The session-phase owner: **every** production phase write goes through
    /// it. The machine is a pure value type, so it is observed like any other
    /// stored state — a phase change invalidates the views that read it.
    private(set) var phaseMachine = SessionPhaseMachine()

    /// The session phase.
    ///
    /// Production writes go through `reducePhase(_:)`, never through this
    /// setter. The setter exists for tests, and it **never revokes the
    /// quit-time latch**: a phase write may not re-open the start gate
    /// underneath a termination in flight. A test that needs a clean slate
    /// (both latches reset) uses `forcePhaseForTesting(_:)`.
    var phase: SessionPhase {
        get { phaseMachine.phase }
        set { phaseMachine.setPhase(newValue) }
    }

    /// Test seam: force the phase and reset the machine's internal latches
    /// with it, so the latches stay coherent with the phase they describe.
    ///
    /// The explicit way to clear the quit-time latch — production has no
    /// path to it.
    func forcePhaseForTesting(_ newPhase: SessionPhase) {
        phaseMachine.setPhaseForTesting(newPhase)
    }

    /// Observed UI state
    var entries: [SessionEntry] = []
    /// SESSION-card character total: Σ sentence text lengths (translations
    /// excluded), maintained incrementally on sentence append / session
    /// clear / archive swap instead of re-summing the transcript per render.
    /// Internal setter: the archive swap lives in the archive surface.
    var sessionCharacterCount = 0
    /// Observable mirror of `translationQueue.hasWorker` for the retry gate
    /// (the queue is not `@Observable`). An Apple run stays parked across a
    /// stop (true); an external run flips it false as its cancelled worker
    /// unwinds.
    private(set) var translationWorkerActive = false
    var engineIsMock = false
    var modelURL: URL?
    /// Floating subtitle overlay, shown/hidden from the sidebar's overlay
    /// button, the HUD's own close button, or the translation overlay's
    /// subtitle button; not persisted (starts hidden each launch).
    /// Independent of `translationOverlayVisible`, and each flip posts
    /// `.mimidasuHUDVisibilityDidChange`.
    var hudVisible = false {
        didSet {
            guard hudVisible != oldValue else { return }
            NotificationCenter.default.post(name: .mimidasuHUDVisibilityDidChange, object: self)
        }
    }

    /// Translation-only companion overlay: a scrollable, bottom-pinned list
    /// of every finalized translation. Shown/hidden from the HUD's translate
    /// button, the overlay's own close button, or the sidebar's overlay
    /// master switch (which closes it); not persisted (starts hidden each
    /// launch). Each flip posts `.mimidasuTranslationOverlayVisibilityDidChange`.
    var translationOverlayVisible = false {
        didSet {
            guard translationOverlayVisible != oldValue else { return }
            NotificationCenter.default.post(name: .mimidasuTranslationOverlayVisibilityDidChange, object: self)
        }
    }

    /// HUD translation history cursor: the pinned sentence index while
    /// browsing older translations, or nil to follow the latest translated
    /// entry. Pinning an older entry means new translations never move the
    /// view; nil tracks the newest.
    var hudPinnedIndex: Int?
    /// True while a session start is blocked on a missing dictionary build
    /// (see `ensureDictionaryReady`). Mutated only by the preparation
    /// surface in the dictionary surface.
    var isPreparingDictionary = false
    /// True while model discovery (resolve + SHA-256 verify) is in flight —
    /// at launch and on a Settings re-check. Start is gated on it: the
    /// verify hashes up to ~1.2 GB and must never run on the main thread.
    /// Internal setter: driven from the model-selection surface (the
    /// availability refresh lives there).
    var isCheckingModel = true

    /// The popover's current anchor: the surface (transcript row or live
    /// strip) whose tap owns the app's single dictionary popover, with the
    /// content shown and the paged entry index. Nil when no popover is up.
    var selectedLookup: SelectedLookup?
    /// The pinned sidebar DICTIONARY card content: the last lookup of the
    /// session — found or not-found — with the paged entry index.
    /// Persists after the popover dismisses; cleared on session clear.
    /// Mutated by the lookup lifecycle in the dictionary surface and the
    /// session-begin reset below.
    var pinnedLookup: PinnedLookup?
    /// Staleness token for in-flight lookups: each new tap invalidates the
    /// previous one, so a slow lookup that lands after a newer tap (or a
    /// session clear) never presents stale state. Mutated by the lookup
    /// lifecycle in the dictionary surface and the session-begin bump below.
    var lookupGeneration = 0
    /// The JMDict lookup engine behind dictionary taps; injectable so tests
    /// drive a fixture database (the default resolves the prepared store).
    let jmDictLookup: JMDictLookup
    /// The full-dictionary search engine behind the reference window's
    /// Dictionary mode; injectable on the same terms as `jmDictLookup`. It
    /// owns its own read-only handle rather than sharing `jmDictLookup`'s, so
    /// a long prefix scan cannot stall a tap lookup: the two only ever meet at
    /// SQLite's own file locking.
    let dictionarySearch: DictionarySearchEngine

    /// Launch-time model discovery, spawned async in `init` (the verify is a
    /// multi-hundred-MB hash and must not stall the first frame). Internal so
    /// tests can await it before asserting on phase state.
    private(set) var initialModelCheck: Task<Void, Never>?

    /// The model resolver driving every availability refresh (launch check,
    /// selection re-resolve, Settings re-check). Injectable for tests; the
    /// default drives the real locator. Internal: invoked from the
    /// model-selection surface.
    let modelResolve: @Sendable (ASRModelChoice) -> URL?

    let live = LivePartialState()
    let latency = LatencyState()
    let audioLevel = AudioLevelState()
    /// Toast stack: every error surface routes through here;
    /// cleared on session stop/teardown.
    let toasts = ToastCenter()
    /// Transient notice pill (e.g. copy confirmation); single message,
    /// auto-dismissed, cleared on session stop/teardown.
    let notices = NoticeCenter()
    let translationQueue = TranslationQueue()
    /// Non-secret translation provider settings (selected provider, hasKey
    /// flags, per-provider model overrides, test results, target language).
    /// Keys stay in `SecureKeyStoring` and are read on demand (engine
    /// construction, connection tests).
    let translationSettings: TranslationSettings
    /// Runtime-discovered translation-target catalog (`LanguageAvailability`
    /// probe), refreshed by Settings on open; the TARGET LANGUAGE picker
    /// reads it.
    let appleTranslationAvailability = AppleTranslationAvailability()
    /// Non-secret ASR model selection (Lite default, Full opt-in); persisted
    /// across launches. Switching applies at the next session start.
    let asrModelSettings: ASRModelSettings
    /// The user's starred words, persisted in their own SQLite file and
    /// outliving sessions (unlike `pinnedLookup`/`selectedLookup`, which
    /// `wireSessionController` resets). Every mutation runs on the main
    /// actor; the transcript render path probes the store's in-memory
    /// match set, never the database.
    let favorites: FavoritesStore

    /// The session archive (SQLite): the live session persists through it
    /// sentence by sentence, and the archive window reads it. Writes are
    /// synchronous from the main actor under the store's mutex — per-
    /// sentence/translation writes are ms-scale. Injectable for tests: the
    /// default opens the production Application Support file.
    let archive: ArchiveStore

    /// The archive window's cached read surface over `archive`: it owns the
    /// listed summaries, the typed availability, and the revision every
    /// landed archive mutation bumps. UI reads only this, never the store.
    let archiveRead: ArchiveReadModel

    /// The stored row of the live recording, created lazily with the first
    /// finalized sentence. Nil before that (and when the archive is
    /// unavailable). Mutated from the persistence path in the archive
    /// surface; reset at session begin.
    var recordingSessionID: Int64?

    /// Latched by the first failed archive write of a session: writes stop
    /// being attempted, one warning toast is posted, and stop persists
    /// nothing (and skips its prompt) for the rest of the session. Reset at
    /// session begin. Mutated from the archive surface.
    var archiveWriteFailed = false

    /// The stored session opened read-only in the transcript pane, or nil
    /// when the pane shows live-session state. Mutated from the archive
    /// surface.
    var openArchive: ArchivedSession?

    /// The opened archive's viewing-language override (BCP-47 code): nil =
    /// the archive's stored target. View-only state — switching never
    /// mutates stored translations. Reset on open, cleared on close;
    /// mutated from the archive surface and the bulk job's add flows.
    var archiveViewingLanguage: String?

    /// The bulk archive-translation job: one run at a time over the opened
    /// archive's sentences, with its engine resolver and landing sink wired
    /// in the bulk archive-translation surface.
    let archiveTranslationJob = ArchiveTranslationJob()

    /// Forwards the archive read model's revision, which bumps once per
    /// landed archive mutation so the archive window reloads its rows when
    /// it changes.
    var archiveRevision: Int {
        archiveRead.revision
    }

    /// Latest resolve result per choice (bundled → downloaded → dev, SHA-256
    /// verified). The Settings Model section reads it to enable selection;
    /// `modelURL` is the active choice's entry. Internal setter: written by
    /// the availability refresh in the model-selection surface.
    var modelAvailability: [ASRModelChoice: URL] = [:]

    /// The live translation session — engine attach, manual retry, the
    /// one-way Apple fallback latch, the high-fidelity probe, and the
    /// provider-selection machinery — behind the forwarding façade in the
    /// translation surface. Test seam: UI must use the facades, never reach
    /// through to the coordinator.
    let translationSession: TranslationSessionCoordinator

    /// The re-translate lane — route resolution, dedicated Apple sessions,
    /// marker sets, and the serialized runner — behind the forwarding
    /// façade in the translation surface. Test seam: UI must use the
    /// facades, never reach through to the coordinator.
    let retranslate: RetranslateCoordinator

    /// The refresh spawned by the most recent `selectModel` (tracked so
    /// `adoptDownloadedModel` can await it instead of stacking passes).
    /// Internal: managed from the model-selection surface.
    var modelSelectionRefresh: Task<Void, Never>?

    /// The in-flight teardown task from `stop()`. `shutdownForTermination`
    /// awaits it so quit never runs a second teardown concurrently with a
    /// user-initiated one. Internal: managed from the termination surface.
    var stopTask: Task<Void, Never>?

    /// Latched by `shutdownForTermination`: once quit-time teardown begins,
    /// `start` is refused — a session begun during the `.terminateLater`
    /// window would race the engine retirement that follows the drain.
    /// The latch lives in the phase machine (`phaseMachine.isTerminating`),
    /// which owns it with the rest of the session phase.
    /// SESSION-card duration anchors: set when a session's chunks start
    /// flowing (`onSessionBegin`) and when teardown completes
    /// (`performStop`); both nil before the first session and while an
    /// archived session is open (its stats live in the banner). Duration
    /// reads now − startedAt while running, endedAt − startedAt after stop.
    /// Monotonic instants: a wall-clock change mid-session must not distort
    /// the elapsed display. Internal setter: the archive open/close swaps
    /// live in the archive surface.
    var sessionStartedAt: ContinuousClock.Instant?
    /// Internal setter: `performStop` lives in the termination surface.
    var sessionEndedAt: ContinuousClock.Instant?
    /// When the capture source died mid-session (`.sourceLost`). The SESSION
    /// card freezes at it during the outage — the session clock itself
    /// survives a successful restart, so duration resumes counting then.
    /// Internal setter: `restartCapture` lives in the session surface while
    /// the resume fallback lives in the same surface's pause path.
    var captureLostAt: ContinuousClock.Instant?
    /// Completed paused spans of the current session, excluded from the
    /// displayed and stored duration. Mutated only by the pause path; reset
    /// at session begin.
    var sessionPausedTotal: Duration = .zero
    /// When the current pause began; nil outside `.paused`. Mutated only by
    /// the pause path.
    var pauseStartedAt: ContinuousClock.Instant?
    /// A capture error observed while paused — the capture-lost deferral.
    /// Surfaced only when a resume cannot bring the capture back (the
    /// rebuild path reports it). Mutated only by the pause path and the
    /// capture-error wiring below.
    var deferredCaptureError: String?
    /// Injectable so tests can observe (and fake) the quit-time release of
    /// the process-warm ASR engine; the default drives the real factory.
    /// Internal: invoked from the termination surface.
    let retireWarmEngine: @Sendable () -> Void

    /// Sentence index → position in `entries`. Entries are append-only within
    /// a session (positions never shift), so translations resolve in O(1)
    /// instead of scanning the transcript per arrival. Cleared with
    /// `entries` on session begin. Written by `handleSentence` and the
    /// session-begin clear (both in this file); `applyTranslation` only
    /// reads it.
    var entryPositionBySentence: [Int: Int] = [:]

    /// Injectable so the terminate-notification wiring can be tested
    /// hermetically — posting on the shared `.default` center from a parallel
    /// test would stop every other live `AppModel`. The default is the
    /// app-wide center. A `Sendable` constant, so `deinit` can read it.
    private let willTerminateNotifications: NotificationCenter

    /// The terminate-notification subscription. Stored so `deinit` can
    /// remove it — otherwise every `AppModel` built in tests leaks one
    /// dead observer on its notification center. Non-isolated with the
    /// center above; written once in `init`, read once in `deinit`.
    @ObservationIgnored private nonisolated(unsafe) var willTerminateObserver: NSObjectProtocol?

    /// Internal (not private) so tests can drive the session callbacks.
    let sessionController: SessionController

    /// Injectable test seams: tests drive start/stop over a scripted
    /// `SessionController` and quiesce the launch check — the real locator
    /// SHA-256-verifies up to ~1.2 GB and feeds the engine warm-up. The
    /// defaults build the real controller and locator.
    init(
        makeSessionController: (
            (LivePartialState, LatencyState, AudioLevelState, TranslationQueue) -> SessionController
        )? = nil,
        translationSettings: TranslationSettings? = nil,
        asrModelSettings: ASRModelSettings? = nil,
        favorites: FavoritesStore? = nil,
        archive: ArchiveStore? = nil,
        translationTransport: HTTPTranslationTransport? = nil,
        highFidelityProbe: @escaping @Sendable (String) async -> Bool =
            AppleTierAvailability.check(targetCode:),
        jmDictLookup: JMDictLookup? = nil,
        dictionarySearch: DictionarySearchEngine? = nil,
        initialModelResolve: @escaping @Sendable (ASRModelChoice) -> URL? = { choice in
            ModelLocator.resolve(for: choice)
        },
        retireWarmEngine: @escaping @Sendable () -> Void = {
            ASREngineFactory.retireWarmEngine()
        },
        willTerminateNotifications: NotificationCenter = .default
    ) {
        self.translationSettings = translationSettings ?? TranslationSettings()
        self.asrModelSettings = asrModelSettings ?? ASRModelSettings()
        self.favorites = favorites ?? FavoritesStore()
        self.archive = archive ?? ArchiveStore()
        archiveRead = ArchiveReadModel(store: self.archive)
        self.jmDictLookup = jmDictLookup ?? JMDictLookup()
        self.dictionarySearch = dictionarySearch ?? DictionarySearchEngine()
        modelResolve = initialModelResolve
        self.retireWarmEngine = retireWarmEngine
        self.willTerminateNotifications = willTerminateNotifications
        let tierAvailability = AppleTierAvailability(check: highFidelityProbe)
        let translationSession = TranslationSessionCoordinator(
            queue: translationQueue,
            settings: self.translationSettings,
            transport: translationTransport,
            tierAvailability: tierAvailability
        )
        let retranslate = RetranslateCoordinator(
            live: translationSession,
            queue: translationQueue,
            settings: self.translationSettings,
            tierAvailability: tierAvailability
        )
        translationSession.retranslate = retranslate
        self.translationSession = translationSession
        self.retranslate = retranslate
        if let makeSessionController {
            sessionController = makeSessionController(live, latency, audioLevel, translationQueue)
        } else {
            sessionController = SessionController(
                live: live, latency: latency, audioLevel: audioLevel,
                translationQueue: translationQueue
            )
        }
        wireSessionController()
        translationQueue.setHandlers(
            result: { [weak self] index, translation in
                self?.applyTranslation(index: index, translation: translation)
            },
            // Through the facade so tests exercise the production path.
            status: { [weak self] status in
                self?.handleTranslationStatus(status)
            },
            workerChanged: { [weak self] active in
                self?.translationWorkerActive = active
            }
        )
        // The coordinators captured only values (queue, settings) above, so
        // no `self` escaped before full init. The host wiring below runs
        // after every stored property is initialized: the coordinators reach
        // phase, toasts, and the row landing through the host port.
        translationSession.host = self
        retranslate.host = self
        // Extends the model's lifetime until the first availability pass
        // completes (fast in tests, bounded in production) — intentional.
        initialModelCheck = Task { await refreshModelAvailability() }
        prepareDictionaries()
        // A `recording` row left by an unclean exit becomes an Interrupted
        // recent before anything can list the archive.
        sweepArchivesOnLaunch()
        wireArchiveTranslationJob()

        willTerminateObserver = willTerminateNotifications.addObserver(
            forName: .mimidasuAppWillTerminate, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.shutdownForTermination() }
        }
    }

    deinit {
        if let willTerminateObserver {
            willTerminateNotifications.removeObserver(willTerminateObserver)
        }
    }

    // MARK: - Session phase

    /// Applies a phase action to the machine and returns what the host must
    /// do about it.
    ///
    /// The machine **decides**; the host **executes**. A refused transition
    /// changed nothing, so the host must do nothing either — that is the
    /// whole point of moving the decision into the machine.
    @discardableResult
    func reducePhase(_ action: SessionAction) -> SessionTransition {
        phaseMachine.reduce(action)
    }

    private func wireSessionController() {
        sessionController.onSessionBegin = { [weak self] in
            guard let self else { return }
            entries.removeAll()
            entryPositionBySentence.removeAll()
            // Sentence indexes restart at 0 in every session, so a backlog
            // left by the last one has no row to land on — drop it, and with
            // it any re-translation marker still waiting on its result and
            // any lane task still in flight from the previous session.
            translationQueue.resetForNewSession()
            // Begin order is lane-then-live; stop order in `performStop` is
            // live-then-lane. The halves are independent (marker/epoch clear
            // vs latch reset), so the swap is harmless — kept as moved.
            retranslate.sessionWillBegin()
            // The Apple-fallback latch is per session: a fresh session
            // re-attempts the configured provider from scratch.
            translationSession.sessionWillBegin()
            sessionCharacterCount = 0
            hudPinnedIndex = nil
            sessionStartedAt = .now
            sessionEndedAt = nil
            captureLostAt = nil
            // Pause state is per session: a fresh session starts unpaused
            // with no accumulated paused time and no deferred capture error.
            sessionPausedTotal = .zero
            pauseStartedAt = nil
            deferredCaptureError = nil
            // Archive persistence is per session too: a previous session's
            // write latch must not disable this one.
            archiveWriteFailed = false
            // Dictionary state is per session too: the popover anchor and
            // the pinned card reset, and any in-flight lookup is dropped.
            selectedLookup = nil
            pinnedLookup = nil
            lookupGeneration &+= 1
        }
        sessionController.onEngineChosen = { [weak self] isMock, url in
            self?.engineIsMock = isMock
            self?.modelURL = url
        }
        sessionController.onSentence = { [weak self] sentence in
            self?.handleSentence(sentence)
        }
        sessionController.onEngineError = { [weak self] message in
            // Throttled ASR warnings (first + every 32nd): transient toast.
            self?.toasts.post(
                key: ToastKey.asrWarning, style: .yellowAuto,
                title: "Transcription warning", body: message
            )
        }
        sessionController.onCaptureError = { [weak self] message in
            // A capture failure is fatal in any active phase: mid-session it
            // means the source is gone; during `.starting` it means the
            // session can never come up, so surface it instead of swallowing.
            // While paused it is DEFERRED: the resume path rebuilds the
            // capture, and only a failed resume reports capture lost.
            guard let self else { return }
            let transition = reducePhase(.captureLost(message))
            if transition.defersCaptureError {
                deferredCaptureError = message
                return
            }
            guard transition.isLegal else { return }
            captureLostAt = .now
            toasts.dismiss(key: ToastKey.noAudio)
            postCaptureLost(body: message)
        }
        sessionController.onNoAudioDetected = { [weak self] in
            self?.postNoAudioWarning()
        }
        sessionController.onAudioDetected = { [weak self] in
            // Capture is finally carrying signal: retire the warning.
            self?.toasts.dismiss(key: ToastKey.noAudio)
        }
    }

    // MARK: - Model / app discovery

    // The availability refresh lives in the model-selection surface.

    // MARK: - Model selection

    // Switching the active ASR model and adopting a downloaded model live in
    // the model-selection surface.

    // MARK: - Dictionary preparation

    // The first-launch dictionary kick-off and the session-start gate live in
    // the dictionary surface.

    // MARK: - Session control

    // Starting a session and bringing it up to `.running` live in the
    // session surface.

    /// Restarts the capture stream mid-session — the `capture.lost` toast's
    /// fix action. Guarded on `.sourceLost`: a
    /// double-tap is a no-op and a `stop()` during the restart wins the race
    /// (the phase check after the await refuses to resurrect a stopped
    /// session). Entries, the session clock, and the fallback latch survive;
    /// `onSessionBegin` does not re-fire.
    func restartCapture() {
        guard phase == .sourceLost else { return }
        performCaptureRestart()
    }

    /// The shared capture-rebuild flow: the `.sourceLost` fix action above,
    /// and the resume of a pause that found the capture dead (its caller
    /// hands the machine the restart request). A `stop()` during the rebuild
    /// wins the race — the machine refuses to resurrect a stopped session.
    /// Internal: driven from the pause path.
    func performCaptureRestart() {
        guard reducePhase(.captureRestartRequested).isLegal else { return }
        Task { @MainActor in
            do {
                try await sessionController.restartCapture()
                // A stop() interleaved while the restart was in flight: the
                // session is gone (engine nil, restartCapture no-oped) and
                // must not come back up.
                guard reducePhase(.captureRestartSucceeded).isLegal else { return }
                captureLostAt = nil
                // A fresh capture is up: any error observed while the old one
                // was down must not force another rebuild later.
                deferredCaptureError = nil
                toasts.dismiss(key: ToastKey.captureLost)
                sessionController.armNoAudioWatchdog()
            } catch {
                let message = "Restart failed: \(error.localizedDescription)"
                guard reducePhase(.captureRestartFailed(message)).isLegal else { return }
                postCaptureLost(body: message)
            }
        }
    }

    // MARK: - Event handling (main actor)

    private func handleSentence(_ sentence: Sentence) {
        entryPositionBySentence[sentence.index] = entries.count
        entries.append(SessionEntry(sentence: sentence))
        sessionCharacterCount += sentence.text.count
        // The archive row follows the transcript: persistence is the same
        // synchronous main-actor path, governed by the per-session latch.
        persistSentence(sentence)
        // Synchronous main-actor enqueue: by the time `stop` drains, every
        // emitted sentence is observably in the queue.
        translationQueue.enqueue(sentence)
    }
}
