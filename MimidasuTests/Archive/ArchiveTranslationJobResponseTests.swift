import Foundation
@testable import Mimidasu
import Testing

/// Deterministic engine double: answers every call with a fixed array — the
/// malformed responses the job has to reject (no result at all, an empty
/// translation).
private final class FixedResultEngine: TranslationEngine, @unchecked Sendable {
    let preferredBatchSize = 1
    var onRetry: (@Sendable (RetryProgress) -> Void)?

    private let result: [String]

    init(result: [String]) {
        self.result = result
    }

    func translate(_ texts: [String]) async throws -> [String] {
        result
    }
}

/// The job's guard against a malformed engine response: an answer carrying no
/// result, or an empty translation, is that sentence's retryable failure —
/// the walk continues and the malformed answer never lands.
@MainActor
@Suite("ArchiveTranslationJob response")
struct ArchiveTranslationJobResponseTests {

    // MARK: - Fixtures

    private func makeSentences(_ count: Int) -> [Sentence] {
        (0 ..< count).map { index in
            Sentence(
                index: index, startS: Double(index), endS: Double(index) + 1,
                lang: "ja", text: "s\(index)"
            )
        }
    }

    private func makeRequest(
        scope: ArchiveTranslationJob.Scope = .all
    ) -> ArchiveTranslationJob.Request {
        ArchiveTranslationJob.Request(
            sessionID: 42,
            lang: "en",
            engine: .google,
            sentences: makeSentences(3),
            translated: [],
            scope: scope
        )
    }

    // MARK: - Malformed responses

    @Test("an empty translation fails its sentence and the walk continues")
    func emptyTranslationCountsAsFailure() async {
        let job = ArchiveTranslationJob()
        let engine = FixedResultEngine(result: [""])
        job.resolveEngine = { _, _ in .ready(engine: engine, kind: .google) }
        let recorder = Recorder()
        job.onEvent = recorder.recordEvent
        job.land = recorder.recordLanding

        #expect(job.claim(makeRequest()))
        await job.run()

        #expect(recorder.landedIndexes.isEmpty, "a malformed answer never lands")
        #expect(job.translatedCount == 0)
        #expect(job.failureIndexes == [0, 1, 2], "every sentence fails")
        #expect(recorder.events.last == .finished(translated: 0, failedIndexes: [0, 1, 2]))
    }

    @Test("an answer carrying no result at all fails its sentence")
    func noResultCountsAsFailure() async {
        let job = ArchiveTranslationJob()
        let engine = FixedResultEngine(result: [])
        job.resolveEngine = { _, _ in .ready(engine: engine, kind: .google) }
        let recorder = Recorder()
        job.onEvent = recorder.recordEvent
        job.land = recorder.recordLanding

        #expect(job.claim(makeRequest()))
        await job.run()

        #expect(recorder.landedIndexes.isEmpty, "a malformed answer never lands")
        #expect(job.translatedCount == 0)
        #expect(job.failureIndexes == [0, 1, 2])
        #expect(recorder.events.last == .finished(translated: 0, failedIndexes: [0, 1, 2]))
    }
}
