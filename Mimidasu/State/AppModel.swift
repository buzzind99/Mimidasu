import Foundation
import Observation
import Translation

/// Session lifecycle phases.
enum SessionPhase: Equatable {
    case needsModel
    case idle
    case starting
    case running
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
    // Observed UI state
    var phase: SessionPhase = .idle
    var entries: [SessionEntry] = []
    /// SESSION-card character total: Σ sentence text lengths (translations
    /// excluded), maintained incrementally on sentence append / session
    /// clear instead of re-summing the transcript per render.
    private(set) var sessionCharacterCount = 0
    var translationStatus: TranslationStatus = .idle
    /// Observable mirror of `translationQueue.hasWorker` for the retry gate
    /// (the queue is not `@Observable`); stays true across stop (parked Apple run).
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
    /// surface in `AppModelDictionary.swift`.
    var isPreparingDictionary = false
    /// True while model discovery (resolve + SHA-256 verify) is in flight —
    /// at launch and on a Settings re-check. Start is gated on it: the
    /// verify hashes up to ~1.2 GB and must never run on the main thread.
    /// Internal setter: driven from `AppModelModelSelection.swift` (the
    /// availability refresh lives there, file split for the lint gate).
    var isCheckingModel = true

    /// The popover's current anchor: the surface (transcript row or live
    /// strip) whose tap owns the app's single dictionary popover, with the
    /// content shown and the paged entry index. Nil when no popover is up.
    var selectedLookup: SelectedLookup?
    /// The pinned sidebar DICTIONARY card content: the last lookup of the
    /// session — found or not-found — with the paged entry index.
    /// Persists after the popover dismisses; cleared on session clear.
    /// Mutated by the lookup lifecycle in `AppModelLookup.swift` and the
    /// session-begin reset below.
    var pinnedLookup: PinnedLookup?
    /// Staleness token for in-flight lookups: each new tap invalidates the
    /// previous one, so a slow lookup that lands after a newer tap (or a
    /// session clear) never presents stale state. Mutated by the lookup
    /// lifecycle in `AppModelLookup.swift` and the session-begin bump below.
    var lookupGeneration = 0
    /// The JMDict lookup engine behind dictionary taps; injectable so tests
    /// drive a fixture database (the default resolves the prepared store).
    let jmDictLookup: JMDictLookup

    /// Drives SwiftUI's `.translationTask` (session acquisition + pack prompt).
    var translationConfig: TranslationSession.Configuration?

    /// Launch-time model discovery, spawned async in `init` (the verify is a
    /// multi-hundred-MB hash and must not stall the first frame). Internal so
    /// tests can await it before asserting on phase state.
    private(set) var initialModelCheck: Task<Void, Never>?

    /// The model resolver driving every availability refresh (launch check,
    /// selection re-resolve, Settings re-check). Injectable for tests; the
    /// default drives the real locator. Internal: invoked from
    /// `AppModelModelSelection.swift`.
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
    /// flags, OpenRouter model, test results, target language). Keys stay in
    /// `SecureKeyStoring` and are read on demand (engine construction,
    /// connection tests).
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

    /// Latest resolve result per choice (bundled → downloaded → dev, SHA-256
    /// verified). The Settings Model section reads it to enable selection;
    /// `modelURL` is the active choice's entry. Internal setter: written by
    /// the availability refresh in `AppModelModelSelection.swift`.
    var modelAvailability: [ASRModelChoice: URL] = [:]

    /// True once this session has latched onto Apple on-device after an
    /// external engine failed (the Settings "Currently using" row surfaces it).
    /// Reset by every manual retry (each retry re-arms the one-way fallback).
    var translationFallbackActive = false

    /// The engine currently attached to the queue — Apple's via the hidden
    /// `.translationTask` host, an external one via `translationWorker`.
    /// Internal: the translation-engine management lives in
    /// `AppModelTranslation.swift` (file split for the lint gate).
    var activeTranslationEngine: ActiveTranslationEngine = .apple

