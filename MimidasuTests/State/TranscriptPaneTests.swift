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

    // MARK: - Landing observations

    @Test("a landing writes the row's cell and leaves the structural revision alone")
    func landingWritesTheRowCellOnly() throws {
        let pane = makePane()
        pane.append(sentence(0, text: "おはよう"))
        let cell = try #require(pane.translationCell(for: 0), "the append seeds a cell")
        let structural = pane.entriesRevision
        let landings = pane.landingRevision
        let translation = SentenceTranslation(lang: "fr", text: "Bonjour")

        #expect(pane.replaceTranslation(index: 0, translation: translation))

        #expect(cell.translations == [translation], "the row's own reader sees the landing")
        #expect(
            pane.entries[0].translations == [translation],
            "the row snapshot every non-observing reader uses agrees"
        )
        #expect(pane.entriesRevision == structural, "appends are the only structural signal")
        #expect(pane.landingRevision == landings + 1)
    }

    @Test("an identical redelivery writes neither the cell nor the landing signal")
    func identicalRedeliverySkipsTheLandingSignal() async throws {
        let pane = makePane()
        pane.append(sentence(0, text: "おはよう"))
        let translation = SentenceTranslation(lang: "fr", text: "Bonjour")
        #expect(pane.replaceTranslation(index: 0, translation: translation))
        let cell = try #require(pane.translationCell(for: 0))
        let landing = pane.landingRevision
        let cellReader = ObservedValuesRecorder(read: { cell.translations })

        // A retranslate with the same engine delivers byte-identical text.
        #expect(pane.replaceTranslation(index: 0, translation: translation))
        await flushObservations()

        #expect(cellReader.values.isEmpty, "a same-value delivery re-runs no row body")
        #expect(pane.landingRevision == landing, "and bumps no landing signal")
        #expect(pane.entries[0].translations == [translation])
    }

    @Test("a landing notifies no rows reader")
    func landingNotifiesNoRowsReader() async {
        let pane = makePane()
        pane.append(sentence(0, text: "おはよう"))
        let rows = ObservedValuesRecorder(read: { pane.entries })
        let inclusive = ObservedValuesRecorder(read: { pane.entriesIncludingLandings })

        pane.replaceTranslation(
            index: 0, translation: SentenceTranslation(lang: "fr", text: "Bonjour")
        )
        await flushObservations()

        #expect(rows.values.isEmpty, "a landing re-runs no surface that renders structure")
        #expect(inclusive.values.count == 1, "the landing-inclusive read refreshes once")
        #expect(inclusive.values.first?.first?.translations.map(\.text) == ["Bonjour"])
    }

    @Test("a structural change wakes the landing-inclusive reader too")
    func structuralChangeWakesInclusiveReader() async {
        let pane = makePane()
        pane.append(sentence(0, text: "おはよう"))
        let inclusive = ObservedValuesRecorder(read: { pane.entriesIncludingLandings })

        pane.append(sentence(1, text: "こんにちは"))
        await flushObservations()
        #expect(inclusive.values.count == 1, "an append refreshes the inclusive read")
        #expect(inclusive.values.first?.count == 2)

        pane.beginLiveSession()
        await flushObservations()
        #expect(inclusive.values.count == 2, "a clear refreshes it too")
        #expect(inclusive.values.last?.isEmpty == true)
    }

    @Test("a landing notifies only that row's own cell")
    func landingNotifiesOnlyItsOwnCell() async throws {
        let pane = makePane()
        pane.append(sentence(0, text: "おはよう"))
        pane.append(sentence(1, text: "こんにちは"))
        let first = try #require(pane.translationCell(for: 0))
        let second = try #require(pane.translationCell(for: 1))
        let firstReader = ObservedValuesRecorder(read: { first.translations })
        let secondReader = ObservedValuesRecorder(read: { second.translations })

        pane.replaceTranslation(
            index: 0, translation: SentenceTranslation(lang: "fr", text: "Bonjour")
        )
        await flushObservations()

        #expect(firstReader.values.count == 1, "the affected row refreshes")
        #expect(
            firstReader.values.first?.map(\.text) == ["Bonjour"],
            "the refreshed value is the landed one"
        )
        #expect(secondReader.values.isEmpty, "no other row's body re-runs")
    }

    @Test("opening a record seeds the landing cells from its stored rows")
    func openSessionSeedsLandingCells() throws {
        let fixture = makeArchiveFixture()
        let id = try #require(fixture.id)
        let stored = SentenceTranslation(lang: "fr", text: "Bonjour")
        #expect(fixture.store.upsert(translation: stored, index: 0, session: id))

        #expect(fixture.pane.openSession(id: id))

        #expect(fixture.pane.translationCell(for: 0)?.translations == [stored])
        #expect(fixture.pane.entries[0].translations == [stored])
        #expect(fixture.pane.translationCell(for: 1)?.translations.isEmpty == true)
    }

    @Test("swapping records reseeds the landing cells from the new session")
    func recordSwapReseedsLandingCells() throws {
        let store = isolatedArchive()
        let firstID = try #require(seedFinalized(store, sentences: ["こんにちは", "さようなら"]))
        let secondID = try #require(seedFinalized(store, sentences: ["おはよう", "こんばんは"]))
        let firstStored = SentenceTranslation(lang: "fr", text: "Bonjour")
        let secondStored = SentenceTranslation(lang: "fr", text: "Salut")
        #expect(store.upsert(translation: firstStored, index: 0, session: firstID))
        #expect(store.upsert(translation: secondStored, index: 0, session: secondID))
        let pane = TranscriptPane(projection: ArchiveProjection(store: store))

        #expect(pane.openSession(id: firstID))
        let firstCell = try #require(pane.translationCell(for: 0))

        // Swap records without an intervening clear: index 0 exists in both.
        #expect(pane.openSession(id: secondID))
        #expect(pane.openSessionID == secondID)
        #expect(
            pane.translationCell(for: 0)?.translations == [secondStored],
            "the swapped-in row observes its own session's cell"
        )
        #expect(firstCell.translations == [firstStored], "the replaced record's cell is untouched")

        let landing = SentenceTranslation(lang: "de", text: "Hallo")
        #expect(pane.replaceTranslation(index: 0, translation: landing))
        #expect(
            pane.translationCell(for: 0)?.translations.contains(where: { entry in
                entry.lang == "de"
            }) == true,
            "a landing on the new record writes its cell"
        )
        #expect(firstCell.translations == [firstStored], "and never the replaced record's")
    }

    @Test("clearing the pane drops its landing cells")
    func clearingDropsLandingCells() throws {
        let fixture = makeArchiveFixture()
        let id = try #require(fixture.id)
        fixture.pane.openSession(id: id)
        #expect(fixture.pane.translationCell(for: 0) != nil)

        fixture.pane.closeSession()
        #expect(fixture.pane.translationCell(for: 0) == nil)
        #expect(fixture.pane.translationCell(for: 1) == nil)

        fixture.pane.openSession(id: id)
        #expect(fixture.pane.translationCell(for: 0) != nil, "reopening seeds them again")

        fixture.pane.beginLiveSession()
        #expect(fixture.pane.translationCell(for: 0) == nil, "a fresh live session starts empty")
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
