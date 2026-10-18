import Foundation
@testable import Mimidasu
import Testing

/// Tests `ToastCenter`: post/dedup-by-key semantics (replace in place +
/// auto-dismiss timer reset), the injectable scheduler driving the 3 s
/// auto-dismiss (yellow cards only), the ~3-card stack cap (oldest dropped),
/// and dismissal/clearing.
///
/// The manual scheduler records every scheduled firing with a cancellable
/// token; tests fire pending timers deterministically instead of sleeping.
@MainActor
@Suite("ToastCenter")
struct ToastCenterTests {

    // MARK: - Fixtures

    private func makeSUT(scheduler: ManualScheduler) -> ToastCenter {
        ToastCenter(scheduler: { delay, fire in scheduler.schedule(delay, fire) })
    }

    // MARK: - Post

    @Test("posting stacks newest first")
    func postStacksNewestFirst() {
        let center = makeSUT(scheduler: ManualScheduler())

        center.post(key: "a", style: .yellowAuto, title: "A", body: "first")
        center.post(key: "b", style: .yellowAuto, title: "B", body: "second")

        #expect(center.toasts.map(\.key) == ["b", "a"])
    }

    @Test("reposting the same key replaces the card in place")
    func repostReplacesInPlace() {
        let center = makeSUT(scheduler: ManualScheduler())

        center.post(key: "a", style: .yellowAuto, title: "A", body: "first")
        center.post(key: "b", style: .yellowAuto, title: "B", body: "second")
        center.post(key: "a", style: .yellowAuto, title: "A", body: "updated")

        #expect(center.toasts.map(\.key) == ["b", "a"], "the replaced card keeps its position")
        #expect(center.toasts.last?.body == "updated")
    }

    @Test("reposting carries an action through the replacement")
    func repostCarriesAction() {
        let center = makeSUT(scheduler: ManualScheduler())

        center.post(key: "a", style: .redPersistent, title: "A", body: "first")
        center.post(
            key: "a", style: .redPersistent, title: "A", body: "updated",
            action: .init(label: "Retry") {}
        )

        #expect(center.toasts.count == 1)
        #expect(center.toasts[0].action?.label == "Retry")
    }

    /// The replaced card keeps its `id` so SwiftUI updates the existing card
    /// in place instead of playing a remove+insert transition (new id would
    /// read as a different card to the stack's `ForEach`).
    @Test("reposting preserves the card's identity")
    func repostPreservesIdentity() {
        let center = makeSUT(scheduler: ManualScheduler())

        center.post(key: "a", style: .yellowAuto, title: "A", body: "first")
        let originalID = center.toasts[0].id

        center.post(key: "a", style: .yellowAuto, title: "A", body: "updated")
        #expect(center.toasts[0].id == originalID, "the replacement reuses the card's id")

        center.dismiss(key: "a")
        center.post(key: "a", style: .yellowAuto, title: "A", body: "fresh")
        #expect(center.toasts[0].id != originalID, "a fresh post after dismissal gets a new id")
    }

    // MARK: - Auto-dismiss

    @Test("a yellowAuto toast schedules its 3 s auto-dismiss and fires it")
    func yellowAutoAutoDismisses() {
        let spy = ManualScheduler()
        let center = makeSUT(scheduler: spy)

        center.post(key: "a", style: .yellowAuto, title: "A", body: "transient")

        #expect(spy.pendingCount == 1)
        #expect(spy.delays == [.seconds(3)])

        spy.firePending()

        #expect(center.toasts.isEmpty, "the timer dismissed the card")
    }

    @Test("persistent styles never schedule an auto-dismiss")
    func persistentStylesNeverAutoDismiss() {
        let spy = ManualScheduler()
        let center = makeSUT(scheduler: spy)

        center.post(key: "p", style: .yellowPersistent, title: "P", body: "stays")
        center.post(key: "r", style: .redPersistent, title: "R", body: "stays")

        #expect(spy.pendingCount == 0, "no timer was scheduled")

        spy.firePending()

        #expect(center.toasts.count == 2, "both cards survive")
    }

    @Test("a replace resets the timer: the old firing is cancelled")
    func replaceResetsTimer() {
        let spy = ManualScheduler()
        let center = makeSUT(scheduler: spy)

        center.post(key: "a", style: .yellowAuto, title: "A", body: "first")
        center.post(key: "a", style: .yellowAuto, title: "A", body: "second")

        #expect(spy.pendingCount == 1, "the stale timer was cancelled, one live firing remains")

        spy.firePending()

        #expect(center.toasts.isEmpty, "the replacement's timer dismissed it exactly once")
    }

