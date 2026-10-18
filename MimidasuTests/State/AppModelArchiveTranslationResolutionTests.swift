import Foundation
@testable import Mimidasu
import Synchronization
import Testing

/// A reference box the resolver wrapper increments before forwarding.
@MainActor
private final class ResolutionSignal {
    private(set) var entered = 0

    func record() {
        entered += 1
    }
}

/// Tests the Apple side of an archive-translation start's engine
/// resolution: the picker's explicit tier parameter (a high-fidelity pick
/// flying a pre-armed session, an NMT pick never upgrading on its own), the
/// still-starting copy each Apple model reports when its arm window runs
/// out, the silent release when a teardown lands under the wait, the
/// un-pre-armed run resolving on the late hand-over, and the pair-scoped
/// high-fidelity degrade — with the progress card naming the tier that
/// actually runs. The settings re-translate selection plays no part: the
/// run resolves exactly the engine the pick names. The lane-chain half (the
/// job's claim over airborne lane work, its release when the surface goes
/// away, and the target-gated adoption of dedicated-session engines by the
/// per-row lane, the bulk run, and the factory) lives in the sibling
/// `ArchiveTranslationAdoption` suite in this file, split to keep both type
/// bodies under the lint gate. Shares the harness (seeded store, scripted
/// engine, permit gate) with the `AppModelArchiveTranslation` suite.
@MainActor
@Suite("AppModelArchiveTranslationResolution")
struct ArchiveTranslationResolutionTests {

    private let resultTimeout: TimeInterval = 5

    /// The open archive's row for `index`.
    private func sentence(_ sut: ArchiveTranslationSUT, at index: Int) -> Sentence {
        sut.model.entries.first { entry in entry.sentence.index == index }!.sentence
    }

    @Test("a high-fidelity selection flies the armed high-fidelity session")
    func highFidelityStartUsesArmedHifiSession() async throws {
        guard #available(macOS 26.4, *) else {
            try Test.cancel("the high-fidelity lane requires macOS 26.4")
        }
        let sut = await makeSUT()
        let engine = ScriptedArchiveEngine()
        sut.model.retranslate.armRetranslateSessionIfNeeded(for: .appleHighFidelity, target: "fr")
        sut.model.retranslateHifiSessionArrived(engine)

        sut.model.beginArchiveTranslation(engine: .appleHighFidelity, lang: "fr")

