import Foundation
@testable import Mimidasu
import Synchronization
import Testing
import Translation

/// Tests the re-translate lane's route resolution and settings surface: the
/// plan's alternate route, the Apple selections' de facto degradation, the
/// duplicate-external degradation, the armed dedicated Apple sessions'
/// teardown at stop, the high-fidelity probe an external activation fires,
/// and the cloud disclosure that holds an external selection.
@MainActor
@Suite("AppModel re-translate routes")
struct AppModelRetranslateRouteTests {

    private let harness = RetranslateHarness(suite: "test.AppModelRetranslateRoute")
    private let resultTimeout: TimeInterval = 5

    /// An HTTP transport that always answers `status` — hermetic insurance
    /// for suites that activate a real external engine (no factory): one
    /// enqueued sentence away from a live network call otherwise.
    private func constantStatusTransport(_ status: Int) -> HTTPTranslationTransport {
        HTTPTranslationTransport(timeout: 5) { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil
            )!
            return (Data(), response)
        }
    }

    private func makeSUT(transport: HTTPTranslationTransport? = nil) async -> AppModel {
        await harness.makeModel(translationTransport: transport)
    }

    /// The live plan for the current settings target — what the transcript's
    /// retry button and the click path both read.
    private func livePlan(_ model: AppModel) -> RetranslatePlan {
        model.retranslatePlan(surface: .live, target: model.translationSettings.targetLanguage)
    }

    /// Attaches a queue worker and returns the engine too: the degrade tests
    /// must pin that the retry actually flew the queue a second time, and a
    /// row condition alone cannot tell a served retry from the untouched
    /// initial delivery.
    private func attachWorker(
        _ model: AppModel
    ) async -> (worker: Task<Void, Never>, engine: QueueEchoEngine) {
        let engine = QueueEchoEngine()
        let worker = await harness.attachWorker(model, engine: engine)
        return (worker, engine)
    }

    /// Which Apple selection names the live session's own model: a landed
    /// installed probe means the live session runs Intelligence; a landed
    /// not-installed probe means it fell back to the fast model.
    enum AppleSessionDegrade: String, CaseIterable, Sendable {
        case deFactoHifi
        case deFactoFast

        var selection: RetranslateEngine {
            switch self {
            case .deFactoHifi: .appleHighFidelity
            case .deFactoFast: .appleFast
            }
        }

        var probe: (installed: Bool, targetCode: String?) {
            switch self {
            case .deFactoHifi: (true, "en")
            case .deFactoFast: (false, "en")
            }
        }
    }

    // MARK: - Armed dedicated-session lifecycle

    @Test("stop drops both armed dedicated Apple sessions' engines and rebuilds their configs")
    func stopDropsArmedDedicatedSessions() async {
        let model = await makeSUT()
        model.phase = .running
        model.retranslateConfig = model.makeRetranslateConfig(highFidelity: false)
        model.retranslateSessionEngine = LaneEchoEngine()
        model.retranslateHifiConfig = model.makeRetranslateConfig(highFidelity: true)
        model.retranslateHifiSessionEngine = LaneEchoEngine()
        model.lanePendingRetranslations = [3]
        model.retranslateLaneTask = Task {}

        await model.performStop()

        // The configs are rebuilt in place, never nil-ed: a nil →
        // fresh-equal-config transition is the `.translationTask` path that
        // does not reliably re-fire, and the next Apple-kind retry would arm
        // onto it (see `teardownRetranslateSession`).
        #expect(model.retranslateConfig != nil, "the armed config is rebuilt, not nil-ed")
        #expect(model.retranslateSessionEngine == nil, "the stored engine goes with the old config")
        #expect(model.retranslateHifiConfig != nil, "the hifi config is rebuilt, not nil-ed")
        #expect(model.retranslateHifiSessionEngine == nil)
        #expect(model.lanePendingRetranslations.isEmpty)
        #expect(model.retranslateLaneTask == nil, "stop clears the stored lane task")
    }

    /// The explicit strategy is what keeps the dedicated lanes off the live
    /// session's model: the property's default follows the build SDK and
    /// would hand both lanes the same model, returning byte-identical text
    /// and defeating the feature.
    @Test("the dedicated lane configs pin their Apple strategies")
    func retranslateConfigsPinStrategies() async throws {
        guard #available(macOS 26.4, *) else {
            try Test.cancel("preferredStrategy requires macOS 26.4")
        }
        let model = await makeSUT()

        #expect(
            model.makeRetranslateConfig(highFidelity: false).preferredStrategy == .lowLatency,
            "the fast lane pins the fast model"
        )
        #expect(
            model.makeRetranslateConfig(highFidelity: true).preferredStrategy == .highFidelity,
            "the hifi lane pins the high-fidelity strategy"
        )
    }

    // MARK: - Route resolution

    @Test("the plan's alternate route tracks the selection and key state")
    func planAlternateRouteTracksSelection() async throws {
        // The second half of the truth table pivots on the probe-installed
        // Apple identity, which `activeEngineKind` only reports on 26.4+.
        guard #available(macOS 26.4, *) else {
            try Test.cancel("the installed-probe half of the truth table requires macOS 26.4")
        }
        let model = await makeSUT()

        #expect(!livePlan(model).isAlternate, "the session selection is never alternate")

        model.translationSettings.selectRetranslate(.google)
        #expect(!livePlan(model).isAlternate, "an unconfigured external is not usable")

        try? model.translationSettings.saveKey("sk-google", for: .google)
        #expect(livePlan(model).isAlternate, "a keyed external resolves")

        // The probe never landed in this fixture: the live Apple identity is
        // UNKNOWN, so both Apple selections are alternates — the lane defers
        // to the landing instead of trusting the provisional `.appleFast`
        // read (which would misroute against a live hifi session).
        model.translationSettings.selectRetranslate(.appleFast)
        #expect(livePlan(model).isAlternate)
        model.translationSettings.selectRetranslate(.appleHighFidelity)
        #expect(livePlan(model).isAlternate)

        // Once the probe lands installed, the truth table resolves: the
        // live session IS Apple Intelligence, so the hifi selection is the
        // same engine and the fast selection is the alternate.
        model.appleHighFidelityProbe = (true, "en")
        #expect(livePlan(model).isAlternate == false, "the live session IS Apple Intelligence now")
        model.translationSettings.selectRetranslate(.appleFast)
        #expect(livePlan(model).isAlternate)
    }

    @Test("a duplicate external selection is not an alternate and routes through the session engine")
    func duplicateExternalSelectionUsesSessionEngine() async {
        let model = await makeSUT()
        let laneCalls = Mutex(0)
        model.retranslateEngineFactory = { _, _ in
            laneCalls.withLock { counter in counter += 1 }
            return LaneEchoEngine()
        }
        try? model.translationSettings.saveKey("sk-google", for: .google)
        model.translationSettings.selectRetranslate(.google)
        model.translationSession.activeExternalProvider = .google

        #expect(!livePlan(model).isAlternate)
        model.translationSession.activeExternalProvider = nil
        #expect(livePlan(model).isAlternate)
        model.translationSession.activeExternalProvider = .google

        model.phase = .running
        let (worker, queueEngine) = await attachWorker(model)
        defer { worker.cancel() }
        let sentence = makeSentence(index: 7)
        model.sessionController.onSentence?(sentence)
        #expect(
            await pollUntil(timeout: resultTimeout) { model.entries[0].joinedTranslations == "EN:テスト" },
            "the initial session translation is delivered before the retry"
        )

        model.retranslateSentence(sentence)

        #expect(
            await pollUntil(timeout: resultTimeout) {
                queueEngine.recordedBatches.count == 2
                    && model.entries[0].joinedTranslations == "EN:テスト"
                    && model.entries[0].translations.first?.engine == nil
            },
            "the queue's engine served the retry as a second unstamped flight"
        )
        #expect(laneCalls.withLock { counter in counter } == 0, "the lane factory is never consulted")
    }

    @Test(
        "an Apple selection matching the live session's de facto model degrades to the session engine",
        arguments: AppleSessionDegrade.allCases
    )
    func appleSelectionDegradesToSessionWhenLiveRunsSameKind(testCase: AppleSessionDegrade) async {
        let model = await makeSUT()
        model.appleHighFidelityProbe = testCase.probe
        let laneCalls = Mutex(0)
        model.retranslateEngineFactory = { provider, _ in
            laneCalls.withLock { counter in counter += 1 }
            #expect(provider == .google, "only external selections reach the factory")
            return LaneEchoEngine()
        }
        model.translationSettings.selectRetranslate(testCase.selection)
        model.phase = .running
        let (worker, queueEngine) = await attachWorker(model)
        defer { worker.cancel() }
        let sentence = makeSentence(index: 7)
        model.sessionController.onSentence?(sentence)
        #expect(
            await pollUntil(timeout: resultTimeout) { model.entries[0].joinedTranslations == "EN:テスト" },
            "the initial session translation is delivered before the retry"
        )

        model.retranslateSentence(sentence)

        #expect(
            await pollUntil(timeout: resultTimeout) {
                queueEngine.recordedBatches.count == 2
                    && model.entries[0].joinedTranslations == "EN:テスト"
                    && model.entries[0].translations.first?.engine == nil
            },
            "the queue's engine served the retry as a second unstamped flight"
        )
        #expect(laneCalls.withLock { counter in counter } == 0, "the lane factory is never consulted")
        #expect(model.retranslateHifiConfig == nil, "the degraded route never arms the hifi session")
    }

    @Test("a session-route retry with no attached worker reports instead of no-oping")
    func sessionRouteRetryWithoutWorkerPostsUnavailableToast() async {
        let model = await makeSUT()
        // The default selection is `.session`; no worker is attached (the
        // engine was released after a terminal failure).
        model.phase = .running
        let sentence = makeSentence(index: 4)
        model.sessionController.onSentence?(sentence)
        model.applyTranslation(index: 4, translation: SentenceTranslation(lang: "en", text: "Original"))

        model.retranslateSentence(sentence)

        let toast = model.toasts.toasts.first(where: { candidate in candidate.key == ToastKey.retranslate })
        #expect(toast?.title == "Re-translate unavailable")
        #expect(toast?.body == "No translation engine attached — try again in a moment.")
        #expect(model.pendingRetranslations.isEmpty, "no marker is set — nothing dangles")
    }

    // MARK: - High-fidelity probe

    @Test("an external activation re-probes high fidelity and degrades a persisted hifi selection")
    func externalActivationProbesHighFidelityAndDegradesHifi() async {
        // Hermetic transport: the activation builds a real Google engine (no
        // factory in this suite), and this test must stay one enqueued
        // sentence away from the live network.
        let model = await makeSUT(transport: constantStatusTransport(401))
        try? model.translationSettings.saveKey("sk-google", for: .google)
        model.translationSettings.select(.google)
        model.translationSettings.selectRetranslate(.appleHighFidelity)

        model.activateTranslation()
        defer { model.translationWorker?.cancel() }

        #expect(
            await pollUntil(timeout: resultTimeout) {
                model.appleHighFidelityProbe == (false, model.translationSettings.targetLanguage.code)
            },
            "the external activation lands the high-fidelity probe for the current pair"
        )
        #expect(
            livePlan(model).context.tier.highFidelityKnownUnavailable,
            "a landed not-installed probe is known unavailability, under any live engine"
        )
        #expect(
            livePlan(model).context.effectiveSelection == .appleFast,
            "the persisted hifi selection degrades once the probe lands unavailable"
        )
        #expect(
            livePlan(model).isAlternate,
            "the degraded fast selection is a genuine alternate against the external live session"
        )
    }

    // MARK: - Settings selection

    @Test("selecting an external re-translate engine raises the disclosure; on-device rows complete")
    func selectRetranslateEngineHoldsExternalBehindDisclosure() async {
        let model = await makeSUT()

        model.selectRetranslateEngine(.appleFast)
        #expect(model.translationSettings.retranslateEngine == .appleFast)
        #expect(model.providerAwaitingDisclosure == nil)

        model.selectRetranslateEngine(.appleHighFidelity)
        #expect(model.translationSettings.retranslateEngine == .appleHighFidelity)
        #expect(model.providerAwaitingDisclosure == nil)

        model.selectRetranslateEngine(.deepl)
        #expect(model.providerAwaitingDisclosure == .retranslateEngine(.deepl))
        #expect(
            model.translationSettings.retranslateEngine == .appleHighFidelity,
            "the selection is held until the disclosure confirms"
        )

        model.confirmCloudDisclosure(.retranslateEngine(.deepl))
        #expect(model.translationSettings.retranslateEngine == .deepl)
        #expect(model.providerAwaitingDisclosure == nil)
    }
}
