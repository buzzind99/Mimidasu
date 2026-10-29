@testable import Mimidasu
import Testing

@MainActor
@Suite("RetranslatePlanContextTests")
struct RetranslatePlanContextTests {
    private let harness = RetranslateHarness(suite: "test.RetranslatePlanContext")

    private func makeModel() async -> AppModel {
        await harness.makeModel()
    }

    @Test("copies the persisted re-translate selection and target")
    func copiesSettingsSelectionAndTarget() async {
        let model = await makeModel()
        model.translationSettings.selectRetranslate(.deepl)
        model.translationSettings.select(TargetLanguage(code: "de"))

        let plan = model.retranslatePlan(
            surface: .live,
            target: model.translationSettings.targetLanguage
        )

        #expect(plan.context.selection == .deepl)
        #expect(plan.context.effectiveSelection == .deepl)
        #expect(plan.context.target == TargetLanguage(code: "de"))
    }

    @Test("passes an explicit picker selection through")
    func explicitSelectionPassedThrough() async {
        let model = await makeModel()
        model.translationSettings.selectRetranslate(.session)

        let plan = model.retranslatePlan(surface: .archive, target: .english, selection: .google)

        #expect(plan.context.selection == .google)
        #expect(plan.context.effectiveSelection == .google)
    }

    @Test("the row facade returns the plan's row")
    func rowFacadeMatchesPlan() async {
        let model = await makeModel()
        let entry = SessionEntry(sentence: makeSentence(index: 2))
        let plan = model.retranslatePlan(surface: .live, target: .english)

        let row = model.retranslateRowPlan(for: entry, surface: .live, target: .english)

        #expect(row == plan.row(for: entry))
    }

    @Test("copies the target's probe evidence")
    func copiesTierFacts() async {
        let model = await makeModel()
        model.appleHighFidelityProbe = (installed: false, targetCode: "en")

        let plan = model.retranslatePlan(surface: .live, target: .english)

        #expect(plan.context.tier.highFidelityKnownUnavailable)
        #expect(!plan.context.tier.highFidelityOffered)
    }

    @Test("copies the live Apple identity")
    func copiesAppleIdentity() async {
        let model = await makeModel()

        let plan = model.retranslatePlan(surface: .live, target: .english)

        #expect(plan.context.live.activeEngineKind == .appleFast)
        #expect(plan.context.live.attachedProvider == nil)
        #expect(plan.context.live.runsFast == !AppleTierAvailability.supportsStrategySelection)
        #expect(!plan.context.live.runsHighFidelity)
    }

    @Test("copies the live external identity")
    func copiesExternalIdentity() async {
        let model = await makeModel()
        model.translationSession.activeTranslationEngine = .external
        model.translationSession.activeExternalProvider = .deepl

        let plan = model.retranslatePlan(surface: .live, target: .english)

        #expect(plan.context.live.activeEngineKind == .deepl)
        #expect(plan.context.live.attachedProvider == .deepl)
        #expect(!plan.context.live.runsFast)
        #expect(!plan.context.live.runsHighFidelity)
    }

    @Test("copies the live runtime status")
    func copiesRuntimeStatus() async {
        let model = await makeModel()
        model.translationSession.translationStatus = .unavailable("boom", .permanent)

        let plan = model.retranslatePlan(surface: .live, target: .english)

        #expect(plan.context.live.status == .unavailable("boom", .permanent))
    }

    @Test("reads the observable worker mirror the queue's callback keeps in sync")
    func copiesWorkerMirror() async {
        let model = await makeModel()
        let idle = model.retranslatePlan(surface: .live, target: .english)

        #expect(!idle.context.live.workerAttached)

        model.translationSession.workerAttached = true
        let mirrorOnly = model.retranslatePlan(surface: .live, target: .english)

        #expect(mirrorOnly.context.live.workerAttached)

        let worker = await harness.attachWorker(model)
        defer { worker.cancel() }

        let attached = model.retranslatePlan(surface: .live, target: .english)

        #expect(attached.context.live.workerAttached)
    }

    @Test("copies stored keys and configured providers separately")
    func copiesKeys() async {
        let model = await makeModel()
        try? model.translationSettings.saveKey("sk-google", for: .google)
        try? model.translationSettings.saveKey("sk-deepl", for: .deepl)
        model.translationSettings.setTestResult(.success, for: .google)

        let plan = model.retranslatePlan(surface: .live, target: .english)

        #expect(plan.context.keys.keyed == [.google, .deepl])
        #expect(plan.context.keys.configured == [.google])
    }

