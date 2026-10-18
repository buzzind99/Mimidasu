import Foundation
@testable import Mimidasu
import Testing

/// The archive store's durable side: lazy session creation on the first
/// sentence, sentence/translation persistence, finalize, the recents cap,
/// promote/rename/delete, the interrupted sweep, and the degraded latch.
/// Every test owns a private temp directory and removes it with `defer`.
@MainActor
@Suite("ArchiveStore")
struct ArchiveStoreTests {

    // MARK: - Fixtures

    private func makeLocation(prefix: String = "mimidasu-archive-store") -> (URL, () -> Void) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        return (
            root.appendingPathComponent("archives.sqlite"),
            { try? FileManager.default.removeItem(at: root) }
        )
    }

    private func makeStore() -> (ArchiveStore, () -> Void) {
        let (location, cleanup) = makeLocation()
        return (ArchiveStore(location: location), cleanup)
    }

    private func metadata(
        startedAt: TimeInterval = 1_000_000, targetLang: String? = "en"
    ) -> SessionMetadata {
        SessionMetadata(
            startedAt: Date(timeIntervalSince1970: startedAt),
            sourceLang: "ja",
            targetLang: targetLang,
            model: "test-model",
            chunkMS: 160
        )
    }

    private func sentence(
        _ index: Int, start: Double = 0, end: Double = 1.5,
        text: String = "こんにちは", lang: String = "ja"
    ) -> Sentence {
        Sentence(index: index, startS: start, endS: end, lang: lang, text: text)
    }

    /// Appends one sentence and returns the created session id.
    @discardableResult
    private func startSession(
        _ store: ArchiveStore, startedAt: TimeInterval = 1_000_000,
        text: String = "こんにちは", end: Double = 1.5
    ) -> Int64? {
        store.append(
            sentence: sentence(0, end: end, text: text),
            sessionID: nil, metadata: metadata(startedAt: startedAt)
        )
    }

    /// A finalized recent with one sentence, dated `startedAt`.
    @discardableResult
    private func finalizeRecent(
        _ store: ArchiveStore, startedAt: TimeInterval, durationS: Int = 5
    ) -> Int64? {
        guard let id = store.append(
            sentence: sentence(0), sessionID: nil, metadata: metadata(startedAt: startedAt)
        ) else { return nil }
        store.finalize(session: id, durationMS: durationS * 1000, saved: false)
        return id
    }

    // MARK: - Lazy creation & persistence

    @Test("an empty store lists nothing and holds no session")
    func emptyStoreListsNothing() {
        let (store, cleanup) = makeStore()
        defer { cleanup() }

        #expect(store.list().isEmpty)
        #expect(store.load(id: 1) == nil)
    }

    @Test("the first sentence creates the session and later ones reuse it")
    func firstSentenceCreatesSession() {
        let (store, cleanup) = makeStore()
        defer { cleanup() }

        let first = store.append(sentence: sentence(0), sessionID: nil, metadata: metadata())
        #expect(first != nil)
        let second = store.append(sentence: sentence(1, start: 2, end: 3), sessionID: first, metadata: metadata())
        #expect(second == first)

        guard let loaded = store.load(id: first ?? -1) else {
            Issue.record("session should load")
            return
        }
        #expect(loaded.entries.count == 2)
        #expect(loaded.entries.map { entry in entry.sentence.index } == [0, 1])
    }

    @Test("a recording session is not listed")
    func recordingSessionNotListed() {
        let (store, cleanup) = makeStore()
        defer { cleanup() }

        startSession(store)

        #expect(store.list().isEmpty)
    }

    @Test("sentence spans and text round-trip through load")
    func sentenceRoundTrips() {
        let (store, cleanup) = makeStore()
        defer { cleanup() }

        guard let id = store.append(
            sentence: sentence(0, start: 1.25, end: 3.75, text: "今日はいい天気ですね。"),
            sessionID: nil, metadata: metadata()
        ) else {
            Issue.record("append should succeed")
            return
        }

        let loaded = store.load(id: id)
        #expect(loaded?.entries.first?.sentence.startS == 1.25)
        #expect(loaded?.entries.first?.sentence.endS == 3.75)
        #expect(loaded?.entries.first?.sentence.text == "今日はいい天気ですね。")
    }

    @Test("a translation is stored and joins the loaded row")
    func translationRoundTrips() {
        let (store, cleanup) = makeStore()
        defer { cleanup() }

        guard let id = startSession(store) else {
            Issue.record("append should succeed")
            return
        }
        let ok = store.upsert(
            translation: SentenceTranslation(lang: "en", text: "Hello", engine: .google),
            index: 0, session: id
        )
        #expect(ok)

        let entry = store.load(id: id)?.entries.first
        #expect(entry?.translations == [
            SentenceTranslation(lang: "en", text: "Hello", engine: .google)
        ])
        #expect(entry?.joinedTranslations == "Hello")
    }

    @Test("a re-upsert for the same language replaces in place")
    func translationUpsertReplaces() {
        let (store, cleanup) = makeStore()
        defer { cleanup() }

        guard let id = startSession(store) else {
            Issue.record("append should succeed")
            return
        }
        store.upsert(translation: SentenceTranslation(lang: "en", text: "one"), index: 0, session: id)
        store.upsert(
            translation: SentenceTranslation(lang: "en", text: "two", engine: .deepl),
            index: 0, session: id
        )

        let entry = store.load(id: id)?.entries.first
        #expect(entry?.translations.count == 1)
        #expect(entry?.translations.first?.text == "two")
        #expect(entry?.translations.first?.engine == .deepl)
    }

    // MARK: - Finalize & the recents cap

    @Test("finalize sets complete status, duration, and the saved flag")
    func finalizeSetsComplete() {
        let (store, cleanup) = makeStore()
        defer { cleanup() }

        guard let id = startSession(store) else {
            Issue.record("append should succeed")
            return
        }
        #expect(store.finalize(session: id, durationMS: 12500, saved: false))

        guard let summary = store.list().first else {
            Issue.record("finalized session should be listed")
            return
        }
        #expect(summary.id == id)
        #expect(summary.status == .complete)
        #expect(summary.saved == false)
        #expect(summary.durationS == 12)
        #expect(summary.sentenceCount == 1)
        #expect(summary.targetLang == "en")
        #expect(summary.model == "test-model")
        #expect(summary.chunkMS == 160)
    }

    @Test("the 11th recent evicts the oldest, and Saved rows always survive")
    func capEvictsOldestUnsaved() {
        let (store, cleanup) = makeStore()
        defer { cleanup() }

        // One Saved session older than everything, then 11 recents.
        guard let saved = finalizeRecent(store, startedAt: 0) else {
            Issue.record("seed should succeed")
            return
        }
        #expect(store.promote(id: saved))

        var recentIDs: [Int64] = []
        for offset in 1 ... 11 {
            guard let id = finalizeRecent(store, startedAt: TimeInterval(1000 + offset)) else {
                Issue.record("recent \(offset) should persist")
                return
            }
            recentIDs.append(id)
        }

        let listed = store.list()
        let recents = listed.filter { summary in !summary.saved }
        #expect(recents.count == ArchiveStore.recentCap)
        // The oldest recent (the first one, right after the Saved row) is gone.
        #expect(!recents.contains { summary in summary.id == recentIDs[0] })
        #expect(recents.contains { summary in summary.id == recentIDs[10] })
        #expect(listed.contains { summary in summary.id == saved })
    }

    @Test("promote moves a recent to the Saved tier")
    func promoteMovesToSaved() {
        let (store, cleanup) = makeStore()
        defer { cleanup() }

        guard let id = finalizeRecent(store, startedAt: 1000) else {
            Issue.record("seed should succeed")
            return
        }
        #expect(store.promote(id: id))

        #expect(store.list().first?.saved == true)
    }

    // MARK: - Open / delete / rename

    @Test("load returns summary and entries; unknown ids return nil")
    func loadReturnsSummaryAndEntries() {
        let (store, cleanup) = makeStore()
        defer { cleanup() }

        guard let id = startSession(store, text: "一つ目") else {
            Issue.record("append should succeed")
            return
        }
        store.finalize(session: id, durationMS: 1000, saved: false)

        let loaded = store.load(id: id)
        #expect(loaded?.summary.displayTitle.isEmpty == false)
        #expect(loaded?.entries.map { entry in entry.sentence.text } == ["一つ目"])
        #expect(loaded?.characterCount == 3)
        #expect(store.load(id: id + 999) == nil)
    }

    @Test("delete removes the session and cascades to its sentences")
    func deleteCascades() {
        let (store, cleanup) = makeStore()
        defer { cleanup() }

        guard let id = finalizeRecent(store, startedAt: 1000) else {
            Issue.record("seed should succeed")
            return
        }
        #expect(store.delete(id: id))

        #expect(store.list().isEmpty)
        #expect(store.load(id: id) == nil)
    }

    @Test("rename stores the trimmed name and clears to nil on empty")
    func renameSetsAndClears() {
        let (store, cleanup) = makeStore()
        defer { cleanup() }

        guard let id = finalizeRecent(store, startedAt: 1000) else {
            Issue.record("seed should succeed")
            return
        }
        #expect(store.rename(id: id, name: "  Interview with Tanaka-san  "))
        #expect(store.list().first?.name == "Interview with Tanaka-san")

        #expect(store.rename(id: id, name: "   "))
        #expect(store.list().first?.name == nil)
    }

    @Test("rows list newest first")
    func listOrdersNewestFirst() {
        let (store, cleanup) = makeStore()
        defer { cleanup() }

        finalizeRecent(store, startedAt: 1000)
        finalizeRecent(store, startedAt: 3000)
        finalizeRecent(store, startedAt: 2000)

        let startedAts = store.list().map { summary in summary.startedAt.timeIntervalSince1970 }
        #expect(startedAts == [3000, 2000, 1000])
    }

    // MARK: - Sweep

    @Test("sweep flips a leftover recording row to interrupted with the last sentence's end")
    func sweepFlipsRecording() {
        let (location, cleanup) = makeLocation()
        defer { cleanup() }

        let first = ArchiveStore(location: location)
        guard let id = first.append(
            sentence: sentence(0, end: 42.5), sessionID: nil, metadata: metadata()
        ) else {
            Issue.record("append should succeed")
            return
        }
        // No finalize: the process "died" here. A fresh store sweeps on init.
        let second = ArchiveStore(location: location)
        #expect(second.sweepInterrupted())

        guard let summary = second.list().first else {
            Issue.record("swept session should be listed")
            return
        }
        #expect(summary.id == id)
        #expect(summary.status == .interrupted)
        #expect(summary.durationS == 42)
    }

    @Test("sweep never touches finalized sessions")
    func sweepLeavesFinalizedAlone() {
        let (location, cleanup) = makeLocation()
        defer { cleanup() }

        let first = ArchiveStore(location: location)
        guard let id = first.append(sentence: sentence(0), sessionID: nil, metadata: metadata()) else {
            Issue.record("append should succeed")
            return
        }
        first.finalize(session: id, durationMS: 9000, saved: false)

        let second = ArchiveStore(location: location)
        second.sweepInterrupted()

        #expect(second.list().first?.status == .complete)
        #expect(second.list().first?.durationS == 9)
    }

    // MARK: - Paused total

    @Test("the paused total round-trips into the summary")
    func pausedTotalRoundTrips() {
        let (store, cleanup) = makeStore()
        defer { cleanup() }

        guard let id = startSession(store) else {
            Issue.record("append should succeed")
            return
        }
        #expect(store.syncPaused(session: id, pausedMS: 95000))
        store.finalize(session: id, durationMS: 300_000, saved: false)

        guard let summary = store.list().first else {
            Issue.record("finalized session should be listed")
            return
        }
        #expect(summary.pausedMS == 95000)
        #expect(summary.durationS == 300)
        #expect(summary.sentenceCount == 1)
    }

    // MARK: - Degraded

    @Test("an unopenable location degrades the store: no writes, no list, isDegraded")
    func unopenableLocationDegrades() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mimidasu-archive-blocked-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // A *file* where the database's parent directory should be: creating
        // the directory fails, and the file itself can never open as a DB.
        let blocker = root.appendingPathComponent("blocker")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? Data().write(to: blocker)

        let store = ArchiveStore(location: blocker.appendingPathComponent("archives.sqlite"))

        #expect(store.isDegraded)
        #expect(store.append(sentence: sentence(0), sessionID: nil, metadata: metadata()) == nil)
        #expect(store.list().isEmpty)
        #expect(store.upsert(translation: SentenceTranslation(lang: "en", text: "x"), index: 0, session: 1) == false)
        #expect(store.promote(id: 1) == false)
        #expect(store.delete(id: 1) == false)
    }
}

