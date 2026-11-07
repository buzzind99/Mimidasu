import Foundation
@testable import Mimidasu
import Testing

/// Tests the probe-deferral gate at the head of a lane task: while the
/// activation probe is unlanded the live session's model identity is
/// unknown, so high-fidelity lanes wait bounded for the landing and the
/// landing re-routes (session hand-over, degrade-to-fast) or times out.
@MainActor
@Suite("AppModel re-translate probe deferral")
struct AppModelRetranslateProbeTests {

    private let harness = RetranslateHarness(suite: "test.AppModelRetranslateProbe")
    private let resultTimeout: TimeInterval = 5

    /// The live plan's route for the current settings target — the decision
    /// the click executes and the probe landing re-plans.
    private func liveRoute(_ model: AppModel) -> RetranslateRoute {
        model.retranslatePlan(
            surface: .live, target: model.translationSettings.targetLanguage
        ).route
    }

    // MARK: - Probe deferral

    @Test("a fast retry during a pending probe flies the dedicated fast session, not the live one")
    func pendingProbeFastRetryFliesDedicatedSession() async throws {
        guard #available(macOS 26.4, *) else {
            try Test.cancel("the provisional-identity defer requires macOS 26.4")
        }
        let model = await harness.makeModel()
        // Live Apple, probe UNLANDED: the identity is unknown. The retry
        // must not take the session path on the provisional `.appleFast`
        // read — the live session may actually run high fidelity, whose
        // text would land unstamped over a fast request.
        model.translationSettings.selectRetranslate(.appleFast)
        #expect(
            liveRoute(model) == .lane(.appleFast),
            "the unlanded identity routes the fast retry to its dedicated lane"
        )
        model.phase = .running
        let worker = await harness.attachWorker(model)
        defer { worker.cancel() }
        let sentence = makeSentence(index: 7)
        model.sessionController.onSentence?(sentence)
        #expect(
            await pollUntil(timeout: resultTimeout) { model.pane.entries[0].joinedTranslations == "EN:テスト" },
            "the initial session translation is delivered before the retry"
        )

        model.retranslate.retranslateSentence(sentence)
        #expect(model.retranslate.fastSessionConfig != nil, "the click arms the dedicated fast session")
        // The probe lands installed — the live session turns out to run the
        // Intelligence model. The dedicated fast lane flies anyway: a
        // genuine alternate, stamped so.
        model.appleHighFidelityProbe = (true, "en")
        #expect(
            liveRoute(model) == .lane(.appleFast),
            "the landed hifi identity leaves the fast lane a genuine alternate"
        )
        model.retranslate.retranslateSessionArrived(.appleFast, engine: LaneEchoEngine())

        #expect(
            await pollUntil(timeout: resultTimeout) {
                model.pane.entries[0].translations
                    == [SentenceTranslation(lang: "en", text: "JA:テスト", engine: .appleFast)]
            },
            "the fast-model result lands stamped even though the live session is hifi"
        )
        #expect(model.retranslate.pendingRetranslations.isEmpty)
    }

    @Test("a fast retry during a pending probe is served by the session once the probe rules the live session fast")
    func pendingProbeFastRetryServedBySessionWhenProbeSaysFast() async throws {
        guard #available(macOS 26.4, *) else {
            try Test.cancel("the provisional-identity defer requires macOS 26.4")
        }
        let model = await harness.makeModel()
        model.translationSettings.selectRetranslate(.appleFast)
        #expect(
            liveRoute(model) == .lane(.appleFast),
            "the unlanded identity routes the fast retry to its dedicated lane"
        )
        model.phase = .running
        let worker = await harness.attachWorker(model)
        defer { worker.cancel() }
        let sentence = makeSentence(index: 7)
        model.sessionController.onSentence?(sentence)
        #expect(
            await pollUntil(timeout: resultTimeout) { model.pane.entries[0].joinedTranslations == "EN:テスト" },
            "the initial session translation is delivered before the retry"
        )

        model.retranslate.retranslateSentence(sentence)
        #expect(model.retranslate.fastSessionConfig != nil)
        // The probe lands NOT installed — the live session runs the fast
        // model, i.e. the engine the retry asked for. The lane hands the
        // retry to the session path instead of flying a duplicate.
        model.appleHighFidelityProbe = (false, "en")
        #expect(
            liveRoute(model) == .session,
            "the landed fast identity makes the session the same-engine route"
        )

        #expect(
            await pollUntil(timeout: resultTimeout) {
                model.retranslate.pendingRetranslations.isEmpty
            },
            "the deferred retry landed and retired its markers"
        )
        #expect(
            model.pane.entries[0].joinedTranslations == "EN:テスト",
            "the session path re-served the retry unstamped"
        )
        #expect(
            model.pane.entries[0].translations.first?.engine == nil,
            "a session-path result carries no provenance"
        )
    }

    @Test("a deferred intelligence retry on a live Apple session is served by the session once the probe confirms hifi")
    func deferredHifiRetryOnLiveAppleServedBySession() async throws {
        guard #available(macOS 26.4, *) else {
            try Test.cancel("the provisional-identity defer requires macOS 26.4")
        }
        let model = await harness.makeModel()
        model.translationSettings.selectRetranslate(.appleHighFidelity)
        #expect(
            liveRoute(model) == .lane(.appleHighFidelity),
            "the unlanded identity routes the hifi retry to its dedicated lane"
        )
        model.phase = .running
        let worker = await harness.attachWorker(model)
        defer { worker.cancel() }
        let sentence = makeSentence(index: 7)
        model.sessionController.onSentence?(sentence)
        #expect(
            await pollUntil(timeout: resultTimeout) { model.pane.entries[0].joinedTranslations == "EN:テスト" },
            "the initial session translation is delivered before the retry"
        )

        model.retranslate.retranslateSentence(sentence)
        #expect(model.retranslate.hifiSessionConfig != nil, "the click arms the hifi lane on the pending probe")
        // The probe lands installed: the live Apple session itself runs the
        // Intelligence model — the retry asked for the engine the session
        // already is. Flying a second hifi session would return
        // byte-identical text with the marker suppressed; the queue serves
        // instead.
        model.appleHighFidelityProbe = (true, "en")
        #expect(
            liveRoute(model) == .session,
            "the landed hifi identity makes the session the same-engine route"
        )

        #expect(
            await pollUntil(timeout: resultTimeout) {
                model.retranslate.pendingRetranslations.isEmpty
            },
            "the handed-off retry landed and retired its markers"
        )
        #expect(
            model.pane.entries[0].joinedTranslations == "EN:テスト",
            "the session path re-served the retry unstamped"
        )
        #expect(model.pane.entries[0].translations.first?.engine == nil)
    }

    @Test("a landing that degrades the selection arms and flies the fast lane")
    func probeLandingDegradesToFastLane() async throws {
        guard #available(macOS 26.4, *) else {
            try Test.cancel("the provisional-identity defer requires macOS 26.4")
        }
        let model = await harness.makeModel()
        // External live session: both Apple models are genuine alternates.
        model.translationSession.activeTranslationEngine = .external
        model.translationSession.activeExternalProvider = .google
        model.translationSettings.selectRetranslate(.appleHighFidelity)
        #expect(
            liveRoute(model) == .lane(.appleHighFidelity),
            "the unlanded identity routes the hifi retry to its dedicated lane"
        )
        model.phase = .running
        let worker = await harness.attachWorker(model)
        defer { worker.cancel() }
        let sentence = makeSentence(index: 7)
        model.sessionController.onSentence?(sentence)
        #expect(
            await pollUntil(timeout: resultTimeout) { model.pane.entries[0].joinedTranslations == "EN:テスト" },
            "the initial session translation is delivered before the retry"
        )

        model.retranslate.retranslateSentence(sentence)
        #expect(model.retranslate.hifiSessionConfig != nil, "the click armed the hifi lane on the pending probe")
        // A stale hifi hand-over arrives before the probe lands: the
        // degraded lane must not fly it — it belongs to the abandoned
        // high-fidelity generation. The landing re-reads the (newly armed)
        // fast lane's own storage instead.
        let staleHifiEngine = LaneEchoEngine()
        model.retranslate.retranslateSessionArrived(.appleHighFidelity, engine: staleHifiEngine)
        // The probe lands NOT installed: the selection degrades to the fast
        // model. The lane arms the fast lane and flies IT — stamping the
        // model that actually ran, never hifi over fallback-fast text. The
        // engine arrives only after the arming is observable, mirroring the
        // `.translationTask` host, which fires on the config's appearance.
        model.appleHighFidelityProbe = (false, "en")
        #expect(
            liveRoute(model) == .lane(.appleFast),
            "the landed degrade re-plans the click to the fast lane"
        )
        #expect(
            await pollUntil(timeout: resultTimeout) { model.retranslate.fastSessionConfig != nil },
            "the degrade armed the fast lane"
        )
        model.retranslate.retranslateSessionArrived(.appleFast, engine: LaneEchoEngine())

        #expect(
            await pollUntil(timeout: resultTimeout) {
                model.pane.entries[0].translations
                    == [SentenceTranslation(lang: "en", text: "JA:テスト", engine: .appleFast)]
            },
            "the degraded lane lands stamped with the fast model"
        )
        #expect(
            staleHifiEngine.recordedBatches.isEmpty,
            "the abandoned high-fidelity engine is never flown"
        )
        #expect(model.retranslate.pendingRetranslations.isEmpty)
        #expect(
            model.translationSettings.retranslateEngine == .appleHighFidelity,
            "the persisted selection is not rewritten — only its resolution degrades"
        )
    }

    @Test("a mid-session teardown cancels a parked probe wait without reporting")
    func teardownDuringPendingProbeRetiresSilently() async throws {
        guard #available(macOS 26.4, *) else {
            try Test.cancel("the provisional-identity defer requires macOS 26.4")
        }
        let model = await harness.makeModel()
        model.translationSession.activeTranslationEngine = .external
        model.translationSession.activeExternalProvider = .google
        model.translationSettings.selectRetranslate(.appleHighFidelity)
        #expect(
            liveRoute(model) == .lane(.appleHighFidelity),
            "the unlanded identity routes the hifi retry to its dedicated lane"
        )
        model.phase = .running
        let sentence = makeSentence(index: 7)
        model.sessionController.onSentence?(sentence)
        model.applyTranslation(index: 7, translation: SentenceTranslation(lang: "en", text: "Original"))

        // The lane parks in the probe wait; an Apple activation's teardown
        // cancels the task out of the wait itself. The cancellation must
        // exit silently — the teardown's toast stack is the user's chosen
        // activation, not a failure surface.
        model.retranslate.retranslateSentence(sentence)
        #expect(
            await pollUntil(timeout: resultTimeout) { model.retranslate.pendingRetranslations.count == 1 },
            "the deferred lane owns the marker"
        )
        model.cancelArchiveTranslation(); model.retranslate.teardown()

        #expect(
            await pollUntil(timeout: resultTimeout) {
                model.retranslate.pendingRetranslations.isEmpty
            },
            "the cancelled wait retires the markers"
        )
        #expect(
            !model.toasts.toasts.contains(where: { toast in toast.key == ToastKey.retranslate }),
            "a cancelled wait reports nothing"
        )
        #expect(
            model.pane.entries[0].translations == [SentenceTranslation(lang: "en", text: "Original")],
            "the row keeps its previous translation"
        )
    }

    @Test("a hand-over to the session without a worker posts the unavailable toast")
    func handoffWithoutWorkerPostsUnavailableToast() async throws {
        guard #available(macOS 26.4, *) else {
            try Test.cancel("the provisional-identity defer requires macOS 26.4")
        }
        let model = await harness.makeModel()
        model.translationSettings.selectRetranslate(.appleFast)
        #expect(
            liveRoute(model) == .lane(.appleFast),
            "the unlanded identity routes the fast retry to its dedicated lane"
        )
        model.phase = .running
        let sentence = makeSentence(index: 7)
        model.sessionController.onSentence?(sentence)
        model.applyTranslation(index: 7, translation: SentenceTranslation(lang: "en", text: "Original"))

        // Live Apple, probe unlanded, NO queue worker: the click defers on
        // the unknown identity, and the landing resolves the live session
        // as the fast model — the queue path — whose worker is missing.
        model.retranslate.retranslateSentence(sentence)
        #expect(
            await pollUntil(timeout: resultTimeout) { model.retranslate.pendingRetranslations.count == 1 },
            "the deferred lane owns the marker"
        )
        model.appleHighFidelityProbe = (false, "en")
        #expect(
            liveRoute(model) == .session,
            "the landed fast identity hands the retry to the session path"
        )

        #expect(
            await pollUntil(timeout: resultTimeout) {
                model.retranslate.pendingRetranslations.isEmpty
            },
            "the failed hand-over retires the markers"
        )
        let toast = model.toasts.toasts.first(where: { candidate in candidate.key == ToastKey.retranslate })
        #expect(toast?.title == "Re-translate unavailable")
        #expect(toast?.body == "No translation engine attached — try again in a moment.")
        #expect(
            model.pane.entries[0].translations == [SentenceTranslation(lang: "en", text: "Original")],
            "the row keeps its previous translation"
        )
    }

    @Test("a probe that never lands within the bound retires the markers and reports the check")
    func pendingProbeTimeoutPostsCheckingToast() async throws {
        guard #available(macOS 26.4, *) else {
            try Test.cancel("the provisional-identity defer requires macOS 26.4")
        }
        let model = await harness.makeModel()
        model.translationSession.activeTranslationEngine = .external
        model.translationSession.activeExternalProvider = .google
        model.translationSettings.selectRetranslate(.appleHighFidelity)
        #expect(
            liveRoute(model) == .lane(.appleHighFidelity),
            "the unlanded identity routes the hifi retry to its dedicated lane"
        )
        model.phase = .running
        let sentence = makeSentence(index: 7)
        model.sessionController.onSentence?(sentence)
        model.applyTranslation(index: 7, translation: SentenceTranslation(lang: "en", text: "Original"))

        // The probe never lands; the deferral runs out on its own (a short
        // injected bound, so the timeout is exercised for real).
        model.retranslate.probeSettleTimeout = .milliseconds(80)
        model.retranslate.retranslateSentence(sentence)

        #expect(
            await pollUntil(timeout: resultTimeout) {
                model.retranslate.pendingRetranslations.isEmpty
            },
            "the timed-out deferral retires the markers"
        )
        let toast = model.toasts.toasts.first(where: { candidate in candidate.key == ToastKey.retranslate })
        #expect(toast?.title == "Re-translate unavailable")
        #expect(
            toast?.body == "Still checking Apple Intelligence availability — try again in a moment."
        )
        #expect(
            model.pane.entries[0].translations == [SentenceTranslation(lang: "en", text: "Original")],
            "the row keeps its previous translation"
        )
        #expect(
            model.retranslate.hifiSessionConfig != nil,
            "the config stays armed — the next click reuses it once the probe lands"
        )
    }
}
