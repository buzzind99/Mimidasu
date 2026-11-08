import Foundation
@testable import Mimidasu
import Testing

/// Tests the dedicated Apple sessions behind the re-translate lane's
/// on-device selections: the fast (MTL) and Apple Intelligence arrival
/// hooks, arming, engine-stamped delivery through each armed session, and
/// the per-kind still-arming toasts.
@MainActor
@Suite("AppModel re-translate Apple lanes")
struct AppModelRetranslateAppleLaneTests {

    private let harness = RetranslateHarness(suite: "test.AppModelRetranslateAppleLane")
    private let resultTimeout: TimeInterval = 5

    /// The two dedicated Apple lanes' still-arming timeout: the fast model
    /// against a live Apple session, and Intelligence against an external
    /// live session so it stays a genuine alternate.
    enum StillArmingLane: String, CaseIterable, Sendable {
        case fast
        case highFidelity

        var selection: RetranslateEngine {
            switch self {
            case .fast: .appleFast
            case .highFidelity: .appleHighFidelity
            }
        }

        var usesExternalLiveSession: Bool {
            switch self {
            case .fast: false
            case .highFidelity: true
            }
        }

        var toastBody: String {
            switch self {
            case .fast: "Apple (NMT) session is still starting — try again in a moment."
            case .highFidelity: "Apple Intelligence session is still starting — try again in a moment."
            }
        }

        var armsFastConfig: Bool {
            switch self {
            case .fast: true
            case .highFidelity: false
            }
        }

        var armsHifiConfig: Bool {
            switch self {
            case .fast: false
            case .highFidelity: true
            }
        }
    }

    // MARK: - Session plumbing