// MARK: - Language membership

/// The language-membership cases extend the store suite from its own
/// extension (the same suite, reusing its private fixtures), so both
/// declarations stay a readable size.
extension ArchiveStoreTests {

    /// Raw membership-row count for one session. A cascade leak is invisible
    /// through the store's reads (a deleted session is never loaded), so the
    /// one way to see the orphaned rows is the schema itself.
    private func membershipRowCount(at location: URL, id: Int64) throws -> Int {
        let database = try SQLiteDatabase(path: location.path)
        let statement = try database.statement(
            "SELECT COUNT(*) FROM session_languages WHERE session_id = :id"
        )
        statement.bind(Int(id), at: 1)
        _ = try statement.step()
        return statement.optionalInt(0) ?? -1
    }

    @Test("addLanguage registers membership and a repeat add is a no-op")
    func addLanguageIsIdempotent() {
        let (store, cleanup) = makeStore()
        defer { cleanup() }

        guard let id = startSession(store) else {
            Issue.record("append should succeed")
            return
        }
        #expect(store.addLanguage(id: id, lang: "fr"))
        #expect(store.addLanguage(id: id, lang: "fr"))

        #expect(
            store.summary(id: id)?.langs.map { count in count.lang } == ["en", "fr"],
            "the repeat add does not duplicate the membership"
        )
    }

    @Test("membership lists at zero translated before any translation lands")
    func membershipListsAtZero() {
        let (store, cleanup) = makeStore()
        defer { cleanup() }

        guard let id = startSession(store) else {
            Issue.record("append should succeed")
            return
        }
        store.finalize(session: id, durationMS: 1000, saved: false)
        #expect(store.addLanguage(id: id, lang: "fr"))

        #expect(
            store.summary(id: id)?.languageCount(for: "fr")
                == ArchiveLanguageCount(lang: "fr", translated: 0)
        )
        #expect(store.list().first?.languageCount(for: "fr")?.translated == 0)
    }

    @Test("the language count reflects exactly the upserted rows")
    func languageCountReflectsUpserts() {
        let (store, cleanup) = makeStore()
        defer { cleanup() }

        guard let id = store.append(sentence: sentence(0), sessionID: nil, metadata: metadata()) else {
            Issue.record("append should succeed")
            return
        }
        store.append(sentence: sentence(1, start: 2, end: 3), sessionID: id, metadata: metadata())
        store.append(sentence: sentence(2, start: 4, end: 5), sessionID: id, metadata: metadata())
        #expect(store.addLanguage(id: id, lang: "fr"))
        store.upsert(translation: SentenceTranslation(lang: "fr", text: "un"), index: 0, session: id)
        store.upsert(translation: SentenceTranslation(lang: "fr", text: "trois"), index: 2, session: id)

        #expect(
            store.summary(id: id)?.languageCount(for: "fr")
                == ArchiveLanguageCount(lang: "fr", translated: 2)
        )
    }

    @Test("languages order target first, then membership, then translation-only")
    func languageSetOrdering() {
        let (store, cleanup) = makeStore()
        defer { cleanup() }

        guard let id = startSession(store) else {
            Issue.record("append should succeed")
            return
        }
        #expect(store.addLanguage(id: id, lang: "fr"))
        #expect(store.addLanguage(id: id, lang: "de"))
        store.upsert(translation: SentenceTranslation(lang: "es", text: "Hola"), index: 0, session: id)

        #expect(store.summary(id: id)?.langs.map { count in count.lang } == ["en", "fr", "de", "es"])
    }

    @Test("a session without membership lists its target and translation languages")
    func translationOnlyLanguageSet() {
        let (store, cleanup) = makeStore()
        defer { cleanup() }

        guard let id = startSession(store) else {
            Issue.record("append should succeed")
            return
        }
        store.upsert(translation: SentenceTranslation(lang: "fr", text: "Bonjour"), index: 0, session: id)
        store.upsert(translation: SentenceTranslation(lang: "es", text: "Hola"), index: 0, session: id)

        #expect(store.summary(id: id)?.langs.map { count in count.lang } == ["en", "fr", "es"])
        #expect(store.summary(id: id)?.languageCount(for: "fr")?.translated == 1)
    }

    @Test("delete cascades to the session's membership rows")
    func deleteCascadesMembership() throws {
        let (location, cleanup) = makeLocation()
        defer { cleanup() }

        let store = ArchiveStore(location: location)
        guard let id = startSession(store) else {
            Issue.record("append should succeed")
            return
        }
        #expect(store.addLanguage(id: id, lang: "fr"))
        #expect(store.delete(id: id))

        let reopened = ArchiveStore(location: location)
        #expect(reopened.summary(id: id) == nil, "the deleted id can't be queried")
        #expect(try membershipRowCount(at: location, id: id) == 0, "no orphan membership row survives")
    }

    @Test("summary returns nil for an unknown id")
    func summaryUnknownIDIsNil() {
        let (store, cleanup) = makeStore()
        defer { cleanup() }

        #expect(store.summary(id: 999) == nil)
    }
}
