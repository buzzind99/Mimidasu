import Foundation
@testable import Mimidasu
import Testing

/// Tests `NoticeCenter`: posting shows the message, the injectable scheduler
/// drives the 2 s auto-dismiss, re-posting resets the timer, and
/// dismissal/clearing.
///
/// The manual scheduler records every scheduled firing with a cancellable
/// token; tests fire pending timers deterministically instead of sleeping.
@MainActor
@Suite("NoticeCenter")
struct NoticeCenterTests {

    // MARK: - Fixtures

    private func makeSUT(scheduler: ManualScheduler) -> NoticeCenter {
        NoticeCenter(scheduler: { delay, fire in scheduler.schedule(delay, fire) })
    }

    // MARK: - Post

    @Test("posting shows the message")
    func postShowsMessage() {
        let center = makeSUT(scheduler: ManualScheduler())

        center.post(message: "Text copied")

        #expect(center.message == "Text copied")
    }

    // MARK: - Auto-dismiss

    @Test("a post schedules its 2 s auto-dismiss and fires it")
    func postAutoDismisses() {
        let spy = ManualScheduler()
        let center = makeSUT(scheduler: spy)

        center.post(message: "Text copied")

        #expect(spy.pendingCount == 1)
        #expect(spy.delays == [.seconds(2)])

        spy.firePending()

        #expect(center.message == nil, "the timer dismissed the notice")
    }

    @Test("a repost resets the timer: the old firing is cancelled")
    func repostResetsTimer() {
        let spy = ManualScheduler()
        let center = makeSUT(scheduler: spy)

        center.post(message: "first")
        center.post(message: "second")

        #expect(spy.pendingCount == 1, "the stale timer was cancelled, one live firing remains")

        spy.firePending()

        #expect(center.message == nil, "the replacement's timer dismissed it exactly once")
    }

    // MARK: - dismiss

    @Test("dismiss clears the message and cancels the timer")
    func dismissClearsAndCancels() {
        let spy = ManualScheduler()
        let center = makeSUT(scheduler: spy)

        center.post(message: "Text copied")
        center.dismiss()

        #expect(center.message == nil)
        #expect(spy.pendingCount == 0, "the timer was cancelled")

        spy.firePending()

        #expect(center.message == nil)
    }

    @Test("dismiss without a visible notice is a no-op")
    func dismissWithoutNoticeIsNoOp() {
        let spy = ManualScheduler()
        let center = makeSUT(scheduler: spy)

        center.dismiss()

        #expect(center.message == nil)
        #expect(spy.pendingCount == 0)
    }
}