    @Test("copies the phase liveness")
    func copiesPhase() async {
        let model = await makeModel()

        model.phase = .paused
        let livePlan = model.retranslatePlan(surface: .live, target: .english)

        #expect(livePlan.context.live.phaseIsLive)

        model.phase = .idle
        let idlePlan = model.retranslatePlan(surface: .live, target: .english)

        #expect(!idlePlan.context.live.phaseIsLive)
    }

    @Test("copies the archive job's running flag")
    func copiesArchiveJobFlag() async {
        let model = await makeModel()
        let idlePlan = model.retranslatePlan(surface: .archive, target: .english)

        #expect(!idlePlan.context.row.archiveJobRunning)

        let claimed = model.archiveTranslationJob.claim(ArchiveTranslationJobFixtures.makeRequest())
        let runningPlan = model.retranslatePlan(surface: .archive, target: .english)

        #expect(claimed)
        #expect(runningPlan.context.row.archiveJobRunning)
    }

    @Test("copies pending indexes, the marker toggle, and the probe target")
    func copiesRowFacts() async {
        let model = await makeModel()
        model.pendingRetranslations = [3, 5]
        model.translationSettings.showsRetranslateMarker = false
        model.appleHighFidelityProbe = (installed: true, targetCode: "de")

        let plan = model.retranslatePlan(surface: .live, target: .english)

        #expect(plan.context.row.pendingIndexes == [3, 5])
        #expect(!plan.context.row.showsMarker)
        #expect(plan.context.row.probeTargetCode == "de")
    }

    @Test("a probe landing re-routes the live plan and refreshes its options")
    func probeLandingChangesLivePlan() async throws {
        guard #available(macOS 26.4, *) else {
            try Test.cancel("the strategy probe requires macOS 26.4")
        }
        let model = await makeModel()
        model.phase = .running
        model.translationSettings.selectRetranslate(.appleFast)

        let before = model.retranslatePlan(surface: .live, target: .english)

        #expect(before.route == .lane(.appleFast))
        #expect(before.options.contains(where: { option in option.engine == .appleHighFidelity }))

        model.appleHighFidelityProbe = (installed: false, targetCode: "en")
        let after = model.retranslatePlan(surface: .live, target: .english)

        #expect(after.route == .session)
        #expect(!after.options.contains(where: { option in option.engine == .appleFast }))
        #expect(!after.options.contains(where: { option in option.engine == .appleHighFidelity }))
    }

    @Test("a click-time explicit selection survives a later settings change")
    func clickTimeSelectionSurvivesSettingsChange() async {
        let model = await makeModel()
        model.translationSettings.selectRetranslate(.appleFast)

        let clickTime = model.retranslatePlan(
            surface: .live, target: .english, selection: .google
        )

        model.translationSettings.selectRetranslate(.deepl)
        let later = model.retranslatePlan(
            surface: .live, target: .english, selection: .google
        )

        #expect(clickTime.context.selection == .google)
        #expect(later.context.selection == .google)
    }

    @Test("high-fidelity evidence is scoped to the plan's target")
    func targetScopesHighFidelityEvidence() async throws {
        guard #available(macOS 26.4, *) else {
            try Test.cancel("the strategy probe requires macOS 26.4")
        }
        let model = await makeModel()
        model.translationSettings.select(TargetLanguage.english)
        model.appleHighFidelityProbe = (installed: false, targetCode: "en")
        model.translationSettings.select(TargetLanguage(code: "de"))

        let english = model.retranslatePlan(surface: .archive, target: .english)
        let german = model.retranslatePlan(surface: .archive, target: TargetLanguage(code: "de"))

        #expect(english.context.tier.highFidelityKnownUnavailable)
        #expect(!german.context.tier.highFidelityKnownUnavailable)
        #expect(!english.context.tier.highFidelityOffered)
        #expect(german.context.tier.highFidelityOffered)
        #expect(english.defaultEngine == .appleFast)
        #expect(german.defaultEngine == .appleHighFidelity)
        #expect(!english.options.contains(where: { option in option.engine == .appleHighFidelity }))
        #expect(german.options.contains(where: { option in option.engine == .appleHighFidelity }))
    }
}
