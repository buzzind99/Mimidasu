import Foundation

@MainActor
protocol SessionLifecycleHost: AnyObject {
    func finishPauseSpan()
    func sessionTeardownDidFinish(at endedAt: ContinuousClock.Instant)
    func activeSessionDurationMS(to endedAt: ContinuousClock.Instant) -> Int?
    @discardableResult func finalizeLiveSession(durationMS: Int) -> Bool
    func postArchivedRecentToast()
}

@MainActor
protocol SessionStopping: AnyObject {
    func stop() async
}

@MainActor
protocol SessionBoundaryEnding: AnyObject {
    func sessionDidEnd()
}

@MainActor
struct SessionLifecycle {
    let controller: any SessionStopping
    let translationSession: any SessionBoundaryEnding
    let retranslate: any SessionBoundaryEnding

    /// The one ordered end sequence. Steps must not be reordered: the pause
    /// span folds before the recording row is finalized; the controller
    /// drains before either coordinator retires its boundary; the archive
    /// finalize runs after the chrome clear so its toast survives.
    func end(host: any SessionLifecycleHost) async {
        host.finishPauseSpan()
        await controller.stop()
        translationSession.sessionDidEnd()
        retranslate.sessionDidEnd()
        let endedAt = ContinuousClock.now
        host.sessionTeardownDidFinish(at: endedAt)
        if let durationMS = host.activeSessionDurationMS(to: endedAt),
           host.finalizeLiveSession(durationMS: durationMS)
        {
            host.postArchivedRecentToast()
        }
    }
}

extension SessionController: SessionStopping {}
