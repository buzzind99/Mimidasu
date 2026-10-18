import Foundation
@testable import Mimidasu
import Synchronization
import Testing

/// Tests the Apple side of an archive-translation start's engine
/// resolution: the high-fidelity selection flying a pre-armed session, the
/// still-starting copy each Apple model reports when its arm window runs
/// out, the silent release when a teardown lands under the wait, and the
/// chain on airborne lane work before the first engine call. Shares the
/// harness (seeded store, scripted engine, permit gate) with the
/// `AppModelArchiveTranslation` suite.
@MainActor
@Suite("AppModelArchiveTranslationResolution")
struct ArchiveTranslationResolutionTests {

    private let resultTimeout: TimeInterval = 5

    @Test("a high-fidelity selection flies the armed high-fidelity session")
    func highFidelityStartUsesArmedHifiSession() async {
        guard #available(macOS 26.4, *) else { return }
        let sut = await makeSUT()
        sut.model.translationSettings.selectRetranslate(.appleHighFidelity)
        let engine = ScriptedArchiveEngine()
        sut.model.retranslate.armRetranslateSessionIfNeeded(for: .appleHighFidelity, target: "fr")
        sut.model.retranslateHifiSessionArrived(engine)

        sut.model.beginArchiveTranslation(provider: .apple, lang: "fr")

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

    @Test("an Apple start with no hand-over reports the still-starting copy per model")
    func appleArmTimeoutReportsStillStarting() async {
        let sut = await makeSUT()
        sut.model.laneArmTimeout = .milliseconds(60)

        sut.model.beginArchiveTranslation(provider: .apple, lang: "fr")
        #expect(
            await pollUntil(timeout: resultTimeout) { retranslateToast(sut.model) != nil },
            "the fast-model arm window reports its timeout"
        )
        #expect(
            retranslateToast(sut.model)?.body
                == "Apple (MTL) session is still starting — try again in a moment."
        )
        #expect(!sut.model.archiveTranslationRunning, "a timed-out arm starts nothing")
        #expect(sut.model.archiveTranslationJob.currentRun == nil)
        #expect(archiveToast(sut.model) == nil, "no progress card for a failed start")

        sut.model.translationSettings.selectRetranslate(.appleHighFidelity)
        sut.model.beginArchiveTranslation(provider: .apple, lang: "fr")
        #expect(
            await pollUntil(timeout: resultTimeout) {
                retranslateToast(sut.model)?.body
                    == "Apple Intelligence session is still starting — try again in a moment."
            },
            "the high-fidelity arm window reports its own copy"
        )
        #expect(!sut.model.archiveTranslationRunning)
    }

    @Test("a teardown during the arm wait cancels the start silently")
    func teardownDuringArmWaitCancelsStart() async {
        let sut = await makeSUT()
        sut.model.laneArmTimeout = .seconds(2)

        sut.model.beginArchiveTranslation(provider: .apple, lang: "fr")
        // No hand-over is coming; turn the lane generation over under the
        // airborne wait.
        try? await Task.sleep(for: .milliseconds(40))
        sut.model.teardownRetranslateSession()

        #expect(
            await pollUntil(timeout: resultTimeout) { !sut.model.archiveTranslationRunning },
            "the canceled resolution releases the claim"
        )
        #expect(sut.model.archiveTranslationJob.currentRun == nil, "no run ever starts")
        #expect(archiveToast(sut.model) == nil, "no progress card for a canceled start")
        #expect(retranslateToast(sut.model) == nil, "a canceled start never reports")
    }

    @Test("a run chains on airborne lane work before its first engine call")
    func queuedRunChainsOnAirborneLaneWork() async {
        let sut = await makeSUT()
        let engine = ScriptedArchiveEngine()
        sut.model.retranslate.armRetranslateSessionIfNeeded(for: .appleFast, target: "fr")
        sut.model.retranslateSessionArrived(engine)

        let chained = Mutex(false)
        sut.model.retranslateLaneTask = Task {
            try? await Task.sleep(for: .milliseconds(150))
            chained.withLock { current in current = true }
        }

        sut.model.beginArchiveTranslation(provider: .apple, lang: "fr")
        try? await Task.sleep(for: .milliseconds(60))
        #expect(
            engine.recordedBatches.isEmpty,
            "the first call waits out the airborne lane work"
        )
        #expect(
            await pollUntil(timeout: resultTimeout) { runFinished(sut.model, translated: 3) },
            "the run proceeds once the chain clears"
        )
        #expect(chained.withLock { current in current }, "the chain task completed first")
    }
}
