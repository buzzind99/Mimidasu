@testable import Mimidasu
import Testing

/// The ordered end seam: every collaborator appends to one shared log so a
/// single happy-path run pins the whole sequence, and the duration /
/// finalize pair decides whether the archive toast follows.
@MainActor
@Suite("SessionLifecycle end sequence")
struct SessionLifecycleTests {

    // MARK: - SUT

    private struct SUT {
        let lifecycle: SessionLifecycle
        let host: SpyLifecycleHost
    }

    private func makeSUT(
        log: LifecycleLog,
        durationMS: Int?,
        finalizeResult: Bool
    ) -> SUT {
        SUT(
            lifecycle: SessionLifecycle(
                controller: SpyStopping(log: log),
                translationSession: SpyBoundaryEnding(log: log, label: "live.end"),
                retranslate: SpyBoundaryEnding(log: log, label: "lane.end")
            ),
            host: SpyLifecycleHost(log: log, durationMS: durationMS, finalizeResult: finalizeResult)
        )
    }

    // MARK: - Order

    @Test("the end sequence runs every step in one fixed order")
    func endRunsInFixedOrder() async {
        let log = LifecycleLog()
        let sut = makeSUT(log: log, durationMS: 1234, finalizeResult: true)

        await sut.lifecycle.end(host: sut.host)

        #expect(
            log.entries == [
                "pause.close",
                "controller.stop",
                "live.end",
                "lane.end",
                "teardown.finish",
                "duration",
                "finalize",
                "toast"
            ],
            "got \(log.entries)"
        )
        #expect(sut.host.finalizeDurationsMS == [1234], "the finalize receives the measured duration")
    }

    // MARK: - Duration / finalize branches

    @Test("no session duration skips both the finalize and the toast")
    func nilDurationSkipsFinalizeAndToast() async {
        let log = LifecycleLog()
        let sut = makeSUT(log: log, durationMS: nil, finalizeResult: true)

        await sut.lifecycle.end(host: sut.host)

        #expect(
            log.entries == [
                "pause.close",
                "controller.stop",
                "live.end",
                "lane.end",
                "teardown.finish",
                "duration"
            ],
            "got \(log.entries)"
        )
        #expect(!log.entries.contains("finalize"), "no duration means no recording row")
        #expect(sut.host.finalizeDurationsMS.isEmpty, "no duration means no finalize call")
        #expect(!log.entries.contains("toast"), "no recording row means no toast")
    }

    @Test("a duration with a rejected finalize skips only the toast")
    func finalizeFalseSkipsToastOnly() async {
        let log = LifecycleLog()
        let sut = makeSUT(log: log, durationMS: 900, finalizeResult: false)

        await sut.lifecycle.end(host: sut.host)

        #expect(
            log.entries == [
                "pause.close",
                "controller.stop",
                "live.end",
                "lane.end",
                "teardown.finish",
                "duration",
                "finalize"
            ],
            "got \(log.entries)"
        )
        #expect(!log.entries.contains("toast"), "a rejected finalize must not announce itself")
    }

    @Test("a duration with an accepted finalize posts the toast")
    func finalizeTruePostsToast() async {
        let log = LifecycleLog()
        let sut = makeSUT(log: log, durationMS: 42000, finalizeResult: true)

        await sut.lifecycle.end(host: sut.host)

        #expect(log.entries.suffix(2) == ["finalize", "toast"], "got \(log.entries)")
    }

    // MARK: - Ended-at plumbing

    @Test("teardown and duration see the same ended-at instant")
    func teardownAndDurationShareEndedAt() async throws {
        let log = LifecycleLog()
        let sut = makeSUT(log: log, durationMS: 1000, finalizeResult: true)

        await sut.lifecycle.end(host: sut.host)

        let teardownEndedAt = try #require(sut.host.teardownEndedAt, "teardown never ran")
        let durationEndedAt = try #require(sut.host.durationEndedAt, "duration never ran")
        #expect(teardownEndedAt == durationEndedAt, "one ended-at instant, not two clocks")
    }

    // MARK: - The stop seam on the real controller

    @Test("SessionController satisfies the stop seam")
    func sessionControllerConformsToStopping() {
        #expect(SessionController.self is any SessionStopping.Type)
    }
}

// MARK: - Shared log

/// Ordered record shared by every spy in a test: one array decides the
/// expected end sequence, so a reorder fails the equality check outright.
@MainActor
final class LifecycleLog {
    private(set) var entries: [String] = []

    func record(_ entry: String) {
        entries.append(entry)
    }
}

// MARK: - Spies

@MainActor
final class SpyStopping: SessionStopping {
    private let log: LifecycleLog

    init(log: LifecycleLog) {
        self.log = log
    }

    func stop() async {
        log.record("controller.stop")
    }
}

@MainActor
final class SpyBoundaryEnding: SessionBoundaryEnding {
    private let log: LifecycleLog
    private let label: String

    init(log: LifecycleLog, label: String) {
        self.log = log
        self.label = label
    }

    func sessionDidEnd() {
        log.record(label)
    }
}

@MainActor
final class SpyLifecycleHost: SessionLifecycleHost {
    private let log: LifecycleLog
    let durationMS: Int?
    let finalizeResult: Bool
    private(set) var teardownEndedAt: ContinuousClock.Instant?
    private(set) var durationEndedAt: ContinuousClock.Instant?
    private(set) var finalizeDurationsMS: [Int] = []

    init(log: LifecycleLog, durationMS: Int?, finalizeResult: Bool) {
        self.log = log
        self.durationMS = durationMS
        self.finalizeResult = finalizeResult
    }

    func finishPauseSpan() {
        log.record("pause.close")
    }

    func sessionTeardownDidFinish(at endedAt: ContinuousClock.Instant) {
        teardownEndedAt = endedAt
        log.record("teardown.finish")
    }

    func activeSessionDurationMS(to endedAt: ContinuousClock.Instant) -> Int? {
        durationEndedAt = endedAt
        log.record("duration")
        return durationMS
    }

    @discardableResult func finalizeLiveSession(durationMS: Int) -> Bool {
        finalizeDurationsMS.append(durationMS)
        log.record("finalize")
        return finalizeResult
    }

    func postArchivedRecentToast() {
        log.record("toast")
    }
}
