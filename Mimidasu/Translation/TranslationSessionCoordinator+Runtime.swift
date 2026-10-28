extension TranslationSessionCoordinator {
    /// Owns the queue's three callbacks — called once, at the end of `init`,
    /// so worker truth is published at the source instead of mirrored
    /// through `AppModel`. `host` is assigned later in `AppModel.init`; it is
    /// weak and nil-safe, and no run can land before init completes.
    func installQueueHandlers() {
        queue.setHandlers(
            result: { [weak self] index, translation in
                _ = self?.host?.applyTranslation(index: index, translation: translation)
            },
            status: { [weak self] status in
                self?.handleStatus(status)
            },
            workerChanged: { [weak self] attached in
                self?.workerAttached = attached
            }
        )
    }

    /// The one entry point for SwiftUI's live `.translationTask` hand-over.
    /// Refuses a hand-over whose config the authority no longer owns (D5):
    /// a stale Apple session must not bump the queue's generation and steal
    /// it from the attached external engine. Legitimate arming sites stamp
    /// `.apple` before arming the config (K2), so they pass. Awaiting (not
    /// spawning) keeps the `TranslationSession` alive for the run's life and
    /// keeps Apple runs parked across a stop (K1).
    func sessionHandOver(_ engine: any TranslationEngine) async {
        guard runtime.engine == .apple else { return }
        await queue.run(with: engine)
    }
}