    /// Which external provider is attached while `activeTranslationEngine`
    /// is `.external` (nil on the Apple paths). Labels read this, never the
    /// picker, so the ENGINES card and "Currently using" row can't describe
    /// a provider that isn't actually attached. Internal: managed from
    /// `AppModelTranslation.swift`.
    var activeExternalProvider: TranslationProvider?

    /// Outcome of the last high-fidelity (Apple Intelligence) probe: whether
    /// the OS reports the strategy installed, and the ja→target code it was
    /// probed for (nil until a probe lands). Internal: managed from
    /// `AppModelTranslation.swift`.
    var appleHighFidelityProbe: (installed: Bool, targetCode: String?) = (false, nil)

    /// Monotonic token ruling which high-fidelity probe may land: every
    /// engine attach and teardown bumps it, so a probe superseded before it
    /// finished is dropped. Internal: managed from `AppModelTranslation.swift`.
    var highFidelitySequence = 0

    /// Session boundary token for the re-translate lane, in the same spirit as
    /// `TranslationQueue.sessionEpoch`: bumped in `onSessionBegin`,
    /// `performStop`, and `teardownRetranslateSession` (a mid-session Apple
    /// activation is a lane-generation change, not a session one), captured
    /// when a retry is clicked, and compared after the flight. A lane task
    /// that outlives its session — `performStop` cancels only the newest
    /// chained link, so earlier ones run to completion — would otherwise pass
    /// the phase guard (the next session is `.running` again) and write the
    /// *previous* session's translation onto an unrelated row, since
    /// `Sentence.index` restarts at 0. Internal: managed from
    /// `AppModelRetranslate.swift`.
    var retranslateSessionEpoch = 0

    /// How long the re-translate lane waits for an arming dedicated Apple
    /// session before giving up on a click. Injectable so the timeout test can
    /// exercise the real path in milliseconds instead of faking it with a
    /// cancellation, which is a different outcome. Internal: driven from
    /// `AppModelRetranslate.swift`.
    var laneArmTimeout = Duration.seconds(5)

    /// How long a high-fidelity re-translate lane waits for the activation
    /// probe to land before routing on it: while the probe is unlanded the
    /// live identity is unknown and the pair's hifi availability unproven,
    /// so the lane defers (see `AppModelRetranslate.probeLanding`). The
    /// probe is a fast async check; the bound only catches pathological
    /// cases. Injectable for tests. Internal: driven from
    /// `AppModelRetranslate.swift`.
    var probeSettleTimeout = Duration.seconds(3)

    /// The intent held behind the cloud disclosure sheet: completing a
    /// provider switch (the live translation engine) or a re-translate
    /// engine selection. Nil when no disclosure is pending. Internal:
    /// managed from `AppModelTranslation.swift` and
    /// `AppModelRetranslate.swift`; both confirm paths dispatch through
    /// `confirmCloudDisclosure`.
    var providerAwaitingDisclosure: PendingCloudDisclosure?

    /// Sentence indexes with a manual re-translation in flight (the
    /// transcript row's hover button). Membership is a dim cue and a
    /// double-click guard only — `applyTranslation` routes on the row's
    /// languages, so nothing about a result's *correctness* depends on it.
    /// Internal: inserted in `AppModelRetranslate.retranslateSentence`, and
    /// cleared by the landing result (`applyTranslation`), by any lane exit
    /// that will not deliver (`retireLaneMarker`), by the queue's terminal
    /// `.unavailable` that engages no replay (`handleTranslationStatus`), by
    /// session stop (`performStop`), and by the next session's begin
    /// (`onSessionBegin`). Read by views.
    var pendingRetranslations: Set<Int> = []

    /// Config for the dedicated low-latency (fast model) re-translate
    /// session, armed by the first Apple-fast retry. Internal: managed from
    /// `AppModelRetranslate.swift`.
    var retranslateConfig: TranslationSession.Configuration?

