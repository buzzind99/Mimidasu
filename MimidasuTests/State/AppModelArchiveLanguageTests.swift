import Foundation
@testable import Mimidasu
import Testing

/// Tests `AppModel`'s archive language surface over a seeded in-temp store:
/// the viewing language default/switch/clear, membership adds on the open
/// archive and on a stored sibling, add idempotence and revision bumps,
/// membership persistence across a reopen, the summary's language set (the
/// provider chooser's exclusion data), and the send-count/completeness reads
/// after an add or a per-row delivery.
@MainActor
@Suite("AppModelArchiveLanguage")
struct AppModelArchiveLanguageTests {

    private struct SUT {
        let model: AppModel
        let store: ArchiveStore
        let id: Int64
    }

    // MARK: - Fixtures

    private func metadata(target: String) -> SessionMetadata {
        SessionMetadata(
            startedAt: Date(timeIntervalSince1970: 1_000_000),
            sourceLang: "ja", targetLang: target, model: "test-model", chunkMS: 160
        )
    }

    private func sentence(_ index: Int, text: String) -> Sentence {
        Sentence(index: index, startS: Double(index), endS: Double(index) + 1, lang: "ja", text: text)
    }

    /// A finalized three-sentence archive (stored target `en`) open in the
    /// pane; `translations` seeds pre-existing rows by sentence index.
    private func makeSUT(
        target: String = "en",
        translations: [Int: SentenceTranslation] = [:]
    ) async -> SUT {
        let store = isolatedArchive()
        var id: Int64?
        for (index, text) in ["こんにちは", "さようなら", "おはよう"].enumerated() {
            id = store.append(
                sentence: sentence(index, text: text), sessionID: id, metadata: metadata(target: target)
            )
        }
        let finalized = id ?? -1
        for (index, translation) in translations {
            store.upsert(translation: translation, index: index, session: finalized)
        }
        store.finalize(session: finalized, durationMS: 60000, saved: false)

        let model = AppModel(
            translationSettings: isolatedTranslationSettings(suite: "test.AppModelArchiveLanguage"),
            asrModelSettings: isolatedASRModelSettings(suite: "test.AppModelArchiveLanguage"),
            favorites: isolatedFavorites(),
            archive: store,
            highFidelityProbe: { _ in false },
            initialModelResolve: { _ in nil }
        )
        await model.initialModelCheck?.value
        model.openArchiveSession(id: finalized)
        return SUT(model: model, store: store, id: finalized)
    }

    /// A second finalized session (`en`, two sentences) stored alongside
    /// the open one; the pane keeps showing the first.
    private func appendSecondSession(_ sut: SUT) -> Int64 {
        var id: Int64?
        for (index, text) in ["おやすみ", "いただきます"].enumerated() {
            id = sut.store.append(
                sentence: sentence(index, text: text), sessionID: id, metadata: metadata(target: "en")
            )
        }
        let finalized = id ?? -1
        sut.store.finalize(session: finalized, durationMS: 30000, saved: false)
        return finalized
    }

    // MARK: - Viewing language

    @Test("the viewing language defaults to the stored target and a selection overrides it")
    func viewingLanguageDefaultsAndSwitches() async {
        let sut = await makeSUT()

        #expect(sut.model.archiveViewingCode == "en", "the default is the stored target")
        #expect(sut.model.archiveViewingLanguage == nil, "no override until one is picked")

        sut.model.selectArchiveViewingLanguage("fr")

        #expect(sut.model.archiveViewingCode == "fr")
    }

    @Test("closing clears the viewing language with the archive")
    func closingClearsViewingLanguage() async {
        let sut = await makeSUT()
        sut.model.selectArchiveViewingLanguage("fr")

        sut.model.closeArchive()

        #expect(sut.model.openArchive == nil)
        #expect(sut.model.archiveViewingCode == nil)
    }

    // MARK: - Membership adds