    @Test("the auto-dismiss delay is injectable")
    func delayIsInjectable() {
        let spy = ManualScheduler()
        let center = ToastCenter(
            autoDismissAfter: .seconds(7),
            scheduler: { delay, fire in spy.schedule(delay, fire) }
        )

        center.post(key: "a", style: .yellowAuto, title: "A", body: "quick")

        #expect(spy.delays == [.seconds(7)], "the injected delay, not the default, reached the scheduler")
    }

    // MARK: - Info style

    @Test("an info card with progress has no auto-dismiss timer")
    func infoWithProgressHasNoTimer() {
        let spy = ManualScheduler()
        let center = makeSUT(scheduler: spy)

        center.post(
            key: "job", style: .info, title: "Translating…", body: "1/3 sentences",
            progress: ToastCenter.ToastProgress(done: 1, total: 3)
        )

        #expect(spy.pendingCount == 0, "progress keeps the card up until the run ends")

        spy.firePending()

        #expect(center.toasts.count == 1, "the card survives")
    }

    @Test("an info summary with neither progress nor action auto-dismisses")
    func infoSummaryAutoDismisses() {
        let spy = ManualScheduler()
        let center = makeSUT(scheduler: spy)

        center.post(key: "job", style: .info, title: "Finished", body: "Translated 3 sentences")

        #expect(spy.delays == [.seconds(3)])

        spy.firePending()

        #expect(center.toasts.isEmpty)
    }

    @Test("an info card with an action but no progress has no auto-dismiss timer")
    func infoWithActionHasNoTimer() {
        let spy = ManualScheduler()
        let center = makeSUT(scheduler: spy)

        center.post(
            key: "job", style: .info, title: "Finished", body: "2 failed",
            action: .init(label: "Retry failed sentences") {}
        )

        #expect(spy.pendingCount == 0, "an action keeps the card up until it is taken")

        spy.firePending()

        #expect(center.toasts.count == 1)
    }

    @Test(
        "defaultIsClosable follows the style and the payload",
        arguments: [
            (ToastCenter.Style.yellowAuto, ToastCenter.ToastProgress?.none, true),
            (ToastCenter.Style.yellowPersistent, ToastCenter.ToastProgress?.none, false),
            (ToastCenter.Style.redPersistent, ToastCenter.ToastProgress?.none, false),
            (ToastCenter.Style.info, ToastCenter.ToastProgress(done: 1, total: 3), false),
            (ToastCenter.Style.info, ToastCenter.ToastProgress?.none, true)
        ]
    )
    func defaultIsClosableByStyleAndPayload(
        style: ToastCenter.Style, progress: ToastCenter.ToastProgress?, expected: Bool
    ) {
        let closable = ToastCenter.defaultIsClosable(style: style, progress: progress)

        #expect(closable == expected)
    }

    @Test("an explicit isClosable argument overrides the style default")
    func explicitIsClosableOverrides() {
        let center = makeSUT(scheduler: ManualScheduler())

        center.post(key: "a", style: .yellowAuto, title: "A", body: "b", isClosable: false)
        center.post(
            key: "i", style: .info, title: "I", body: "b",
            progress: ToastCenter.ToastProgress(done: 0, total: 2), isClosable: true
        )

        let auto = center.toasts.first(where: { toast in toast.key == "a" })
        let info = center.toasts.first(where: { toast in toast.key == "i" })
        #expect(auto?.isClosable == false, "the transient default is turned off")
        #expect(info?.isClosable == true, "the progress default is turned on")
    }

    @Test("reposting with changed progress replaces the card in place")
    func repostWithChangedProgressReplacesInPlace() {
        let center = makeSUT(scheduler: ManualScheduler())

        center.post(
            key: "job", style: .info, title: "Translating…", body: "0/3 sentences",
            progress: ToastCenter.ToastProgress(done: 0, total: 3)
        )
        let originalID = center.toasts[0].id

        center.post(
            key: "job", style: .info, title: "Translating…", body: "2/3 sentences",
            progress: ToastCenter.ToastProgress(done: 2, total: 3)
        )

        #expect(center.toasts.count == 1)
        #expect(center.toasts[0].id == originalID, "the progress update keeps the card's identity")
        #expect(center.toasts[0].progress == ToastCenter.ToastProgress(done: 2, total: 3))
        #expect(center.toasts[0].body == "2/3 sentences")
    }

