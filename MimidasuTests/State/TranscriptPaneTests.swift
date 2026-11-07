import Foundation
@testable import Mimidasu
import Testing

/// Pins the transcript pane's one state module: the live append/clear
/// choreography, the in-place translation swap, and the archive record's
/// open/close join over the projection's summary.
@MainActor
@Suite("Transcript pane")
struct TranscriptPaneTests {

    // MARK: - Fixtures

    private struct Fixture {
        let store: ArchiveStore
        let projection: ArchiveProjection
        let pane: TranscriptPane
        let id: Int64?
    }

    private func sentence(_ index: Int, text: String) -> Sentence {
        Sentence(
            index: index, startS: Double(index), endS: Double(index) + 1,
            lang: "ja", text: text
        )
    }

    private func metadata(target: String = "en") -> SessionMetadata {
        SessionMetadata(
            startedAt: Date(timeIntervalSince1970: 1_000_000),
            sourceLang: "ja",
            targetLang: target,
            model: "test-model",
            chunkMS: 160
        )
    }

    /// A pane over an empty isolated archive — no app model needed.
    private func makePane() -> TranscriptPane {
        TranscriptPane(projection: ArchiveProjection(store: isolatedArchive()))
    }

    /// A pane over one finalized archive of `sentences`.
    private func makeArchiveFixture(
        sentences: [String] = ["こんにちは", "さようなら"],
        target: String = "en"
    ) -> Fixture {
        let store = isolatedArchive()
        let id = seedFinalized(store, sentences: sentences, target: target)
        let projection = ArchiveProjection(store: store)
        return Fixture(
            store: store,
            projection: projection,
            pane: TranscriptPane(projection: projection),
            id: id
        )
    }

    private func seedFinalized(
        _ store: ArchiveStore,
        sentences: [String],
        target: String = "en"
    ) -> Int64? {
        var id: Int64?
        for (index, text) in sentences.enumerated() {
            id = store.append(
                sentence: sentence(index, text: text),
                sessionID: id,
                metadata: metadata(target: target)
            )
        }
        guard let id else { return nil }
        store.finalize(session: id, durationMS: 5000, saved: false)
        return id
    }

    // MARK: - Live feed

    @Test("appending keeps row order, sums characters, and bumps the revision")
    func liveAppendAccumulatesRowsCharactersAndRevision() {
        let pane = makePane()
        let first = sentence(0, text: "テスト")
        let second = sentence(1, text: "こんにちは")
        let start = pane.entriesRevision

        pane.append(first)
        pane.append(second)

        #expect(pane.entries.map(\.sentence) == [first, second])
        #expect(pane.characterCount == "テスト".count + "こんにちは".count)
        #expect(pane.entriesRevision == start + 2)
        #expect(pane.openSessionID == nil)
    }

