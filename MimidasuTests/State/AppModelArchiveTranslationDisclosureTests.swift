import Foundation
@testable import Mimidasu
import Testing

private let disclosureResultTimeout: TimeInterval = 5

/// The cloud-disclosure half of the archive-translation coverage, split
/// from the main suite at the file-length gate: confirming the staged
/// archive intent starts its run, a stale confirm changes nothing, and a
/// decline starts nothing.
extension AppModelArchiveTranslationTests {

    // MARK: - Cloud disclosure

    @Test("confirming the archive-translation disclosure starts the run")
    func confirmStartsTheRun() async {
        let sut = await makeSUT()
        let engine = ScriptedArchiveEngine()
        install(engine, for: .deepl, on: sut.model)
        sut.model.providerAwaitingDisclosure = .archiveTranslation(.deepl, lang: "fr", session: sut.id, presenter: .mainWindow)

        sut.model.confirmCloudDisclosure(.archiveTranslation(.deepl, lang: "fr", session: sut.id, presenter: .mainWindow))

        #expect(sut.model.providerAwaitingDisclosure == nil, "the confirm clears the slot")
        #expect(
            await pollUntil(timeout: disclosureResultTimeout) { runFinished(sut.model, translated: 3) },
            "the confirmed pick flies the run"
        )
        #expect(sut.model.archiveTranslationJob.lastRun?.request.engine == .deepl)
        #expect(sut.model.archiveTranslationJob.lastRun?.kind == .deepl)
        #expect(
            sut.model.entries.first?.translation(for: "fr")
                == SentenceTranslation(lang: "fr", text: "T:こんにちは", engine: .deepl)
        )
    }

    @Test("a stale confirm leaves the staged intent and starts nothing")
    func staleConfirmStartsNothing() async {
        let sut = await makeSUT()
        sut.model.providerAwaitingDisclosure = .archiveTranslation(.deepl, lang: "fr", session: sut.id, presenter: .mainWindow)

        sut.model.confirmCloudDisclosure(.archiveTranslation(.google, lang: "fr", session: sut.id, presenter: .mainWindow))

        #expect(
            sut.model.providerAwaitingDisclosure == .archiveTranslation(.deepl, lang: "fr", session: sut.id, presenter: .mainWindow),
            "the staged intent stays for its own sheet"
        )
        #expect(!sut.model.archiveTranslationRunning)
        #expect(sut.model.archiveTranslationJob.lastRun == nil)
        #expect(
            sut.model.archive.load(id: sut.id)?.entries.allSatisfy { entry in entry.translations.isEmpty } == true
        )
    }

    @Test("declining the archive-translation disclosure starts nothing")
    func declineStartsNothing() async {
        let sut = await makeSUT()
        let engine = ScriptedArchiveEngine()
        install(engine, for: .deepl, on: sut.model)
        sut.model.providerAwaitingDisclosure = .archiveTranslation(.deepl, lang: "fr", session: sut.id, presenter: .mainWindow)

        sut.model.declineCloudDisclosure()

        #expect(sut.model.providerAwaitingDisclosure == nil)
        #expect(!sut.model.archiveTranslationRunning)
        #expect(sut.model.archiveTranslationJob.lastRun == nil)
        #expect(engine.recordedBatches.isEmpty, "the declined pick never reaches an engine")
    }
}
