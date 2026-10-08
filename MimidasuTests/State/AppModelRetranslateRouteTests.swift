import Foundation
@testable import Mimidasu
import Synchronization
import Testing

/// Tests the re-translate lane's route resolution and settings surface:
/// `alternateRetranslateEngineActive`, the Apple selections' de facto
/// degradation, the duplicate-external degradation, the armed dedicated
/// Apple sessions' teardown at stop, the high-fidelity probe an external
/// activation fires, and the cloud disclosure that holds an external
/// selection.
@MainActor
@Suite("AppModel re-translate routes")
struct AppModelRetranslateRouteTests {

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
        let model = AppModel(
            translationSettings: isolatedTranslationSettings(suite: "test.AppModelRetranslateRoute"),
            asrModelSettings: isolatedASRModelSettings(suite: "test.AppModelRetranslateRoute"),
            favorites: isolatedFavorites(),
            translationTransport: transport,
            highFidelityProbe: { _ in false },
            initialModelResolve: { _ in nil }
        )
        await model.initialModelCheck?.value
        return model
    }

    private func makeSentence(
        index: Int, text: String = "テスト"
    ) -> Sentence {
        Sentence(index: index, startS: 0, endS: 1, lang: "ja", text: text)
    }

    /// Attaches a queue worker the way `activateTranslation` does, so the
    /// session-engine path can serve a retry. Returns the engine too: the
    /// degrade tests must pin that the retry actually flew the queue a
    /// second time, and a row condition alone cannot tell a served retry
    /// from the untouched initial delivery.
    private func attachWorker(
        _ model: AppModel
    ) async -> (worker: Task<Void, Never>, engine: QueueEchoEngine) {
        let engine = QueueEchoEngine()
        let worker = Task { await model.translationQueue.run(with: engine) }
        #expect(
            await pollUntil(timeout: resultTimeout) { model.translationQueue.hasWorker },
            "the queue worker must be attached before a retry can be served"
        )
        return (worker, engine)
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

    // MARK: - Route resolution

    @Test("alternate-engine active tracks the selection and key state")
    func alternateEngineActiveTracksSelection() async throws {
        // The second half of the truth table pivots on the probe-installed
        // Apple identity, which `activeEngineKind` only reports on 26.4+.
        guard #available(macOS 26.4, *) else {
            try Test.cancel("the installed-probe half of the truth table requires macOS 26.4")
        }
        let model = await makeSUT()

        #expect(!model.alternateRetranslateEngineActive, "the session selection is never alternate")

        model.translationSettings.selectRetranslate(.google)
        #expect(!model.alternateRetranslateEngineActive, "an unconfigured external is not usable")

        try? model.translationSettings.saveKey("sk-google", for: .google)
        #expect(model.alternateRetranslateEngineActive, "a keyed external resolves")

        // The probe never landed in this fixture: the live Apple identity is
        // UNKNOWN, so both Apple selections are alternates — the lane defers
        // to the landing instead of trusting the provisional `.appleFast`
        // read (which would misroute against a live hifi session).
        model.translationSettings.selectRetranslate(.appleFast)
        #expect(model.alternateRetranslateEngineActive)
        model.translationSettings.selectRetranslate(.appleHighFidelity)
        #expect(model.alternateRetranslateEngineActive)

        // Once the probe lands installed, the truth table resolves: the
        // live session IS Apple Intelligence, so the hifi selection is the
        // same engine and the fast selection is the alternate.
        model.appleHighFidelityProbe = (true, "en")
        #expect(model.alternateRetranslateEngineActive == false, "the live session IS Apple Intelligence now")
        model.translationSettings.selectRetranslate(.appleFast)
        #expect(model.alternateRetranslateEngineActive)
    }

    @Test("a retranslate selection naming the attached provider is not an alternate")
    func duplicateExternalSelectionIsNotAlternate() async {
        let model = await makeSUT()
        try? model.translationSettings.saveKey("sk-google", for: .google)
        model.translationSettings.selectRetranslate(.google)
        model.activeExternalProvider = .google

        #expect(!model.alternateRetranslateEngineActive)

        model.activeExternalProvider = nil
        #expect(model.alternateRetranslateEngineActive)
    }

    @Test("apple intelligence with a de facto hifi live session degrades to the session engine")
    func appleIntelligenceDegradesToSessionWhenDeFactoHifi() async {
        let model = await makeSUT()
        model.appleHighFidelityProbe = (true, "en")
        let laneCalls = Mutex(0)
        model.retranslateEngineFactory = { provider in
            laneCalls.withLock { counter in counter += 1 }
            #expect(provider == .google, "only external selections reach the factory")
            return LaneEchoEngine()
        }
        model.translationSettings.selectRetranslate(.appleHighFidelity)
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

        // A second flight through the queue's engine is the retry: the row
        // condition alone is already true from the initial delivery.
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

    @Test("a duplicate external selection routes through the session engine")
    func duplicateExternalSelectionRoutesToSession() async {
        let model = await makeSUT()
        let laneCalls = Mutex(0)
        model.retranslateEngineFactory = { _ in
            laneCalls.withLock { counter in counter += 1 }
            return LaneEchoEngine()
        }
        try? model.translationSettings.saveKey("sk-google", for: .google)
        model.translationSettings.selectRetranslate(.google)
        model.activeExternalProvider = .google
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

    @Test("apple fast with a de facto fast live session degrades to the session engine")
    func appleFastDegradesToSessionWhenDeFactoFast() async {
        let model = await makeSUT()
        // LANDED not-installed: the live Apple session runs the fast model
        // (the framework fell back), so a fast selection names the session's
        // own engine. An UNLANDED probe would defer to the dedicated fast
        // lane instead — the identity must be known to call it the same
        // engine.
        model.appleHighFidelityProbe = (false, "en")
        let laneCalls = Mutex(0)
        model.retranslateEngineFactory = { provider in
            laneCalls.withLock { counter in counter += 1 }
            #expect(provider == .google, "only external selections reach the factory")
            return LaneEchoEngine()
        }
        model.translationSettings.selectRetranslate(.appleFast)
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

    @Test("an unconfigured external without the factory falls back to the unavailable toast")
    func unconfiguredExternalWithoutFactoryPostsUnavailableToast() async {
        let model = await makeSUT()
        // No factory, no key: the real engine builder resolves to nil.
        model.translationSettings.selectRetranslate(.google)
        model.phase = .running
        let sentence = makeSentence(index: 7)
        model.sessionController.onSentence?(sentence)
        model.applyTranslation(index: 7, translation: SentenceTranslation(lang: "en", text: "Original"))

        model.retranslateSentence(sentence)

        #expect(model.pendingRetranslations.isEmpty, "no marker: nothing is in flight")
        let toast = model.toasts.toasts.first(where: { candidate in candidate.key == ToastKey.retranslate })
        #expect(toast?.title == "Re-translate unavailable")
        #expect(toast?.body == "No API key stored for \(TranslationProvider.google.displayName).")
        #expect(
            model.entries[0].translations == [SentenceTranslation(lang: "en", text: "Original")],
            "the row keeps its previous translation"
        )
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
            model.highFidelityKnownUnavailable,
            "a landed not-installed probe is known unavailability, under any live engine"
        )
        #expect(
            model.effectiveRetranslateSelection == .appleFast,
            "the persisted hifi selection degrades once the probe lands unavailable"
        )
        #expect(
            model.alternateRetranslateEngineActive,
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

/// Lane fixture: prefixes every input with "JA:", recording each batch.
final class LaneEchoEngine: TranslationEngine, @unchecked Sendable {
    let preferredBatchSize = 4
    var onRetry: (@Sendable (RetryProgress) -> Void)?

    private let state = Mutex([[String]]())

    var recordedBatches: [[String]] {
        state.withLock { batches in batches }
    }

    func translate(_ texts: [String]) async throws -> [String] {
        state.withLock { batches in batches.append(texts) }
        return texts.map { text in "JA:\(text)" }
    }
}

/// Session-engine fixture for the degrade tests: prefixes with "EN:",
/// recording each batch so a test can pin how many flights the queue
/// actually ran.
private final class QueueEchoEngine: TranslationEngine, @unchecked Sendable {
    let preferredBatchSize = 16
    var onRetry: (@Sendable (RetryProgress) -> Void)?

    private let state = Mutex([[String]]())

    var recordedBatches: [[String]] {
        state.withLock { batches in batches }
    }

    func translate(_ texts: [String]) async throws -> [String] {
        state.withLock { batches in batches.append(texts) }
        return texts.map { text in "EN:\(text)" }
    }
}
