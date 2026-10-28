import Foundation

extension AppModel {
    var sessionLifecycle: SessionLifecycle {
        SessionLifecycle(
            controller: sessionController,
            translationSession: translationSession,
            retranslate: retranslate
        )
    }
}

extension TranslationSessionCoordinator: SessionBoundaryEnding {}
extension RetranslateCoordinator: SessionBoundaryEnding {}

extension AppModel: SessionLifecycleHost {
    func sessionTeardownDidFinish(at endedAt: ContinuousClock.Instant) {
        sessionEndedAt = endedAt
        toasts.clearAll()
        notices.dismiss()
        reducePhase(.stopCompleted)
    }
}
