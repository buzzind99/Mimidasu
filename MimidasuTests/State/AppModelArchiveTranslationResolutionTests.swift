import Foundation
@testable import Mimidasu
import Testing

/// Tests the Apple side of an archive-translation start's engine
/// resolution: the picker's explicit tier parameter (a high-fidelity pick
/// flying a pre-armed session, an NMT pick never upgrading on its own), the
/// still-starting copy each Apple model reports when its arm window runs
/// out, the silent release when a teardown lands under the wait, the chain
/// on airborne lane work before the first engine call, and the
/// pair-scoped high-fidelity degrade. The settings re-translate selection
/// plays no part: the run resolves exactly the engine the pick names.
/// Shares the harness (seeded store, scripted engine, permit gate) with the
/// `AppModelArchiveTranslation` suite.
@MainActor
@Suite("AppModelArchiveTranslationResolution")
struct ArchiveTranslationResolutionTests {

    private let resultTimeout: TimeInterval = 5

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
        #expect(sut.model.archiveTranslationJob.kind == .appleHighFidelity)
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
        #expect(sut.model.archiveTranslationJob.currentRun == nil)
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
        #expect(sut.model.archiveTranslationJob.currentRun == nil)
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
        #expect(sut.model.archiveTranslationJob.currentRun == nil, "no run ever starts")
        #expect(engine.recordedBatches.isEmpty, "a post-teardown engine is never flown")
        #expect(archiveToast(sut.model) == nil, "no card for a canceled start")
        #expect(retranslateToast(sut.model) == nil, "a canceled start never reports")
    }

    @Test("a run chains on airborne lane work before its first engine call")
    func queuedRunChainsOnAirborneLaneWork() async {
        let sut = await makeSUT()
        let engine = ScriptedArchiveEngine()
        sut.model.retranslate.armRetranslateSessionIfNeeded(for: .appleFast, target: "fr")
        sut.model.retranslateSessionArrived(engine)

        let gate = PermitGate()
        sut.model.retranslateLaneTask = Task {
            await gate.acquire()
        }

        sut.model.beginArchiveTranslation(engine: .appleFast, lang: "fr")
        #expect(
            await pollUntil(timeout: resultTimeout) {
                sut.model.archiveTranslationJob.pendingRequest != nil
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
        #expect(sut.model.archiveTranslationJob.kind == .appleHighFidelity)
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
        let engine = ScriptedArchiveEngine()
        sut.model.retranslate.armRetranslateSessionIfNeeded(for: .appleFast, target: "fr")
        sut.model.retranslateSessionArrived(engine)

        sut.model.beginArchiveTranslation(engine: .appleHighFidelity, lang: "fr")

        #expect(
            await pollUntil(timeout: resultTimeout) { runFinished(sut.model, translated: 3) },
            "the degraded run flies the fast session"
        )
        #expect(sut.model.archiveTranslationJob.kind == .appleFast)
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
        #expect(sut.model.archiveTranslationJob.kind == .appleFast)
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
