import Foundation
@testable import Mimidasu
import Testing

/// The archive-boundary half of the bulk-run lifecycle: a pane boundary
/// (open/close/swap) retires lane work but must not discard a run resolving
/// its engine, must not tear the dedicated Apple sessions down, and must
/// leave a stored engine usable by the next run. An explicit cancel stays
/// the only thing that ends an airborne resolution, and it ends it
/// silently. Scripted engine doubles and the arm-wait seam make each
/// resolution park deterministic.
@MainActor
@Suite("AppModelArchiveTranslation boundaries")
struct AppModelArchiveTranslationBoundaryTests {

    private let resultTimeout: TimeInterval = 5

    // MARK: - Boundary during resolution

    @Test("a swap during engine resolution lets the run proceed on the late hand-over")
    func swapDuringResolutionLetsRunProceed() async {
        let sut = await makeSUT()
        let otherID = appendArchive(to: sut.store)
        let engine = ScriptedArchiveEngine()
        sut.model.laneArmTimeout = .seconds(2)

        sut.model.beginArchiveTranslation(engine: .appleFast, lang: "fr")
        #expect(
            await pollUntil(timeout: resultTimeout) { sut.model.retranslateConfig != nil },
            "the run's resolution arms the fast session"
        )
        #expect(sut.model.archiveTranslationRunning, "the run is claimed while it resolves")

        sut.model.openArchiveSession(id: otherID)

        #expect(sut.model.openArchive?.id == otherID, "the boundary swapped the pane")
        #expect(
            !sut.model.archiveTranslationJob.isCancelled,
            "the boundary never trips the run's abort probe"
        )
        #expect(sut.model.archiveTranslationRunning, "the boundary keeps the run claimed")

        sut.model.retranslateSessionArrived(engine)

        #expect(
            await pollUntil(timeout: resultTimeout) { runFinished(sut.model, translated: 3) },
            "the run proceeds once the hand-over lands"
        )
        #expect(
            engine.recordedBatches == [["こんにちは"], ["さようなら"], ["おはよう"]],
            "the late hand-over serves every sentence"
        )
        #expect(
            sut.model.archiveTranslationJob.lastRun?.request.sessionID == sut.id,
            "the run stays on its own archive"
        )
        #expect(
            sut.store.load(id: sut.id)?.entries.compactMap { entry in entry.translation(for: "fr")?.text }
                == ["T:こんにちは", "T:さようなら", "T:おはよう"],
            "every landing persists under the run's archive"
        )
    }

    @Test("a cancel during engine resolution discards the run silently")
    func cancelDuringResolutionDiscardsSilently() async {
        let sut = await makeSUT()
        let engine = ScriptedArchiveEngine()
        sut.model.laneArmTimeout = .seconds(10)

        sut.model.beginArchiveTranslation(engine: .appleFast, lang: "fr")
        #expect(
            await pollUntil(timeout: resultTimeout) { sut.model.retranslateConfig != nil },
            "the run's resolution arms the fast session"
        )

        sut.model.cancelArchiveTranslation()

        #expect(
            await pollUntil(timeout: resultTimeout) { !sut.model.archiveTranslationRunning },
            "the cancel releases the claim well inside the arm window"
        )
        sut.model.retranslateSessionArrived(engine)

        #expect(sut.model.archiveTranslationJob.lastRun == nil, "no run ever starts")
        #expect(engine.recordedBatches.isEmpty, "the late hand-over engine is never flown")
        #expect(archiveToast(sut.model) == nil, "a canceled resolution reports nothing")
    }

    // MARK: - Boundary keeps the dedicated session

    @Test("swapping the pane keeps the armed high-fidelity config and its stored engine")
    func swapKeepsArmedHighFidelitySession() async {
        let sut = await makeSUT()
        let otherID = appendArchive(to: sut.store)
        let engine = ScriptedArchiveEngine()
        sut.model.retranslate.armRetranslateSessionIfNeeded(for: .appleHighFidelity, target: "fr")
        sut.model.retranslateHifiSessionArrived(engine)
        #expect(sut.model.retranslateHifiConfig != nil, "the high-fidelity session starts armed")
        #expect(sut.model.retranslateHifiSessionEngine != nil, "the hand-over stores the engine")

        sut.model.openArchiveSession(id: otherID)

        #expect(sut.model.retranslateHifiConfig != nil, "the swap keeps the armed config")
        #expect(sut.model.retranslateHifiSessionEngine != nil, "the swap keeps the stored engine")
    }

    @Test("closing the archive keeps the armed high-fidelity config and its stored engine")
    func closeKeepsArmedHighFidelitySession() async {
        let sut = await makeSUT()
        let engine = ScriptedArchiveEngine()
        sut.model.retranslate.armRetranslateSessionIfNeeded(for: .appleHighFidelity, target: "fr")
        sut.model.retranslateHifiSessionArrived(engine)
        #expect(sut.model.retranslateHifiConfig != nil, "the high-fidelity session starts armed")
        #expect(sut.model.retranslateHifiSessionEngine != nil, "the hand-over stores the engine")

        sut.model.closeArchive()

        #expect(sut.model.retranslateHifiConfig != nil, "the close keeps the armed config")
        #expect(sut.model.retranslateHifiSessionEngine != nil, "the close keeps the stored engine")
    }

    // MARK: - Stored engine after a boundary

    @Test("a row start after a boundary flies the stored engine with no arm wait")
    func rowStartAfterBoundaryFliesStoredEngineImmediately() async {
        let sut = await makeSUT()
        let otherID = appendArchive(to: sut.store)
        let engine = ScriptedArchiveEngine()
        sut.model.retranslate.armRetranslateSessionIfNeeded(for: .appleFast, target: "fr")
        sut.model.retranslateSessionArrived(engine)

        sut.model.openArchiveSession(id: otherID)
        #expect(sut.model.openArchive?.id == otherID, "the boundary swapped the pane")
        // Short enough that a lost engine would time out and report instead
        // of flying; a stored engine resolves without touching the window.
        sut.model.laneArmTimeout = .milliseconds(60)

        sut.model.beginArchiveTranslation(engine: .appleFast, lang: "fr", sessionID: otherID)

        #expect(
            await pollUntil(timeout: resultTimeout) { runFinished(sut.model, translated: 1) },
            "the stored session serves the row's run"
        )
        #expect(
            engine.recordedBatches == [["bonjour"]],
            "the run flies immediately, never waiting an arm window"
        )
        #expect(
            archiveToast(sut.model)?.title == "Archive translation finished",
            "no still-starting card is posted"
        )
    }
}
