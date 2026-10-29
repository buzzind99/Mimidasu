import Foundation
@testable import Mimidasu
import Testing

/// Tests the coordinator's live hand-over seam — the one entry point for
/// SwiftUI's `.translationTask`: an Apple-stamped authority attaches the
/// handed-over engine and publishes worker truth through the runtime
/// snapshot, while a hand-over whose config the authority no longer owns
/// (an external engine is attached) is refused without side effects.
@MainActor
@Suite("TranslationSessionCoordinator hand-over")
struct TranslationSessionHandOverTests {

    /// The cancel-await pattern the worker tests rely on: cancelling the
    /// hand-over task ends the queue run, whose `defer` releases the engine
    /// and publishes `workerAttached == false` before the task's value is
    /// awaiting us.
    @Test("an Apple hand-over attaches the engine and publishes worker truth")
    func appleHandOverAttachesWorker() async {
        let coordinator = makeCoordinator()
        let engine = QueueEchoEngine()

        let handOver = Task { await coordinator.sessionHandOver(engine) }

        #expect(
            await pollUntil {
                coordinator.workerAttached && coordinator.queue.hasWorker
            },
            "the hand-over attaches the engine and publishes the snapshot"
        )

        handOver.cancel()
        await handOver.value

        #expect(
            await pollUntil { !coordinator.workerAttached },
            "the cancelled run releases the worker and clears the snapshot"
        )
    }

    /// A stale Apple hand-over must not bump the queue's generation and
    /// steal it from the attached external engine — the guard returns before
    /// `queue.run`, so the queue, the snapshot's worker flag, and the status
    /// all stay exactly as they were.
    @Test("a hand-over is refused while an external engine owns the queue")
    func handOverRefusedWhileExternalAttached() async {
        let coordinator = makeCoordinator()
        coordinator.activeTranslationEngine = .external
        let statusBefore = coordinator.runtime.status

        await coordinator.sessionHandOver(QueueEchoEngine())

        #expect(!coordinator.queue.hasWorker, "the refused hand-over never runs the queue")
        #expect(!coordinator.workerAttached, "the refused hand-over attaches no worker")
        #expect(
            coordinator.runtime.status == statusBefore,
            "the refused hand-over leaves the status untouched"
        )
    }

    // MARK: - Fixtures

    /// Fully real coordinator over injected dependencies: isolated settings,
    /// a live queue (so `installQueueHandlers` wires the worker publication
    /// under test), no transport (unused on this path), and a tier
    /// availability that never reports high fidelity.
    private func makeCoordinator() -> TranslationSessionCoordinator {
        let defaults = UserDefaults(
            suiteName: "test.TranslationSessionHandOver.\(UUID().uuidString)"
        )!
        let settings = TranslationSettings(
            defaults: defaults, keys: InMemoryKeyStore()
        )
        return TranslationSessionCoordinator(
            queue: TranslationQueue(),
            settings: settings,
            transport: nil,
            tierAvailability: AppleTierAvailability(check: { _ in false })
        )
    }
}
