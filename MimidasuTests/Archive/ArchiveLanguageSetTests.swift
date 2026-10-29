import Foundation
@testable import Mimidasu
import Testing

/// The pure language rules one stored summary exposes: ordered counts,
/// completeness, send counts, and the addable-target complement against the
/// runtime OS catalog.
@Suite("Archive language set")
struct ArchiveLanguageSetTests {

    private func summary(
        sentenceCount: Int = 3,
        targetLang: String? = "en",
        langs: [ArchiveLanguageCount] = [
            ArchiveLanguageCount(lang: "en", translated: 3),
            ArchiveLanguageCount(lang: "fr", translated: 1)
        ]
    ) -> ArchivedSessionSummary {
        ArchivedSessionSummary(
            id: 1,
            status: .complete,
            saved: false,
            startedAt: Date(timeIntervalSince1970: 1_000_000),
            durationS: 90,
            pausedMS: 0,
            sentenceCount: sentenceCount,
            targetLang: targetLang,
            model: "test-model",
            chunkMS: 160,
            name: nil,
            firstSentence: nil,
            langs: langs
        )
    }

    // MARK: - Counts

    @Test("counts preserve the summary's order")
    func countsPreserveOrder() {
        let sut = ArchiveLanguageSet(summary: summary())

        #expect(sut.counts.map(\.lang) == ["en", "fr"])
        #expect(sut.targetLang == "en")
        #expect(sut.sentenceCount == 3)
    }

    @Test("count(for:) finds a held language and misses an unknown one")
    func countLookup() {
        let sut = ArchiveLanguageSet(summary: summary())

        #expect(sut.count(for: "fr")?.translated == 1)
        #expect(sut.translatedCount(for: "fr") == 1)
        #expect(sut.count(for: "de") == nil)
        #expect(sut.translatedCount(for: "de") == 0)
    }

    // MARK: - Completeness

    @Test("completeness needs a non-empty session")
    func completenessNeedsSentences() {
        let empty = ArchiveLanguageSet(
            summary: summary(
                sentenceCount: 0,
                langs: [ArchiveLanguageCount(lang: "en", translated: 0)]
            )
        )

        #expect(!empty.isComplete("en"))
    }

    @Test("completeness is false for a missing or partial language")
    func completenessPartial() {
        let sut = ArchiveLanguageSet(summary: summary())

        #expect(!sut.isComplete("fr"))
        #expect(!sut.isComplete("de"))
    }

    @Test("completeness is true at the exact count and above it")
    func completenessAtAndOverCount() {
        let sut = ArchiveLanguageSet(
            summary: summary(
                sentenceCount: 3,
                langs: [
                    ArchiveLanguageCount(lang: "en", translated: 3),
                    ArchiveLanguageCount(lang: "fr", translated: 4)
                ]
            )
        )

        #expect(sut.isComplete("en"))
        #expect(sut.isComplete("fr"))
    }

    // MARK: - Send counts

    @Test("missingCount clamps at zero and sendCount re-sends a complete language")
    func missingAndSendCounts() {
        let sut = ArchiveLanguageSet(summary: summary())

        #expect(sut.missingCount("en") == 0)
        #expect(sut.missingCount("fr") == 2)
        #expect(sut.missingCount("de") == 3)
        #expect(sut.sendCount("en") == 3, "a complete language re-sends every sentence")
        #expect(sut.sendCount("fr") == 2)
        #expect(sut.sendCount("de") == 3)
    }

    @Test("a zero-sentence session sends nothing")
    func zeroSentenceSendCount() {
        let sut = ArchiveLanguageSet(
            summary: summary(
                sentenceCount: 0,
                langs: [ArchiveLanguageCount(lang: "en", translated: 0)]
            )
        )

        #expect(sut.missingCount("en") == 0)
        #expect(sut.sendCount("en") == 0)
    }

    // MARK: - Addability

    @Test("addableTargets is nil while the OS catalog has not loaded")
    func addableTargetsWhileLoading() {
        let sut = ArchiveLanguageSet(summary: summary(), targets: [.english], targetsLoaded: false)

        #expect(sut.addableTargets() == nil)
        #expect(!sut.canAddLanguage)
    }

    @Test("addableTargets is empty when every target is held")
    func addableTargetsEmptyWhenComplete() {
        let sut = ArchiveLanguageSet(
            summary: summary(
                langs: [
                    ArchiveLanguageCount(lang: "en", translated: 0),
                    ArchiveLanguageCount(lang: "fr", translated: 0)
                ]
            ),
            targets: [.english, TargetLanguage(code: "fr")],
            targetsLoaded: true
        )

        #expect(sut.addableTargets() == [])
        #expect(!sut.canAddLanguage)
    }

    @Test("addableTargets is the exact complement of the held codes")
    func addableTargetsComplement() {
        let sut = ArchiveLanguageSet(
            summary: summary(),
            targets: [.english, TargetLanguage(code: "fr"), TargetLanguage(code: "de")],
            targetsLoaded: true
        )

        #expect(sut.addableTargets()?.map(\.code) == ["de"])
        #expect(sut.canAddLanguage)
    }

    @Test("unknown stored codes are held and never re-offered")
    func unknownStoredCodeIsHeld() {
        let sut = ArchiveLanguageSet(
            summary: summary(
                langs: [
                    ArchiveLanguageCount(lang: "en", translated: 0),
                    ArchiveLanguageCount(lang: "xx-unknown", translated: 0)
                ]
            ),
            targets: [.english, TargetLanguage(code: "de")],
            targetsLoaded: true
        )

        #expect(sut.addableTargets()?.map(\.code) == ["de"])
        #expect(sut.count(for: "xx-unknown") != nil)
    }

    @Test("duplicate catalog entries appear once")
    func duplicateCatalogEntriesAppearOnce() {
        let sut = ArchiveLanguageSet(
            summary: summary(langs: [ArchiveLanguageCount(lang: "en", translated: 0)]),
            targets: [TargetLanguage(code: "de"), TargetLanguage(code: "de")],
            targetsLoaded: true
        )

        #expect(sut.addableTargets()?.map(\.code) == ["de"])
    }
}