    /// The fast-model session handed out by the second `.translationTask`
    /// host, stored as the queue-side engine adapter. Internal: managed from
    /// `AppModelRetranslate.swift`.
    var retranslateSessionEngine: (any TranslationEngine)?

    /// Config for the dedicated high-fidelity (Apple Intelligence) re-translate
    /// session, armed by the first Apple-Intelligence retry. Internal:
    /// managed from `AppModelRetranslate.swift`.
    var retranslateHifiConfig: TranslationSession.Configuration?

    /// The high-fidelity session handed out by the third `.translationTask`
    /// host, stored as the queue-side engine adapter. Internal: managed from
    /// `AppModelRetranslate.swift`.
    var retranslateHifiSessionEngine: (any TranslationEngine)?

    /// Serialized one-at-a-time runner for alternate-engine retries: each
    /// new lane task awaits the previous one, so a session-backed engine
    /// never sees concurrent `translate` calls. Internal setter: driven from
    /// `AppModelRetranslate.swift` (the lane lives there, file split for the
    /// lint gate).
    var retranslateLaneTask: Task<Void, Never>?

    /// The lane-owned subset of `pendingRetranslations`: markers the
    /// re-translate lane itself inserted. The queue engine's terminal
    /// `.unavailable` clear drops queue-owned markers only — a lane
    /// translation in flight still has its deliverer, and losing the marker
    /// would re-open the double-click guard. Internal: managed from
    /// `AppModelRetranslate.swift`.
    var lanePendingRetranslations: Set<Int> = []

    /// Injectable factory for the lane's external engines (tests); nil
    /// drives `makeExternalEngine(for:)`. Internal: invoked from
    /// `AppModelRetranslate.swift`.
    var retranslateEngineFactory: (@Sendable (TranslationProvider) -> (any TranslationEngine)?)?

    /// The refresh spawned by the most recent `selectModel` (tracked so
    /// `adoptDownloadedModel` can await it instead of stacking passes).
    /// Internal: managed from `AppModelModelSelection.swift`.
    var modelSelectionRefresh: Task<Void, Never>?

    /// The spawned external-engine worker (`queue.run(with:)`). Apple runs
    /// belong to SwiftUI's `.translationTask` instead. Torn down on stop.
    /// Internal: managed from `AppModelTranslation.swift`.
    var translationWorker: Task<Void, Never>?

    /// The in-flight teardown task from `stop()`. `shutdownForTermination`
    /// awaits it so quit never runs a second teardown concurrently with a
    /// user-initiated one. Internal: managed from `AppModelTermination.swift`.
    var stopTask: Task<Void, Never>?

    /// Latched by `shutdownForTermination`: once quit-time teardown begins,
    /// `start` is refused — a session begun during the `.terminateLater`
    /// window would race the engine retirement that follows the drain.
    /// Internal: managed from `AppModelTermination.swift`.
    var isTerminating = false
    /// SESSION-card duration anchors: set when a session's chunks start
    /// flowing (`onSessionBegin`) and when teardown completes
    /// (`performStop`); both nil before the first session. Duration reads
    /// now − startedAt while running, endedAt − startedAt after stop.
    /// Monotonic instants: a wall-clock change mid-session must not distort
    /// the elapsed display.
    private(set) var sessionStartedAt: ContinuousClock.Instant?
    /// Internal setter: `performStop` lives in `AppModelTermination.swift`
    /// (file split for the lint gate).
    var sessionEndedAt: ContinuousClock.Instant?
    /// When the capture source died mid-session (`.sourceLost`). The SESSION
    /// card freezes at it during the outage — the session clock itself
    /// survives a successful restart, so duration resumes counting then.
    private(set) var captureLostAt: ContinuousClock.Instant?
    /// Injectable so tests can observe (and fake) the quit-time release of
    /// the process-warm ASR engine; the default drives the real factory.
    /// Internal: invoked from `AppModelTermination.swift`.
    let retireWarmEngine: @Sendable () -> Void