        #expect(
            await pollUntil(timeout: resultTimeout) { runFinished(sut.model, translated: 3) },
            "the armed high-fidelity session serves the whole run"
        )
        #expect(sut.model.archiveTranslationJob.lastRun?.kind == .appleHighFidelity)
        #expect(
            sut.model.entries.compactMap { entry in entry.translation(for: "fr")?.engine }
                == [.appleHighFidelity, .appleHighFidelity, .appleHighFidelity],
            "every landed row is stamped high fidelity"
        )
    }

    @Test("an Apple start with no hand-over reports the fast model's still-starting copy")
    func appleArmTimeoutReportsStillStarting() async {
        let sut = await makeSUT()
        sut.model.laneArmTimeout = .milliseconds(60)

        sut.model.beginArchiveTranslation(engine: .appleFast, lang: "fr")

        #expect(
            await pollUntil(timeout: resultTimeout) { archiveToast(sut.model) != nil },
            "the fast-model arm window reports its timeout"
        )
        let toast = archiveToast(sut.model)
        #expect(toast?.style == .yellowAuto)
        #expect(toast?.title == "Archive translation unavailable", "the run posts under its own key")
        #expect(toast?.body == "Apple (NMT) session is still starting — try again in a moment.")
        #expect(toast?.progress == nil, "no progress card for a failed start")
        #expect(!sut.model.archiveTranslationRunning, "a timed-out arm starts nothing")
        #expect(sut.model.archiveTranslationJob.lastRun == nil)
    }

    @Test("an Apple start with no hand-over reports the high-fidelity model's copy")
    func hifiArmTimeoutReportsStillStarting() async throws {
        guard #available(macOS 26.4, *) else {
            try Test.cancel("the high-fidelity arm requires macOS 26.4")
        }
        let sut = await makeSUT()
        sut.model.laneArmTimeout = .milliseconds(60)

        sut.model.beginArchiveTranslation(engine: .appleHighFidelity, lang: "fr")

        #expect(
            await pollUntil(timeout: resultTimeout) {
                archiveToast(sut.model)?.body
                    == "Apple Intelligence session is still starting — try again in a moment."
            },
            "the high-fidelity arm window reports its own copy"
        )
        #expect(!sut.model.archiveTranslationRunning)
        #expect(sut.model.archiveTranslationJob.lastRun == nil)
    }

    @Test("a teardown during the arm wait cancels the start silently")
    func teardownDuringArmWaitCancelsStart() async {
        let sut = await makeSUT()
        sut.model.laneArmTimeout = .seconds(2)

        sut.model.beginArchiveTranslation(engine: .appleFast, lang: "fr")
        #expect(
            await pollUntil(timeout: resultTimeout) { sut.model.retranslateConfig != nil },
            "the run's resolution armed the fast session"
        )
        // Turn the lane generation over under the airborne wait. The rebuild
        // keeps a config armed, so the hand-over that follows still stores
        // its engine — a post-teardown engine with a stale epoch, which the
        // resolving run must not adopt.
        sut.model.teardownRetranslateSession()
        let engine = ScriptedArchiveEngine()
        sut.model.retranslateSessionArrived(engine)

        #expect(
            await pollUntil(timeout: resultTimeout) { !sut.model.archiveTranslationRunning },
            "the canceled resolution releases the claim"
        )
        #expect(sut.model.archiveTranslationJob.lastRun == nil, "no run ever starts")
        #expect(engine.recordedBatches.isEmpty, "a post-teardown engine is never flown")
        #expect(archiveToast(sut.model) == nil, "no card for a canceled start")
        #expect(retranslateToast(sut.model) == nil, "a canceled start never reports")
    }

    // MARK: - Un-pre-armed hand-over

    @Test("a fast run with no pre-armed engine resolves on the late hand-over")
    func unarmedFastRunResolvesOnLateHandover() async {
        let sut = await makeSUT()
        let engine = ScriptedArchiveEngine()

        sut.model.beginArchiveTranslation(engine: .appleFast, lang: "fr")
        #expect(
            await pollUntil(timeout: resultTimeout) { sut.model.retranslateConfig != nil },
            "the run's resolution arms the fast session"
        )
        sut.model.retranslateSessionArrived(engine)

        #expect(
            await pollUntil(timeout: resultTimeout) { runFinished(sut.model, translated: 3) },
            "the late hand-over serves the whole run"
        )
        #expect(sut.model.archiveTranslationJob.lastRun?.kind == .appleFast)
        #expect(
            sut.model.entries.compactMap { entry in entry.translation(for: "fr")?.engine }
                == [.appleFast, .appleFast, .appleFast],
            "every landed row is stamped fast"
        )
    }

    @Test("a high-fidelity run with no pre-armed engine resolves on the late hand-over")
    func unarmedHifiRunResolvesOnLateHandover() async throws {
        guard #available(macOS 26.4, *) else {
            try Test.cancel("the high-fidelity lane requires macOS 26.4")
        }
        let sut = await makeSUT()
        let engine = ScriptedArchiveEngine()

        sut.model.beginArchiveTranslation(engine: .appleHighFidelity, lang: "fr")
        #expect(
            await pollUntil(timeout: resultTimeout) { sut.model.retranslateHifiConfig != nil },
            "the run's resolution arms the high-fidelity session"
        )
        sut.model.retranslateHifiSessionArrived(engine)

        #expect(
            await pollUntil(timeout: resultTimeout) { runFinished(sut.model, translated: 3) },
            "the late hand-over serves the whole run"
        )
        #expect(sut.model.archiveTranslationJob.lastRun?.kind == .appleHighFidelity)
        #expect(
            sut.model.entries.compactMap { entry in entry.translation(for: "fr")?.engine }
                == [.appleHighFidelity, .appleHighFidelity, .appleHighFidelity],
            "every landed row is stamped high fidelity"
        )
    }

    @Test("the engine factory receives the run's target, not the settings target")
    func engineFactoryReceivesRunTarget() async {
        let sut = await makeSUT()
        #expect(
            sut.model.translationSettings.targetLanguage.code == "en",
            "the settings target differs from the archive's stored target"
        )
        let engine = ScriptedArchiveEngine()
        let recorded = Mutex<[(provider: TranslationProvider, target: String)]>([])
        sut.model.retranslateEngineFactory = { provider, target in
            recorded.withLock { current in current.append((provider, target.code)) }
            return provider == .google ? engine : nil
        }

        sut.model.beginArchiveTranslation(engine: .google, lang: "fr")

        #expect(
            await pollUntil(timeout: resultTimeout) { runFinished(sut.model, translated: 3) },
            "the external run serves the whole session"
        )
        let calls = recorded.withLock { current in current }
        #expect(calls.count == 1, "one engine build for the run")
        #expect(calls.first?.provider == .google)
        #expect(calls.first?.target == "fr", "the factory builds over the run's target")
    }

    // MARK: - Target-scoped high-fidelity resolution

    @Test("a probe for another pair is not evidence against the picker's high-fidelity choice")
    func foreignProbeDoesNotDegradeTheHifiPick() async throws {
        guard #available(macOS 26.4, *) else {
            try Test.cancel("the high-fidelity lane requires macOS 26.4")
        }
        let sut = await makeSUT()
        // The probe landed not-installed for another pair (`en`); the
        // archive runs to `fr`, whose availability was never probed — not
        // evidence against the picker's explicit high-fidelity choice.
        sut.model.appleHighFidelityProbe = (false, "en")
        let engine = ScriptedArchiveEngine()
        sut.model.retranslate.armRetranslateSessionIfNeeded(for: .appleHighFidelity, target: "fr")
        sut.model.retranslateHifiSessionArrived(engine)

        sut.model.beginArchiveTranslation(engine: .appleHighFidelity, lang: "fr")

        #expect(
            await pollUntil(timeout: resultTimeout) { runFinished(sut.model, translated: 3) },
            "the foreign pair's probe does not degrade the pick"
        )
        #expect(sut.model.archiveTranslationJob.lastRun?.kind == .appleHighFidelity)
        #expect(
            sut.model.entries.compactMap { entry in entry.translation(for: "fr")?.engine }
                == [.appleHighFidelity, .appleHighFidelity, .appleHighFidelity],
            "every landed row is stamped high fidelity"
        )
    }

    @Test("a probe that landed for the archive target degrades the run to fast")
    func matchingTargetDegradesToFast() async throws {
        guard #available(macOS 26.4, *) else {
            try Test.cancel("the high-fidelity lane requires macOS 26.4")
        }
        let sut = await makeSUT()
        // The probe landed not-installed for the archive's own pair: the
        // pair genuinely cannot serve high fidelity, so the run degrades.
        sut.model.appleHighFidelityProbe = (false, "fr")
        let gate = PermitGate()
        let engine = ScriptedArchiveEngine(gate: gate)
        sut.model.retranslate.armRetranslateSessionIfNeeded(for: .appleFast, target: "fr")
        sut.model.retranslateSessionArrived(engine)

        sut.model.beginArchiveTranslation(engine: .appleHighFidelity, lang: "fr")

        // Park the run on its first flight: the card is still the progress
        // variant, and it must name the model that actually runs.
        #expect(
            await pollUntil(timeout: resultTimeout) { engine.recordedBatches.count == 1 },
            "the degraded run reaches its first flight"
        )
        #expect(
            archiveToast(sut.model)?.body.contains("Apple (NMT)") == true,
            "the progress card names the resolved tier, not the requested one"
        )

        gate.release()
        gate.release()
        gate.release()
        #expect(
            await pollUntil(timeout: resultTimeout) { runFinished(sut.model, translated: 3) },
            "the degraded run flies the fast session"
        )
        #expect(sut.model.archiveTranslationJob.lastRun?.kind == .appleFast)
        #expect(
            sut.model.entries.compactMap { entry in entry.translation(for: "fr")?.engine }
                == [.appleFast, .appleFast, .appleFast],
            "the stamps name the model that actually ran"
        )
        #expect(sut.model.retranslateHifiConfig == nil, "the high-fidelity session is never armed")
    }

    @Test("an NMT pick flies fast even where high fidelity is installed")
    func nmtPickFliesFastWithHifiInstalled() async {
        let sut = await makeSUT()
        sut.model.appleHighFidelityProbe = (true, "fr")
        let engine = ScriptedArchiveEngine()
        sut.model.retranslate.armRetranslateSessionIfNeeded(for: .appleFast, target: "fr")
        sut.model.retranslateSessionArrived(engine)

        sut.model.beginArchiveTranslation(engine: .appleFast, lang: "fr")

        #expect(
            await pollUntil(timeout: resultTimeout) { runFinished(sut.model, translated: 3) },
            "the explicit NMT pick serves the whole run"
        )
        #expect(sut.model.archiveTranslationJob.lastRun?.kind == .appleFast)
        #expect(
            sut.model.entries.compactMap { entry in entry.translation(for: "fr")?.engine }
                == [.appleFast, .appleFast, .appleFast],
            "the stamps name the model that actually ran"
        )
        #expect(sut.model.retranslateHifiConfig == nil, "an explicit NMT pick never upgrades")
    }

    @Test("the high-fidelity known-unavailable facade is scoped to the row's target")
    func highFidelityKnownUnavailableFacadeIsTargetScoped() async {
        let sut = await makeSUT()
        sut.model.appleHighFidelityProbe = (false, "en")

        #expect(
            sut.model.highFidelityKnownUnavailable(for: "en"),
            "the probed pair reports unavailable"
        )
        #expect(
            !sut.model.highFidelityKnownUnavailable(for: "fr"),
            "a foreign target has no probe evidence"
        )
        #expect(!sut.model.highFidelityKnownUnavailable(for: "de"))
        #expect(sut.model.highFidelityKnownUnavailable, "the settings-pair read still delegates")
    }

    // MARK: - Picker offer

    @Test("the picker offers high fidelity for a pair with no unavailability evidence")
    func pickerOffersHighFidelityWithoutEvidence() async throws {
        guard #available(macOS 26.4, *) else {
            try Test.cancel("the high-fidelity offer requires macOS 26.4")
        }
        let sut = await makeSUT()

        #expect(sut.model.archiveHighFidelityOffered(for: "fr"))
    }

    @Test("a probe landed not-installed withdraws the offer only for its pair")
    func probeWithdrawsOfferOnlyForItsPair() async throws {
        guard #available(macOS 26.4, *) else {
            try Test.cancel("the high-fidelity offer requires macOS 26.4")
        }
        let sut = await makeSUT()
        sut.model.appleHighFidelityProbe = (false, "fr")

        #expect(
            !sut.model.archiveHighFidelityOffered(for: "fr"),
            "the probed pair withdraws its offer"
        )
        #expect(
            sut.model.archiveHighFidelityOffered(for: "en"),
            "evidence for one pair does not describe the other's offer"
        )
    }
}