    @Test("a progress re-post retires the summary's pending auto-dismiss")
    func progressReplacesSummaryAndCancelsTimer() {
        let spy = ManualScheduler()
        let center = makeSUT(scheduler: spy)

        center.post(key: "job", style: .info, title: "Finished", body: "Translated 3 sentences")
        #expect(spy.pendingCount == 1, "the summary armed its own dismissal")

        center.post(
            key: "job", style: .info, title: "Translating…", body: "0/3 sentences",
            progress: ToastCenter.ToastProgress(done: 0, total: 3)
        )

        #expect(spy.pendingCount == 0, "the summary's timer was cancelled")
        #expect(center.toasts.count == 1, "the progress card replaced the summary in place")

        spy.firePending()

        #expect(center.toasts.count == 1, "no stale firing dismissed the card")
    }

    @Test("the info style's own auto-dismiss flag stays conservative")
    func infoStyleFlagStaysConservative() {
        let center = makeSUT(scheduler: ManualScheduler())
        center.post(key: "summary", style: .info, title: "Finished", body: "Translated 3 sentences")

        #expect(ToastCenter.Style.info.autoDismisses == false)
        #expect(center.toasts[0].autoDismisses, "the toast-level decision follows the payload")
    }

    // MARK: - Cap

    @Test("posting beyond the cap drops the oldest card")
    func capDropsOldest() {
        let spy = ManualScheduler()
        let center = makeSUT(scheduler: spy)

        for key in ["a", "b", "c", "d"] {
            center.post(key: key, style: .yellowAuto, title: key, body: key)
        }

        #expect(center.toasts.map(\.key) == ["d", "c", "b"], "the oldest (a) was dropped")
        #expect(spy.pendingCount == 3, "the dropped card's timer was cancelled too")
    }

    // MARK: - dismiss / clearAll

    @Test("dismiss removes the card with the key and cancels its timer")
    func dismissRemovesAndCancels() {
        let spy = ManualScheduler()
        let center = makeSUT(scheduler: spy)

        center.post(key: "a", style: .yellowAuto, title: "A", body: "transient")
        center.dismiss(key: "a")

        #expect(center.toasts.isEmpty)
        #expect(spy.pendingCount == 0, "the timer was cancelled")

        spy.firePending()

        #expect(center.toasts.isEmpty)
    }

    @Test("dismiss with an unknown key is a no-op")
    func dismissUnknownKeyIsNoOp() {
        let center = makeSUT(scheduler: ManualScheduler())

        center.post(key: "a", style: .yellowAuto, title: "A", body: "stays")

        center.dismiss(key: "missing")

        #expect(center.toasts.count == 1)
    }

    @Test("clearAll empties the stack and cancels every timer")
    func clearAllEmptiesAndCancels() {
        let spy = ManualScheduler()
        let center = makeSUT(scheduler: spy)

        center.post(key: "a", style: .yellowAuto, title: "A", body: "one")
        center.post(key: "b", style: .redPersistent, title: "B", body: "two")
        center.clearAll()

        #expect(center.toasts.isEmpty)
        #expect(spy.pendingCount == 0)
    }

    // MARK: - Actions

    @Test("actions compare by label, not handler identity")
    func actionsCompareByLabel() {
        let byLabel = ToastCenter.Action(label: "Retry") {}
        let sameLabel = ToastCenter.Action(label: "Retry") {}
        let other = ToastCenter.Action(label: "Dismiss") {}

        #expect(byLabel == sameLabel)
        #expect(byLabel != other)
    }
}

// MARK: - Manual scheduler fixtures

/// A scheduled firing; cancelled via the closure `schedule` returns.
private final class ManualTimerToken: @unchecked Sendable {
    let fire: @MainActor () -> Void
    var cancelled = false

    init(fire: @escaping @MainActor () -> Void) {
        self.fire = fire
    }
}

/// Deterministic toast scheduler: records every scheduled firing with a
/// cancellable token; tests fire pending dismissals instead of sleeping.
private final class ManualScheduler: @unchecked Sendable {
    private let lock = NSLock()
    private var scheduled: [ManualTimerToken] = []

    var delays: [Duration] = []

    func schedule(
        _ delay: Duration, _ fire: @escaping @MainActor () -> Void
    ) -> @Sendable () -> Void {
        let token = ManualTimerToken(fire: fire)
        lock.lock()
        scheduled.append(token)
        delays.append(delay)
        lock.unlock()
        return { [weak self] in
            guard let self else { return }
            lock.lock()
            token.cancelled = true
            lock.unlock()
        }
    }

    /// Live (uncancelled) firings, in schedule order.
    private var live: [ManualTimerToken] {
        lock.withLock { scheduled.filter { token in !token.cancelled } }
    }

    var pendingCount: Int {
        live.count
    }

    /// Fires every live dismissal and forgets the schedule. MainActor: the
    /// stored `fire` closures are, and every caller (the tests) is too.
    @MainActor
    func firePending() {
        let tokens = live
        lock.withLock { scheduled.removeAll() }
        for token in tokens {
            token.fire()
        }
    }
}