    @Test(
        "an Apple lane's arrival hook stores its engine only while its config is armed",
        arguments: [TranslationEngineKind.appleFast, .appleHighFidelity]
    )
    func arrivalStoresEngineOnlyWhileArmed(kind: TranslationEngineKind) async {
        let model = await harness.makeModel()
        let target = model.translationSettings.targetLanguage.code

        // An unarmed config refuses the hand-over: a session for a lane that
        // was never armed must not be stored for the next lane to acquire
        // instantly.
        switch kind {
        case .appleFast:
            model.retranslate.retranslateSessionArrived(.appleFast, engine: LaneEchoEngine())
            #expect(model.retranslate.appleSessions.engine(for: .appleFast, target: target) == nil)
            model.retranslate.appleSessions.arm(kind: kind, target: target)
            model.retranslate.retranslateSessionArrived(.appleFast, engine: LaneEchoEngine())
            #expect(model.retranslate.appleSessions.engine(for: .appleFast, target: target) != nil)
            #expect(
                model.retranslate.appleSessions.engine(for: .appleHighFidelity, target: target) == nil,
                "the intelligence lane's slot is untouched"
            )
        case .appleHighFidelity:
            model.retranslate.retranslateSessionArrived(.appleHighFidelity, engine: LaneEchoEngine())
            #expect(model.retranslate.appleSessions.engine(for: .appleHighFidelity, target: target) == nil)
            model.retranslate.appleSessions.arm(kind: kind, target: target)
            model.retranslate.retranslateSessionArrived(.appleHighFidelity, engine: LaneEchoEngine())
            #expect(model.retranslate.appleSessions.engine(for: .appleHighFidelity, target: target) != nil)
            #expect(
                model.retranslate.appleSessions.engine(for: .appleFast, target: target) == nil,
                "the fast lane's slot is untouched"
            )
        default:
            Issue.record("unexpected Apple lane kind \(kind.rawValue)")
        }
    }

    @Test("arming an external kind arms no dedicated session")
    func armingExternalKindArmsNothing() async {
        let model = await harness.makeModel()

        model.retranslate.appleSessions.arm(kind: .google, target: model.translationSettings.targetLanguage.code)

        #expect(model.retranslate.fastSessionConfig == nil)
        #expect(model.retranslate.hifiSessionConfig == nil)
        #expect(
            model.retranslate.appleSessions.engine(for: .google, target: "en") == nil,
            "an external kind has no stored session to adopt"
        )
    }

    @Test("arming an already-armed kind never reassigns its config")
    func armingArmedKindKeepsConfig() async {
        let model = await harness.makeModel()
        model.retranslate.appleSessions.arm(kind: .appleFast, target: model.translationSettings.targetLanguage.code)
        let armed = model.retranslate.fastSessionConfig
        #expect(armed != nil)

        model.retranslate.appleSessions.arm(kind: .appleFast, target: model.translationSettings.targetLanguage.code)

        #expect(
            model.retranslate.fastSessionConfig == armed,
            "a reassignment would be a `.translationTask` re-fire gamble — the armed config stays put"
        )
    }

    // MARK: - Fast (MTL) lane

    @Test("apple fast stamps via the armed session and seeds the cache unstamped")
    func appleFastStampsViaArmedSession() async throws {
        // The probe-installed Apple identity only exists on 26.4+; below it
        // the fast selection degrades to the session path instead.
        guard #available(macOS 26.4, *) else {
            try Test.cancel("the armed fast lane requires macOS 26.4")
        }
        let model = await harness.makeModel()
        // A high-fidelity live session makes the fast model a real alternate.
        model.appleHighFidelityProbe = (true, "en")
        model.translationSettings.selectRetranslate(.appleFast)
        model.phase = .running
        let worker = await harness.attachWorker(model)
        defer { worker.cancel() }
        let sentence = makeSentence(index: 7)
        model.sessionController.onSentence?(sentence)
        #expect(
            await pollUntil(timeout: resultTimeout) { model.pane.entries[0].joinedTranslations == "EN:テスト" },
            "the initial session translation is delivered before the retry"
        )

        // No session engine yet: the lane arms the config and waits (bounded)
        // while the `.translationTask` host hands one over.
        model.retranslate.retranslateSentence(sentence)
        model.retranslate.retranslateSessionArrived(.appleFast, engine: LaneEchoEngine())

        #expect(
            await pollUntil(timeout: resultTimeout) {
                model.pane.entries[0].translations
                    == [SentenceTranslation(lang: "en", text: "JA:テスト", engine: .appleFast)]
            },
            "the fast-model result lands stamped"
        )
        #expect(model.retranslate.pendingRetranslations.isEmpty)
        #expect(model.retranslate.fastSessionConfig != nil, "the armed config survives a successful run")

        // A later repeat of the sentence (a fresh row) serves unstamped.
        model.sessionController.onSentence?(makeSentence(index: 9))
        let repeatEntry = model.pane.entries.first(where: { entry in entry.sentence.index == 9 })
        #expect(repeatEntry?.translations == [SentenceTranslation(lang: "en", text: "JA:テスト")])
        #expect(repeatEntry?.translations.first?.engine == nil, "the seed is unstamped")
    }

    @Test(
        "a still-arming Apple session posts its own starting toast",
        arguments: StillArmingLane.allCases
    )
    func stillArmingSessionPostsStartingToast(testCase: StillArmingLane) async throws {
        guard #available(macOS 26.4, *) else {
            try Test.cancel("the armed Apple lane requires macOS 26.4")
        }
        let model = await harness.makeModel()
        if testCase.usesExternalLiveSession {
            model.translationSession.activeTranslationEngine = .external
            model.translationSession.activeExternalProvider = .google
        }
        model.appleHighFidelityProbe = (true, "en")
        model.translationSettings.selectRetranslate(testCase.selection)
        model.phase = .running
        let sentence = makeSentence(index: 7)
        model.sessionController.onSentence?(sentence)
        model.applyTranslation(index: 7, translation: SentenceTranslation(lang: "en", text: "Original"))

        // No engine ever arrives; the bounded wait runs out on its own (a
        // short injected bound, so the timeout is exercised for real — task
        // cancellation is the separate `.cancelled` outcome, covered below).
        model.retranslate.laneArmTimeout = .milliseconds(50)
        model.retranslate.retranslateSentence(sentence)

        #expect(
            await pollUntil(timeout: resultTimeout) {
                model.retranslate.pendingRetranslations.isEmpty
            },
            "the timed-out wait retires the markers"
        )
        let toast = model.toasts.toasts.first(where: { candidate in candidate.key == ToastKey.retranslate })
        #expect(toast?.title == "Re-translate unavailable")
        #expect(toast?.body == testCase.toastBody)
        #expect(
            model.pane.entries[0].translations == [SentenceTranslation(lang: "en", text: "Original")],
            "the row keeps its previous translation"
        )
        #expect(
            (model.retranslate.fastSessionConfig != nil) == testCase.armsFastConfig,
            "the fast config stays armed exactly for its own lane"
        )
        #expect(
            (model.retranslate.hifiSessionConfig != nil) == testCase.armsHifiConfig,
            "the hifi config stays armed exactly for its own lane"
        )
    }

    // MARK: - Apple Intelligence lane

    @Test("apple intelligence stamps via its armed session and arms only the hifi config")
    func appleIntelligenceStampsViaArmedSession() async throws {
        guard #available(macOS 26.4, *) else {
            try Test.cancel("the armed hifi lane requires macOS 26.4")
        }
        let model = await harness.makeModel()
        // An EXTERNAL live session, so a high-fidelity retry is a genuine
        // alternate at every stage of the probe — a live Apple session would
        // take the session path once a landed-installed probe reveals it
        // already runs the Intelligence model. (A probe that landed
        // not-installed would degrade the selection to `.appleFast` instead
        // — see `unavailableHighFidelityDegradesToFast`.)
        model.translationSession.activeTranslationEngine = .external
        model.translationSession.activeExternalProvider = .google
        model.translationSettings.selectRetranslate(.appleHighFidelity)
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
        // The probe lands installed mid-lane: the pair genuinely serves the
        // Intelligence model, so the deferred lane flies as armed.
        model.appleHighFidelityProbe = (true, "en")
        model.retranslate.retranslateSessionArrived(.appleHighFidelity, engine: LaneEchoEngine())

        #expect(
            await pollUntil(timeout: resultTimeout) {
                model.pane.entries[0].translations
                    == [SentenceTranslation(lang: "en", text: "JA:テスト", engine: .appleHighFidelity)]
            },
            "the Apple Intelligence result lands stamped"
        )
        #expect(model.retranslate.pendingRetranslations.isEmpty)
        #expect(model.retranslate.hifiSessionConfig != nil, "the armed hifi config survives a successful run")
        #expect(model.retranslate.fastSessionConfig == nil, "the fast lane's session is never armed")
    }

    @Test("a cancelled wait retires the markers without reporting a starting session")
    func cancelledWaitRetiresMarkersSilently() async throws {
        // Below 26.4 the fast selection resolves to the session path (or
        // no-ops outright), never to an armed lane — the whole scenario
        // would be vacuous.
        guard #available(macOS 26.4, *) else {
            try Test.cancel("the armed fast lane requires macOS 26.4")
        }
        let model = await harness.makeModel()
        model.appleHighFidelityProbe = (true, "en")
        model.translationSettings.selectRetranslate(.appleFast)
        model.phase = .running
        let sentence = makeSentence(index: 7)
        model.sessionController.onSentence?(sentence)
        model.applyTranslation(index: 7, translation: SentenceTranslation(lang: "en", text: "Original"))

        // A long bound, so a working cancellation is the only way the wait
        // ends promptly; the phase stays live, so a timeout would post the
        // still-starting toast and fail the assertion below.
        model.retranslate.laneArmTimeout = .seconds(30)
        model.retranslate.retranslateSentence(sentence)
        let start = ContinuousClock.now
        model.retranslate.cancelNewestLaneLink()
        _ = await model.retranslate.waitForLaneChainIdle()

        #expect(ContinuousClock.now - start < .seconds(5), "the wait must cancel, not time out")
        #expect(
            model.retranslate.pendingRetranslations.isEmpty,
            "a cancelled wait still retires the markers"
        )
        #expect(
            model.toasts.toasts.allSatisfy { candidate in candidate.key != ToastKey.retranslate },
            "a cancellation is not a timeout — the stop already cleared the toasts"
        )
    }

    @Test("a cancelled probe deferral retires the markers without reporting")
    func cancelledProbeDeferralRetiresMarkersSilently() async throws {
        // Below 26.4 the Apple-kind click has no probe gate to defer on.
        guard #available(macOS 26.4, *) else {
            try Test.cancel("the probe-deferred fast lane requires macOS 26.4")
        }
        let model = await harness.makeModel()
        // The probe stays unlanded: an Apple-kind retry has no live
        // identity to route on, so it defers at the probe gate.
        model.translationSettings.selectRetranslate(.appleFast)
        model.phase = .running
        let sentence = makeSentence(index: 7)
        model.sessionController.onSentence?(sentence)
        model.applyTranslation(index: 7, translation: SentenceTranslation(lang: "en", text: "Original"))

        model.retranslate.retranslateSentence(sentence)
        #expect(model.retranslate.pendingRetranslations == [7], "the click marks the row")
        let start = ContinuousClock.now
        model.retranslate.cancelNewestLaneLink()
        _ = await model.retranslate.waitForLaneChainIdle()

        #expect(ContinuousClock.now - start < .seconds(2), "the deferral must cancel, not time out")
        #expect(
            model.retranslate.pendingRetranslations.isEmpty,
            "a cancelled deferral retires the markers"
        )
        #expect(
            model.toasts.toasts.allSatisfy { candidate in candidate.key != ToastKey.retranslate },
            "a cancellation is not a timeout — no report is posted"
        )
        #expect(
            model.pane.entries[0].translations == [SentenceTranslation(lang: "en", text: "Original")],
            "the row keeps its previous translation"
        )
    }

    @Test("a stop cancels a parked arm wait without reporting")
    func stopCancelsParkedArmWaitSilently() async throws {
        guard #available(macOS 26.4, *) else {
            try Test.cancel("the armed fast lane requires macOS 26.4")
        }
        let model = await harness.makeModel()
        model.appleHighFidelityProbe = (true, "en")
        model.translationSettings.selectRetranslate(.appleFast)
        model.phase = .running
        let worker = await harness.attachWorker(model)
        defer { worker.cancel() }
        let first = makeSentence(index: 1, text: "一")
        let second = makeSentence(index: 2, text: "二")
        model.sessionController.onSentence?(first)
        model.sessionController.onSentence?(second)
        // Settle the initial deliveries: they keep a stop's translation-tail
        // drain instant. An unserved backlog would spin the drain's whole
        // bounded timeout, and the lane's expiry would then land DURING the
        // stop (phase still live) — the toast would be removed by the
        // stop's clearAll, not refused by the delivery guard under test.
        #expect(
            await pollUntil(timeout: resultTimeout) {
                model.pane.entries[0].translations == [SentenceTranslation(lang: "en", text: "EN:一")]
                    && model.pane.entries[1].translations == [SentenceTranslation(lang: "en", text: "EN:二")]
            },
            "the initial translations are delivered before the retries"
        )

        // Two chained waits: the stop's teardown resolves both as cancelled,
        // so neither reaches its timeout. Waiting for the chain to idle
        // proves the cancellation propagated and nothing reposted over the
        // cleared stack.
        model.retranslate.laneArmTimeout = .milliseconds(500)
        model.retranslate.retranslateSentence(first)
        model.retranslate.retranslateSentence(second)
        await model.performStop()
        _ = await model.retranslate.waitForLaneChainIdle()
        #expect(
            !model.toasts.toasts.contains(where: { toast in toast.key == ToastKey.retranslate }),
            "a cancelled wait whose session is gone posts nothing"
        )
        #expect(model.retranslate.pendingRetranslations.isEmpty)
        #expect(
            model.pane.entries[0].translations == [SentenceTranslation(lang: "en", text: "EN:一")],
            "the expired wait never touched its row"
        )
    }

    // MARK: - Unavailable high fidelity

    @Test("an intelligence selection the OS cannot serve degrades to the fast model")
    func unavailableHighFidelityDegradesToFast() async {
        let model = await harness.makeModel()
        model.translationSettings.selectRetranslate(.appleHighFidelity)
        // The probe landed not-installed for this pair: requesting high
        // fidelity anyway would silently return the fast model's text while
        // stamping the row "Apple Intelligence".
        model.appleHighFidelityProbe = (false, "en")
        // An external live session, so the degraded fast selection is a
        // genuine alternate (a live fast Apple session would be served by the
        // session engine instead).
        model.translationSession.activeTranslationEngine = .external
        model.translationSession.activeExternalProvider = .google
        model.phase = .running
        let worker = await harness.attachWorker(model)
        defer { worker.cancel() }
        let sentence = makeSentence(index: 3)
        model.sessionController.onSentence?(sentence)
        #expect(
            await pollUntil(timeout: resultTimeout) { model.pane.entries[0].joinedTranslations == "EN:テスト" },
            "the initial session translation is delivered before the retry"
        )

        let plan = model.retranslatePlan(
            surface: .live, target: model.translationSettings.targetLanguage
        )
        #expect(plan.context.effectiveSelection == .appleFast)
        #expect(plan.route == .lane(.appleFast), "the degrade routes through the fast lane")

        model.retranslate.retranslateSentence(sentence)
        model.retranslate.retranslateSessionArrived(.appleFast, engine: LaneEchoEngine())

        #expect(
            await pollUntil(timeout: resultTimeout) {
                model.pane.entries[0].translations
                    == [SentenceTranslation(lang: "en", text: "JA:テスト", engine: .appleFast)]
            },
            "the row lands stamped with the model that actually ran"
        )
        #expect(model.retranslate.fastSessionConfig != nil, "the fast lane is the one armed")
        #expect(model.retranslate.hifiSessionConfig == nil, "the high-fidelity session is never armed")
        #expect(
            model.translationSettings.retranslateEngine == .appleHighFidelity,
            "the persisted selection is not rewritten — only its resolution degrades"
        )
    }
}
