import Foundation
@testable import Mimidasu
import Testing

/// The archive window's translate-picker slot: one row-language owns it at
/// a time, and only the exact owner clears it — the same one-slot,
/// clear-if-owner contract the add-language chooser follows. Summaries only
/// carry the identity the slot reads.
@MainActor
@Suite("Archive window translation picker slot")
struct ArchiveWindowStateTranslationPickerTests {

    /// The exact target `summary(id: 7)` with `fr` owns while staged.
    private var owner: ArchiveWindowState.TranslationPickerTarget {
        ArchiveWindowState.TranslationPickerTarget(sessionID: 7, lang: "fr")
    }

    private func summary(id: Int64) -> ArchivedSessionSummary {
        ArchivedSessionSummary(
            id: id,
            status: .complete,
            saved: false,
            startedAt: Date(timeIntervalSince1970: 1_000_000),
            durationS: 90,
            pausedMS: 0,
            sentenceCount: 3,
            targetLang: "fr",
            model: "test-model",
            chunkMS: 160,
            name: nil,
            firstSentence: "こんにちは"
        )
    }

    @Test("a request takes the window's one picker slot")
    func requestTakesTheOneSlot() {
        let state = ArchiveWindowState()

        state.requestTranslationPicker(summary(id: 7), lang: "fr")

        #expect(state.translationPicker == owner)
    }

    @Test("a second request replaces the slot's owner")
    func secondRequestReplacesTheOwner() {
        let state = ArchiveWindowState()

        state.requestTranslationPicker(summary(id: 7), lang: "fr")
        state.requestTranslationPicker(summary(id: 8), lang: "de")

        #expect(
            state.translationPicker
                == ArchiveWindowState.TranslationPickerTarget(sessionID: 8, lang: "de"),
            "the newest request owns the window's single slot"
        )
    }

    @Test("clear drops the slot for its exact owner")
    func clearDropsTheSlotForItsOwner() {
        let state = ArchiveWindowState()
        state.requestTranslationPicker(summary(id: 7), lang: "fr")

        state.clearTranslationPicker(sessionID: 7, lang: "fr")

        #expect(state.translationPicker == nil)
    }

    @Test("clear leaves the slot for another session")
    func clearLeavesTheSlotForAnotherSession() {
        let state = ArchiveWindowState()
        state.requestTranslationPicker(summary(id: 7), lang: "fr")

        state.clearTranslationPicker(sessionID: 8, lang: "fr")

        #expect(state.translationPicker == owner, "a sibling row's dismissal never closes this one")
    }

    @Test("clear leaves the slot for another language")
    func clearLeavesTheSlotForAnotherLanguage() {
        let state = ArchiveWindowState()
        state.requestTranslationPicker(summary(id: 7), lang: "fr")

        state.clearTranslationPicker(sessionID: 7, lang: "de")

        #expect(state.translationPicker == owner, "a sibling language's dismissal never closes this one")
    }
}

/// The picker action's disabled feed at the model/state level, since the
/// view's private `actionDisabled` is the disjunction of these three
/// terms: a live phase, a claimed or running job, and a held disclosure.
/// Each term is pinned alone; the fresh idle model pins the all-clear row.
@MainActor
@Suite("Archive translation picker gate")
struct ArchiveTranslationPickerGateTests {

    private let resultTimeout: TimeInterval = 5

    @Test("a fresh idle model leaves every picker gate term clear")
    func idleModelClearsEveryGateTerm() async {
        let sut = await makeSUT()

        #expect(sut.model.archiveTranslationJob.activity == .idle)
        #expect(sut.model.providerAwaitingDisclosure == nil)
        #expect(sut.model.canOpenArchivedSession)
    }

    @Test("live phases flip the picker's phase term")
    func livePhasesFlipThePhaseTerm() async {
        let sut = await makeSUT()

        for phase in [SessionPhase.starting, .running, .paused, .sourceLost, .stopping] {
            sut.model.phase = phase
            #expect(!sut.model.canOpenArchivedSession, "\(phase) blocks archive starts")
        }
    }

    @Test("idle-family phases keep the picker action open")
    func idleFamilyPhasesKeepThePickerActionOpen() async {
        let sut = await makeSUT()

        for phase in [SessionPhase.idle, .needsModel, .failed("boom")] {
            sut.model.phase = phase
            #expect(sut.model.canOpenArchivedSession, "\(phase) allows archive starts")
        }
    }

    @Test("the job term flips with the run and clears when it ends")
    func jobTermFlipsWithTheRun() async {
        let sut = await makeSUT()
        let gate = PermitGate()
        let engine = ScriptedArchiveEngine(gate: gate)
        install(engine, for: .google, on: sut.model)

        sut.model.beginArchiveTranslation(engine: .google, lang: "fr")
        #expect(
            await pollUntil(timeout: resultTimeout) {
                sut.model.archiveTranslationJob.activity != .idle
                    && engine.recordedBatches.count == 1
            },
            "the claimed run keeps the picker's job term hot"
        )

        gate.release()
        gate.release()
        gate.release()
        #expect(
            await pollUntil(timeout: resultTimeout) {
                sut.model.archiveTranslationJob.activity == .idle
            },
            "the finished run clears the job term"
        )
    }

    @Test("a held disclosure flips the picker's disclosure term")
    func heldDisclosureFlipsTheDisclosureTerm() async {
        let sut = await makeSUT()

        sut.model.providerAwaitingDisclosure = .archiveTranslation(
            .google, lang: "fr", session: sut.id, presenter: .archiveWindow
        )

        #expect(sut.model.providerAwaitingDisclosure != nil, "the held intent disables the action")
        #expect(sut.model.archiveTranslationJob.activity == .idle, "the job term stays clear")
        #expect(sut.model.canOpenArchivedSession, "the phase term stays clear")
    }
}