/// The lane-chain half of the archive-translation coverage: the job's claim
/// over airborne lane work and its release when the surface goes away, plus
/// the target-gated adoption of dedicated-session engines by the per-row
/// lane, the bulk run, and the external engine factory. Split into its own
/// suite to keep both type bodies under the lint gate.
@MainActor
@Suite("AppModelArchiveTranslationAdoption")
struct ArchiveTranslationAdoptionTests {

    private let resultTimeout: TimeInterval = 5

    /// The open archive's row for `index`.
    private func sentence(_ sut: ArchiveTranslationSUT, at index: Int) -> Sentence {
        sut.model.entries.first { entry in entry.sentence.index == index }!.sentence
    }

    /// Marks the instant the run enters engine resolution before forwarding
    /// to the wired resolver. The claim is published synchronously, so tests
    /// that must synchronize on resolution itself poll `entered`.
    private func signalResolutionEntry(on sut: ArchiveTranslationSUT) -> ResolutionSignal {
        let signal = ResolutionSignal()
        let resolve = sut.model.archiveTranslationJob.resolveEngine
        sut.model.archiveTranslationJob.resolveEngine = { engine, target in
            signal.record()
            return await resolve(engine, target)
        }
        return signal
    }

    // MARK: - Lane chain and the job claim