    /// Sentence index → position in `entries`. Entries are append-only within
    /// a session (positions never shift), so translations resolve in O(1)
    /// instead of scanning the transcript per arrival. Cleared with
    /// `entries` on session begin. Internal setter: written from
    /// `AppModelTranslation.swift` (`applyTranslation`).
    var entryPositionBySentence: [Int: Int] = [:]

    /// Injectable HTTP transport for the external engines (tests); nil drives
    /// the real per-provider `URLSession` transports.
    let translationTransport: HTTPTranslationTransport?

    /// Injectable probe for the OS's high-fidelity (Apple Intelligence)
    /// translation availability per target code (tests); the default drives
    /// the real `LanguageAvailability` check. Internal: invoked from
    /// `AppModelTranslation.swift`.
    let highFidelityProbe: @Sendable (String) async -> Bool

    /// Injectable so the terminate-notification wiring can be tested
    /// hermetically — posting on the shared `.default` center from a parallel
    /// test would stop every other live `AppModel`. The default is the
    /// app-wide center.
    private let willTerminateNotifications: NotificationCenter

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
        translationTransport: HTTPTranslationTransport? = nil,
        highFidelityProbe: @escaping @Sendable (String) async -> Bool = { code in
            await AppModel.checkHighFidelityAvailability(targetCode: code)
        },
        jmDictLookup: JMDictLookup? = nil,
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
        self.jmDictLookup = jmDictLookup ?? JMDictLookup()
        modelResolve = initialModelResolve
        self.translationTransport = translationTransport
        self.highFidelityProbe = highFidelityProbe
        self.retireWarmEngine = retireWarmEngine
        self.willTerminateNotifications = willTerminateNotifications
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
            status: { [weak self] status in
                self?.handleTranslationStatus(status)
            },
            workerChanged: { [weak self] active in
                self?.translationWorkerActive = active
            }
        )
        initialModelCheck = Task { await refreshModelAvailability() }
        prepareDictionaryIfNeeded()

        willTerminateNotifications.addObserver(
            forName: .mimidasuAppWillTerminate, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.shutdownForTermination() }
        }
    }

    private func wireSessionController() {
        sessionController.onSessionBegin = { [weak self] in
            guard let self else { return }
            entries.removeAll()
            entryPositionBySentence.removeAll()
            // Sentence indexes restart at 0 in every session, so a backlog
            // left by the last one has no row to land on — drop it, and with
            // it any re-translation marker still waiting on its result.
            translationQueue.resetForNewSession()
            pendingRetranslations.removeAll()
            lanePendingRetranslations.removeAll()
            // Retire any lane task still in flight from the previous session:
            // its sentence indexes no longer mean anything here.
            retranslateSessionEpoch += 1
            sessionCharacterCount = 0
            hudPinnedIndex = nil
            sessionStartedAt = .now
            sessionEndedAt = nil
            captureLostAt = nil
            // The Apple-fallback latch is per session: a fresh session
            // re-attempts the configured provider from scratch.
            translationFallbackActive = false
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
            guard let self, phase == .running || phase == .starting else { return }
            phase = .sourceLost
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

    // Availability refresh lives in `AppModelModelSelection.swift` (file
    // split for the lint gate).

    // MARK: - Model selection

    // Switching the active ASR model and adopting a downloaded model live
    // in `AppModelModelSelection.swift` (file split for the lint gate).

    // MARK: - Dictionary preparation

    // The first-launch dictionary kick-off and the session-start gate live
    // in `AppModelDictionary.swift` (file split for the lint gate).

    // MARK: - Session control

    func start() {
        guard !isCheckingModel, !isTerminating else { return }
        // A failed session restarts like an idle one (the sidebar offers
        // Start from `.failed`, and the failure card clears on the
        // next Start); every other active phase refuses.
        switch phase {
        case .idle, .failed: break
        default: return
        }
        phase = .starting
        // "Cleared on next Start": a previous session's failure card must
        // not outlive the user pressing Start again.
        toasts.dismiss(key: ToastKey.sessionFailed)

        Task { @MainActor in
            do {
                try await self.ensureDictionaryReady()
                try await self.beginSession()
            } catch {
                self.phase = .failed(error.localizedDescription)
                // Freeze the SESSION duration at the failure: a capture that
                // died mid-start would otherwise leave the endedAt anchor nil
                // and the frozen path reading now − startedAt per render.
                self.sessionEndedAt = .now
                self.toasts.dismiss(key: ToastKey.noAudio)
                self.toasts.post(
                    key: ToastKey.sessionFailed, style: .redPersistent,
                    title: "Session failed", body: error.localizedDescription
                )
            }
        }
    }

    private func beginSession() async throws {
        let started = try await sessionController.begin(
            modelURL: modelURL,
            modelID: asrModelSettings.selected.modelID,
            targetLang: translationSettings.targetLanguage.code
        )
        // The session may have been cancelled (or its capture lost) while
        // `begin()` was in flight. Tear down whatever begin() brought up so
        // a stopped session cannot come up anyway.
        guard phase == .starting else {
            await sessionController.stop()
            if phase == .stopping {
                phase = .idle
            }
            return
        }
        guard started else {
            phase = .needsModel
            return
        }

        phase = .running
        // A source-lost card cannot survive into the session it restarted
        // (the restart path also clears it; this covers a fresh start).
        toasts.dismiss(key: ToastKey.captureLost)

        // Activate translation: an external provider's worker is spawned
        // directly; Apple goes through the hidden `.translationTask` host
        // (prompting for the language pack the first time). Invalidate the
        // config first (mirroring retryTranslation) so SwiftUI reliably
        // re-fires the task even if a config survived.
        translationQueue.resetForRetry()
        activateTranslation()

        sessionController.startTimers()
        // The silence watchdog starts counting now, not at capture start: a
        // first-launch TCC prompt keeps the session `.starting` until access
        // is granted. TCC blocks the aggregate's first IO until the prompt
        // resolves (verified on device), so no callbacks — and no staged
        // silence — occur during the wait; the `.running` flip is the first
        // moment a genuinely silent capture can be observed.
        sessionController.armNoAudioWatchdog()
    }

    /// Restarts the capture stream mid-session — the `capture.lost` toast's
    /// fix action. Guarded on `.sourceLost`: a
    /// double-tap is a no-op and a `stop()` during the restart wins the race
    /// (the phase check after the await refuses to resurrect a stopped
    /// session). Entries, the session clock, and the fallback latch survive;
    /// `onSessionBegin` does not re-fire.
    func restartCapture() {
        guard phase == .sourceLost else { return }
        phase = .starting
        Task { @MainActor in
            do {
                try await sessionController.restartCapture()
                // A stop() interleaved while the restart was in flight: the
                // session is gone (engine nil, restartCapture no-oped) and
                // must not come back up.
                guard phase == .starting else { return }
                phase = .running
                captureLostAt = nil
                toasts.dismiss(key: ToastKey.captureLost)
                sessionController.armNoAudioWatchdog()
            } catch {
                guard phase == .starting else { return }
                phase = .sourceLost
                postCaptureLost(body: "Restart failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Event handling (main actor)

    private func handleSentence(_ sentence: Sentence) {
        entryPositionBySentence[sentence.index] = entries.count
        entries.append(SessionEntry(sentence: sentence))
        sessionCharacterCount += sentence.text.count
        // Synchronous main-actor enqueue: by the time `stop` drains, every
        // emitted sentence is observably in the queue.
        translationQueue.enqueue(sentence)
    }
}