    @Test("replaceTranslation swaps the known row in place")
    func replaceTranslationSwapsKnownRowInPlace() {
        let pane = makePane()
        pane.append(sentence(0, text: "おはよう"))
        pane.append(sentence(1, text: "こんにちは"))
        let translation = SentenceTranslation(lang: "fr", text: "Bonjour")

        let replaced = pane.replaceTranslation(index: 1, translation: translation)

        #expect(replaced)
        #expect(pane.entries[1].translations == [translation])
        #expect(pane.entries[0].translations.isEmpty, "the other row is untouched")
        #expect(
            pane.characterCount == "おはよう".count + "こんにちは".count,
            "translations never count as transcript characters"
        )
    }

    @Test("replaceTranslation rejects an index the pane does not hold")
    func replaceTranslationRejectsUnknownIndex() {
        let pane = makePane()
        pane.append(sentence(0, text: "おはよう"))
        let before = pane.entries

        let replaced = pane.replaceTranslation(
            index: 99, translation: SentenceTranslation(lang: "fr", text: "Bonjour")
        )

        #expect(!replaced)
        #expect(pane.entries == before)
    }

    @Test("beginLiveSession empties the pane and resets its archive facts")
    func beginLiveSessionResetsTheArchivedPane() throws {
        let fixture = makeArchiveFixture()
        let id = try #require(fixture.id)
        fixture.pane.openSession(id: id)
        fixture.pane.selectViewingLanguage("fr")
        let start = fixture.pane.entriesRevision

        fixture.pane.beginLiveSession()

        #expect(fixture.pane.entries.isEmpty)
        #expect(fixture.pane.characterCount == 0)
        #expect(fixture.pane.viewingLanguage == nil)
        #expect(fixture.pane.openSessionID == nil)
        #expect(fixture.pane.openArchive == nil)
        #expect(fixture.pane.entriesRevision == start + 1)
        #expect(
            !fixture.pane.replaceTranslation(
                index: 0, translation: SentenceTranslation(lang: "fr", text: "Bonjour")
            ),
            "the position map cleared with the rows"
        )
    }

    // MARK: - Archive record

    @Test("openSession seeds the rows, characters, and open record")
    func openSessionSeedsThePane() throws {
        let fixture = makeArchiveFixture()
        let id = try #require(fixture.id)

        let opened = fixture.pane.openSession(id: id)

        #expect(opened)
        #expect(fixture.pane.entries.map(\.sentence.text) == ["こんにちは", "さようなら"])
        #expect(fixture.pane.characterCount == "こんにちは".count + "さようなら".count)
        #expect(fixture.pane.openSessionID == id)
        #expect(fixture.pane.openArchive?.summary.id == id)
        #expect(fixture.pane.openArchive?.entries == fixture.pane.entries)
        #expect(fixture.pane.viewingLanguage == nil)
    }

    @Test("selectViewingLanguage sets the archive override")
    func selectViewingLanguageSetsTheArchiveOverride() throws {
        let fixture = makeArchiveFixture()
        let id = try #require(fixture.id)
        fixture.pane.openSession(id: id)
        #expect(fixture.pane.viewingLanguage == nil, "an opened record starts on its stored target")

        fixture.pane.selectViewingLanguage("fr")

        #expect(fixture.pane.viewingLanguage == "fr")
    }

    @Test("a session-scoped translation lands only while its session is open")
    func sessionScopedReplacementRequiresTheOpenSession() throws {
        let fixture = makeArchiveFixture()
        let id = try #require(fixture.id)
        let otherID = try #require(seedFinalized(fixture.store, sentences: ["おはよう"]))
        fixture.pane.openSession(id: id)
        fixture.pane.selectViewingLanguage("fr")
        let translation = SentenceTranslation(lang: "fr", text: "Bonjour")

        let landed = fixture.pane.replaceTranslation(in: id, index: 0, translation: translation)
        let rejected = fixture.pane.replaceTranslation(
            in: otherID, index: 0, translation: SentenceTranslation(lang: "fr", text: "Autre")
        )

        #expect(landed)
        #expect(!rejected, "another session's landing is dropped")
        #expect(fixture.pane.entries[1].translations.isEmpty)
        #expect(fixture.pane.entries[0].translations == [translation])
    }

    @Test("closeSession empties the pane and drops the open record")
    func closeSessionClearsTheArchivedPane() throws {
        let fixture = makeArchiveFixture()
        let id = try #require(fixture.id)
        fixture.pane.openSession(id: id)
        fixture.pane.selectViewingLanguage("fr")
        let start = fixture.pane.entriesRevision

        fixture.pane.closeSession()

        #expect(fixture.pane.entries.isEmpty)
        #expect(fixture.pane.characterCount == 0)
        #expect(fixture.pane.viewingLanguage == nil)
        #expect(fixture.pane.openSessionID == nil)
        #expect(fixture.pane.openArchive == nil)
        #expect(fixture.pane.entriesRevision == start + 1)
        #expect(
            !fixture.pane.replaceTranslation(
                index: 0, translation: SentenceTranslation(lang: "fr", text: "Bonjour")
            ),
            "the position map cleared with the rows"
        )
    }

    @Test("an unknown openSession leaves the pane untouched")
    func unknownOpenSessionLeavesThePaneUntouched() throws {
        let fixture = makeArchiveFixture()
        let id = try #require(fixture.id)
        fixture.pane.openSession(id: id)
        fixture.pane.selectViewingLanguage("fr")
        let entriesBefore = fixture.pane.entries
        let revisionBefore = fixture.pane.entriesRevision

        let opened = fixture.pane.openSession(id: id + 999)

        #expect(!opened)
        #expect(fixture.pane.entries == entriesBefore)
        #expect(fixture.pane.characterCount == "こんにちは".count + "さようなら".count)
        #expect(fixture.pane.viewingLanguage == "fr")
        #expect(fixture.pane.openSessionID == id)
        #expect(fixture.pane.entriesRevision == revisionBefore)
    }

    @Test("openArchive joins the projection's summary with the pane's rows")
    func openArchiveJoinsTheProjectionSummary() throws {
        let fixture = makeArchiveFixture()
        let id = try #require(fixture.id)
        #expect(fixture.store.rename(id: id, name: "Lecture 3"))

        fixture.pane.openSession(id: id)

        #expect(fixture.pane.openArchive?.summary.name == "Lecture 3")
        #expect(fixture.pane.openArchive?.summary == fixture.projection.openSummary)
        #expect(fixture.pane.openArchive?.entries.map(\.sentence.text) == ["こんにちは", "さようなら"])
    }
}
