@testable import Mimidasu
import Testing

/// Pins the live writer's ordering contract against a real store: queued
/// commands land in submission order, the first append resolves the recording
/// row for everything behind it, and `drain()` does not resume until those
/// writes and their main-actor callbacks have run.
@MainActor
@Suite("Archive write lane")
struct ArchiveWriteLaneTests {

    /// The lane's main-actor callbacks, recorded for one test.
    @MainActor
    private final class CallbackLog {
        var adoptedIDs: [Int64] = []
        var failureCount = 0
    }

    @Test("queued writes land in submission order and drain is a barrier")
    func queuedWritesLandInSubmissionOrder() async throws {
        let store = isolatedArchive()
        let lane = ArchiveWriteLane(store: store)
        let callbacks = CallbackLog()
        lane.bind(
            recordingIDAdopted: { id in
                callbacks.adoptedIDs.append(id)
            },
            writeFailed: {
                callbacks.failureCount += 1
            }
        )

        let first = archiveSentence(0, text: "こんにちは")
        let second = archiveSentence(1, text: "さようなら")
        let firstTranslation = SentenceTranslation(lang: "en", text: "Hello")
        let secondTranslation = SentenceTranslation(lang: "en", text: "Goodbye")

        // The pause sync queued before the row exists is a no-op; the two
        // queued after the appends land on the adopted row in order.
        lane.syncPaused(pausedMS: 500)
        lane.append(sentence: first, metadata: archiveMetadata(target: "en"))
        lane.upsert(translation: firstTranslation, index: 0)
        lane.syncPaused(pausedMS: 1500)
        lane.append(sentence: second, metadata: archiveMetadata(target: "en"))
        lane.upsert(translation: secondTranslation, index: 1)
        lane.syncPaused(pausedMS: 2500)

        await lane.drain()

        let id = try #require(
            callbacks.adoptedIDs.first,
            "the first successful append adopts the recording row"
        )
        #expect(callbacks.adoptedIDs == [id], "only the append that creates the row adopts an id")
        #expect(callbacks.failureCount == 0, "every queued write landed")

        let loaded = try #require(store.load(id: id), "the drained row reads back")
        #expect(loaded.summary.status == .recording, "the row is still the live recording")
        #expect(
            loaded.entries.map { entry in entry.sentence.text } == ["こんにちは", "さようなら"],
            "appends land in submission order"
        )
        #expect(
            loaded.entries.map { entry in entry.translation(for: "en")?.text }
                == ["Hello", "Goodbye"],
            "each upsert lands on the row its append created"
        )
        #expect(loaded.summary.pausedMS == 2500, "the last queued pause sync wins")
    }

    @Test("a lost write latches the writer and reset starts a new session")
    func lostWriteLatchesAndResetStartsNewSession() async throws {
        let store = isolatedArchive()
        let lane = ArchiveWriteLane(store: store)
        let callbacks = CallbackLog()
        lane.bind(
            recordingIDAdopted: { id in
                callbacks.adoptedIDs.append(id)
            },
            writeFailed: {
                callbacks.failureCount += 1
            }
        )
        let first = archiveSentence(0, text: "こんにちは")
        let second = archiveSentence(1, text: "さようなら")
        lane.append(sentence: first, metadata: archiveMetadata(target: "en"))
        await lane.drain()
        let id = try #require(callbacks.adoptedIDs.first, "the first append creates the row")

        // The row vanishes underneath the session: the next write is lost.
        #expect(store.delete(id: id))
        lane.upsert(translation: SentenceTranslation(lang: "en", text: "Hello"), index: 0)
        await lane.drain()

        #expect(callbacks.failureCount == 1, "the lost write reports once")

        // A latched writer keeps dropping the session's writes.
        lane.append(sentence: second, metadata: archiveMetadata(target: "en"))
        await lane.drain()
        #expect(callbacks.adoptedIDs.count == 1, "a latched session adopts nothing more")

        // The next session starts from a clean slate.
        lane.reset()
        lane.append(sentence: second, metadata: archiveMetadata(target: "en"))
        await lane.drain()
        #expect(callbacks.adoptedIDs.count == 2, "the reset session adopts its own row")
        let newID = try #require(callbacks.adoptedIDs.last)
        #expect(
            store.load(id: newID)?.entries.map { entry in entry.sentence.text } == ["さようなら"],
            "the reset session's writes land on its own row"
        )
        #expect(callbacks.failureCount == 1, "a reset clears the latch without a new report")
    }

    @Test("a reset forgets the row, so a later pause sync writes nothing")
    func resetForgetsTheRowForPauseSync() async throws {
        let store = isolatedArchive()
        let lane = ArchiveWriteLane(store: store)
        let callbacks = CallbackLog()
        lane.bind(
            recordingIDAdopted: { id in
                callbacks.adoptedIDs.append(id)
            },
            writeFailed: {
                callbacks.failureCount += 1
            }
        )
        lane.append(
            sentence: archiveSentence(0, text: "こんにちは"),
            metadata: archiveMetadata(target: "en")
        )
        await lane.drain()
        let id = try #require(callbacks.adoptedIDs.first, "the append creates the row")

        lane.reset()
        await lane.drain()
        lane.syncPaused(pausedMS: 4000)
        await lane.drain()

        #expect(
            store.load(id: id)?.summary.pausedMS == 0,
            "a forgotten row takes no pause write"
        )
    }
}