    @Test("adding a language to the open archive selects it and shows it at zero")
    func addOnOpenArchiveSelectsAndRegisters() async {
        let sut = await makeSUT()

        let added = sut.model.addArchiveLanguage(id: sut.id, lang: "fr")

        #expect(added)
        #expect(sut.model.archiveViewingCode == "fr", "the added language becomes the viewed one")
        #expect(
            sut.model.openArchive?.summary.languageCount(for: "fr")
                == ArchiveLanguageCount(lang: "fr", translated: 0),
            "the banner's chip appears at 0/3"
        )
        #expect(sut.model.openArchive?.summary.sentenceCount == 3)
    }

    @Test("adding a language to another stored session never switches the pane")
    func addOnStoredSiblingKeepsViewingLanguage() async {
        let sut = await makeSUT()
        let second = appendSecondSession(sut)

        let added = sut.model.addArchiveLanguage(id: second, lang: "fr")

        #expect(added)
        #expect(sut.model.archiveViewingCode == "en", "another session's membership never switches")
        #expect(
            sut.model.archive.summary(id: second)?.languageCount(for: "fr")
                == ArchiveLanguageCount(lang: "fr", translated: 0),
            "the re-read summary carries the membership at 0/2"
        )
        #expect(
            sut.model.archive.list().first { summary in summary.id == second }?.langs.map(\.lang)
                == ["en", "fr"],
            "the list row carries it too"
        )
    }

    @Test("a repeated add keeps one entry and every successful add bumps the revision")
    func addIsIdempotentAndBumpsRevision() async {
        let sut = await makeSUT()
        let revisionBefore = sut.model.archiveRevision

        let first = sut.model.addArchiveLanguage(id: sut.id, lang: "fr")
        let revisionAfterFirst = sut.model.archiveRevision
        let second = sut.model.addArchiveLanguage(id: sut.id, lang: "fr")

        #expect(first)
        #expect(second, "the idempotent re-add still reports its write as landed")
        #expect(revisionAfterFirst != revisionBefore)
        #expect(
            sut.model.archiveRevision != revisionAfterFirst,
            "the add contract is bump-always, repeats included — every landed write bumps"
        )
        #expect(
            sut.model.openArchive?.summary.languageCount(for: "fr")
                == ArchiveLanguageCount(lang: "fr", translated: 0),
            "the language stays one membership entry at zero"
        )
        #expect(
            sut.model.openArchive?.summary.langs.filter { count in count.lang == "fr" }.count == 1,
            "the language set stays set-valued"
        )
    }

    @Test("membership survives a close and reopen")
    func membershipSurvivesReopen() async {
        let sut = await makeSUT()
        sut.model.addArchiveLanguage(id: sut.id, lang: "fr")

        sut.model.closeArchive()
        sut.model.openArchiveSession(id: sut.id)

        #expect(
            sut.model.openArchive?.summary.languageCount(for: "fr")
                == ArchiveLanguageCount(lang: "fr", translated: 0),
            "the membership is still there"
        )
        #expect(sut.model.archiveViewingCode == "en", "the viewing override cleared with the close")
    }

    // MARK: - Language set

    @Test("the summary's language set leads with the target, then memberships, then translations")
    func summaryLanguageSetLeadsWithTarget() async {
        let sut = await makeSUT(translations: [0: SentenceTranslation(lang: "de", text: "Seed")])
        #expect(
            sut.model.openArchive?.summary.langs.map(\.lang) == ["en", "de"],
            "the stored target leads, the translation-only language follows"
        )

        sut.model.addArchiveLanguage(id: sut.id, lang: "fr")

        #expect(
            sut.model.openArchive?.summary.langs.map(\.lang) == ["en", "fr", "de"],
            "the added membership lands after the target — a chooser subtracting this set offers no re-add"
        )
    }

    // MARK: - Send count and completeness

    @Test("a fresh membership reads as fully missing and incomplete")
    func membershipAddSendCountAndCompleteness() async {
        let sut = await makeSUT()
        let added = sut.model.addArchiveLanguage(id: sut.id, lang: "fr")

        #expect(added)
        #expect(
            sut.model.openArchive?.summary.languageCount(for: "fr")
                == ArchiveLanguageCount(lang: "fr", translated: 0),
            "the membership row exists before anything is translated"
        )

        let sendCount = sut.model.archiveTranslationSendCount(lang: "fr")
        let complete = sut.model.archiveLanguageIsComplete("fr")

        #expect(sendCount == 3, "every sentence is still missing")
        #expect(!complete)
    }

    // MARK: - Per-row deliveries

    @Test("a per-row delivery refreshes the summary counts and bumps the revision")
    func perRowDeliveryRefreshesSummary() async {
        let sut = await makeSUT(translations: [0: SentenceTranslation(lang: "fr", text: "Seed")])
        let revisionBefore = sut.model.archiveRevision

        sut.model.applyTranslation(index: 1, translation: SentenceTranslation(lang: "fr", text: "Second"))
        sut.model.applyTranslation(index: 2, translation: SentenceTranslation(lang: "fr", text: "Third"))

        #expect(
            sut.model.openArchive?.summary.languageCount(for: "fr")
                == ArchiveLanguageCount(lang: "fr", translated: 3),
            "the banner's cached counts refresh in place"
        )
        #expect(
            sut.model.archiveTranslationSendCount(lang: "fr") == 3,
            "a complete language reads as a full re-send"
        )
        #expect(sut.model.archiveLanguageIsComplete("fr"))
        #expect(sut.model.archiveRevision != revisionBefore, "the revision bumps for the window's rows")
    }

    @Test("a failed archive-mode write warns without latching the live persistence")
    func failedArchiveWriteWarnsWithoutLatching() async {
        let sut = await makeSUT(translations: [0: SentenceTranslation(lang: "fr", text: "Seed")])
        #expect(sut.store.delete(id: sut.id), "the row is removed underneath the open pane")
        let revisionBefore = sut.model.archiveRevision

        let landed = sut.model.applyTranslation(
            index: 0, translation: SentenceTranslation(lang: "fr", text: "Third")
        )

        #expect(!landed, "the failed write reports itself")
        #expect(
            sut.model.entries.first?.translation(for: "fr")?.text == "Seed",
            "the row keeps its previous translation instead of a phantom one"
        )
        #expect(!sut.model.archiveWriteFailed, "an archive-mode failure never latches the live session")
        let warning = sut.model.toasts.toasts.first { toast in
            toast.key == ToastKey.archiveUnavailable
        }
        #expect(warning != nil, "the archive warning posts without latching")
        #expect(warning?.isClosable == true, "the archive-mode warning is dismissible")
        #expect(sut.model.archiveRevision == revisionBefore, "a failed write bumps nothing")
    }
}
