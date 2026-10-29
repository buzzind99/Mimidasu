@testable import Mimidasu
import Testing

/// Tests the SESSION-card stats plumbing on `AppModel`: the character count
/// (Σ transcript text, translations excluded) and the session clock anchors
/// (`onSessionBegin` sets the start + clears the previous end; `stop`
/// freezes the end while the start anchor survives, so duration stops
/// counting; a capture death anchors `captureLostAt` until restart/new
/// session). The mm:ss formatting itself is view logic (`SidebarView`).
@MainActor
@Suite("AppModel session stats")
struct AppModelSessionStatsTests {

    // MARK: - Fixtures

    /// Stubbed launch check — see `AppModelTests.makeSUT`.
    private func makeSUT() async -> AppModel {
        let model = makeIdleModel(suite: "test.AppModelStats")
        await model.initialModelCheck?.value
        return model
    }

    // MARK: - Character count

    @Test("the character count sums the transcript text")
    func characterCountSumsTranscriptText() async {
        let model = await makeSUT()

        #expect(model.sessionCharacterCount == 0, "a fresh session counts nothing")

        model.sessionController.onSentence?(makeSentence(index: 0, text: "テスト"))
        model.sessionController.onSentence?(makeSentence(index: 1, text: "こんにちは"))

        #expect(model.sessionCharacterCount == 8)
    }

    // MARK: - Session clock

    /// `onSessionBegin` anchors the start and clears the previous session's
    /// end; `stop` freezes the end while the start anchor survives (duration
    /// reads endedAt − startedAt after stop).
    @Test("session begin anchors the clock, clears the previous end, and stop freezes it")
    func sessionClockAnchorsAndFreezes() async throws {
        let model = await makeSUT()
        model.phase = .running
        model.sessionController.onSessionBegin?()
        let startedAt = try #require(model.sessionStartedAt)

        model.stop()
        #expect(await pollUntil { model.phase == .idle }, "stop winds down to idle")
        #expect(model.sessionEndedAt != nil, "the end anchor is set at stop")
        #expect(model.sessionStartedAt == startedAt, "the start anchor is frozen at stop")

        model.sessionController.onSessionBegin?()

        #expect(model.sessionStartedAt != nil)
        #expect(model.sessionEndedAt == nil, "the previous session's end was cleared")
    }

    // MARK: - Capture-lost anchor

    /// A mid-session capture death anchors `captureLostAt` so the SESSION
    /// card freezes the duration during the outage (alongside the
    /// `.sourceLost` phase); a successful restart clears it and duration
    /// resumes from the surviving session clock.
    @Test("a capture error anchors captureLostAt until the restart clears it")
    func captureLostAnchorsAndRestartClears() async {
        let model = await makeSUT()
        model.phase = .running
        model.sessionController.onSessionBegin?()

        model.sessionController.onCaptureError?("stream died")

        #expect(model.phase == .sourceLost)
        #expect(model.captureLostAt != nil)
        #expect(model.sessionEndedAt == nil, "the session itself is not torn down")

        model.restartCapture()
        #expect(await pollUntil { model.phase == .running }, "the restart recovers")

        #expect(model.captureLostAt == nil, "the successful restart clears the anchor")
    }

    @Test("a new session clears the previous captureLostAt")
    func sessionBeginClearsCaptureLostAt() async {
        let model = await makeSUT()
        model.phase = .running
        model.sessionController.onCaptureError?("stream died")
        #expect(model.captureLostAt != nil)

        model.sessionController.onSessionBegin?()

        #expect(model.captureLostAt == nil)
    }
}
