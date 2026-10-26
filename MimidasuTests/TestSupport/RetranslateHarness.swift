import Foundation
@testable import Mimidasu
import Testing

/// Shared harness for the re-translate suites: an idle model over isolated
/// settings, and a queue worker holding an echo engine so a stop's
/// translation-tail drain stays instant.
@MainActor
struct RetranslateHarness {
    let suite: String

    func makeModel(
        archive: ArchiveStore? = nil,
        translationTransport: HTTPTranslationTransport? = nil
    ) async -> AppModel {
        let model = makeIdleModel(
            suite: suite, archive: archive, translationTransport: translationTransport
        )
        await model.initialModelCheck?.value
        return model
    }

    /// Attaches a queue worker the way `activateTranslation` does. Besides
    /// serving initial deliveries it keeps a stop's translation-tail drain
    /// instant: an unserved backlog spins the drain's whole bounded timeout.
    @discardableResult
    func attachWorker(
        _ model: AppModel, engine: any TranslationEngine = QueueEchoEngine()
    ) async -> Task<Void, Never> {
        let worker = Task { await model.translationQueue.run(with: engine) }
        #expect(
            await pollUntil(timeout: 5) { model.translationQueue.hasWorker },
            "the queue worker must be attached"
        )
        return worker
    }
}