    @Test("a run chains on airborne lane work before its first engine call")
    func queuedRunChainsOnAirborneLaneWork() async {
        let sut = await makeSUT()
        let engine = ScriptedArchiveEngine()
        sut.model.retranslate.armRetranslateSessionIfNeeded(for: .appleFast, target: "fr")
        sut.model.retranslateSessionArrived(engine)

        // Park a real lane link on a gated external engine: the row retry
        // registers through `runRetranslateLane`, so the chain bookkeeping
        // the run's resolution reads is live.
        let gate = PermitGate()
        let laneEngine = ScriptedArchiveEngine(gate: gate)
        install(laneEngine, for: .google, on: sut.model)
        sut.model.translationSettings.selectRetranslate(.google)
        sut.model.retranslateSentence(sentence(sut, at: 0))
        #expect(
            await pollUntil(timeout: resultTimeout) { laneEngine.recordedBatches.count == 1 },
            "the lane link parks in its engine"
        )

        let signal = signalResolutionEntry(on: sut)
        sut.model.beginArchiveTranslation(engine: .appleFast, lang: "fr")
        #expect(
            await pollUntil(timeout: resultTimeout) {
                signal.entered == 1
            },
            "the run reaches engine resolution while the lane link is airborne"
        )
        #expect(
            engine.recordedBatches.isEmpty,
            "the first call waits out the airborne lane work"
        )

        gate.release()
        #expect(
            await pollUntil(timeout: resultTimeout) { runFinished(sut.model, translated: 3) },
            "the run proceeds once the chain clears"
        )
    }

    @Test("a close during resolution releases the job claim behind an airborne lane")
    func closeDuringResolutionReleasesClaimBehindAirborneLane() async {
        let sut = await makeSUT()
        let engine = ScriptedArchiveEngine()
        sut.model.retranslate.armRetranslateSessionIfNeeded(for: .appleFast, target: "fr")
        sut.model.retranslateSessionArrived(engine)

        let gate = PermitGate()
        let laneEngine = ScriptedArchiveEngine(gate: gate)
        install(laneEngine, for: .google, on: sut.model)
        sut.model.translationSettings.selectRetranslate(.google)
        sut.model.retranslateSentence(sentence(sut, at: 0))
        #expect(
            await pollUntil(timeout: resultTimeout) { laneEngine.recordedBatches.count == 1 },
            "the lane link parks in its engine"
        )
        let laneTask = sut.model.retranslateLaneTask

        let signal = signalResolutionEntry(on: sut)
        sut.model.beginArchiveTranslation(engine: .appleFast, lang: "fr")
        #expect(
            await pollUntil(timeout: resultTimeout) {
                signal.entered == 1
            },
            "the run reaches resolution behind the airborne lane"
        )

        // Close before the lane is released: the epoch turns over, so the
        // resolution's deliverability poll must release the job's claim
        // instead of parking behind the airborne link until it drains.
        sut.model.closeArchive()
        #expect(
            await pollUntil(timeout: resultTimeout) { !sut.model.archiveTranslationRunning },
            "the close releases the job claim"
        )

        gate.release()
        await laneTask?.value

        #expect(sut.model.archiveTranslationJob.lastRun == nil, "no run ever starts")
        #expect(sut.model.archiveTranslationJob.activity == .idle, "the claim is fully released")
        #expect(engine.recordedBatches.isEmpty, "the run's engine is never flown")
        #expect(archiveToast(sut.model) == nil, "a cancelled resolution posts no card")
    }

    // MARK: - Target-gated engine adoption

    @Test("a lane whose kind was re-armed for another target never adopts that engine")
    func foreignTargetLaneNeverAdoptsRearmedEngine() async {
        let sut = await makeSUT()
        sut.model.laneArmTimeout = .milliseconds(300)
        let engine = ScriptedArchiveEngine()

        // A `fr` retry with no engine armed: the lane parks in the arm wait.
        sut.model.retranslateSentence(sentence(sut, at: 0))
        #expect(sut.model.pendingRetranslations.contains(0), "the fr click marks its row")

        // The pane moves to `de` and a `de` retry re-arms the fast config for
        // its own target; its lane chains behind the parked fr link.
        sut.model.selectArchiveViewingLanguage("de")
        sut.model.retranslateSentence(sentence(sut, at: 1))
        #expect(
            sut.model.retranslate.retranslateConfigTarget == "de",
            "the de click rebuilds the armed config for its target"
        )

        // The hand-over serves the de config only.
        sut.model.retranslateSessionArrived(engine)

        #expect(
            await pollUntil(timeout: resultTimeout) {
                sut.model.entries.first(where: { entry in entry.sentence.index == 1 })?
                    .translation(for: "de") != nil
            },
            "the de retry lands normally"
        )
        #expect(
            engine.recordedBatches == [["さようなら"]],
            "only the de flight flew — the fr lane never adopted the de engine"
        )
        #expect(
            sut.model.entries.compactMap { entry in entry.translation(for: "fr") }.isEmpty,
            "the fr row keeps no wrong-language result"
        )
        #expect(sut.model.pendingRetranslations.isEmpty, "the timed-out fr marker retires too")
        #expect(sut.model.lanePendingRetranslations.isEmpty)
    }

    @Test("a bulk run resolving for another target never adopts a re-armed engine")
    func foreignTargetJobResolutionNeverAdoptsRearmedEngine() async {
        let sut = await makeSUT()
        sut.model.laneArmTimeout = .milliseconds(300)
        let engine = ScriptedArchiveEngine()

        // No pre-armed engine: the run's resolution parks in the arm wait.
        let signal = signalResolutionEntry(on: sut)
        sut.model.beginArchiveTranslation(engine: .appleFast, lang: "fr")
        #expect(
            await pollUntil(timeout: resultTimeout) {
                signal.entered == 1
            },
            "the run reaches engine resolution"
        )

        // The pane moves to `de` and the same config is re-armed for it; the
        // hand-over stores a `de` engine.
        sut.model.selectArchiveViewingLanguage("de")
        sut.model.retranslate.armRetranslateSessionIfNeeded(for: .appleFast, target: "de")
        sut.model.retranslateSessionArrived(engine)

        #expect(
            await pollUntil(timeout: resultTimeout) { !sut.model.archiveTranslationRunning },
            "the run times out and releases its claim"
        )
        #expect(
            sut.model.entries.compactMap { entry in entry.translation(for: "fr") }.isEmpty,
            "no fr-stamped result ever lands"
        )
        #expect(engine.recordedBatches.isEmpty, "the de engine is never flown for the fr run")
        #expect(sut.model.archiveTranslationJob.lastRun == nil, "no run ever starts")
        #expect(
            archiveToast(sut.model)?.body == "Apple (NMT) session is still starting — try again in a moment.",
            "the run reports the still-starting copy"
        )
    }
}
