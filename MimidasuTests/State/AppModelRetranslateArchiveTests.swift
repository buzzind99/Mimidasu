import Foundation
@testable import Mimidasu
import Synchronization
import Testing

/// Tests the re-translate lane's archive mode: the widened gate (no live
/// session, an open archive), the route switch (`.session` maps to the
/// Apple-fast dedicated session; externals build over the archive's stored
/// target), the result landing back into the store, the cache-seeding skip,
/// and the open/close epoch retirement.
@MainActor
@Suite("AppModel re-translate archive")
struct AppModelRetranslateArchiveTests {

    private let resultTimeout: TimeInterval = 5

    // MARK: - Fixtures

    /// Echoes `FR:`-prefixed text and counts flights. The prefix names the
    /// archive fixture's stored target ("fr"), so a landed row proves the
    /// retry ran and stamped through the archive route.
    private final class ArchiveEchoEngine: TranslationEngine, @unchecked Sendable {
        let preferredBatchSize = 16
        var onRetry: (@Sendable (RetryProgress) -> Void)?

        private let state = Mutex((count: 0, batches: [[String]]()))

        var callCount: Int {
            state.withLock { pair in pair.count }
        }

        var recordedBatches: [[String]] {
            state.withLock { pair in pair.batches }
        }

        func translate(_ texts: [String]) async throws -> [String] {
            state.withLock { pair in
                pair.count += 1
                pair.batches.append(texts)
            }
            return texts.map { text in "FR:\(text)" }
        }
    }

    /// Parks inside `translate` until `open()` — holds a lane flight mid-air.
    private final class GatedArchiveEngine: TranslationEngine, @unchecked Sendable {
        let preferredBatchSize = 16
        var onRetry: (@Sendable (RetryProgress) -> Void)?

        private let state = Mutex((gate: DispatchSemaphore(value: 0), count: 0))

        var callCount: Int {
            state.withLock { pair in pair.count }
        }

        func open() {
            state.withLock { pair in pair.gate }.signal()
        }

        func translate(_ texts: [String]) async throws -> [String] {
            state.withLock { pair in pair.count += 1 }
            let gate = state.withLock { pair in pair.gate }
            await withCheckedContinuation { continuation in
                DispatchQueue.global().async {
                    _ = gate.wait(timeout: .now() + 10)
                    continuation.resume()
                }
            }
            return texts.map { text in "FR:\(text)" }
        }
    }

    private struct SUT {
        let model: AppModel
        let store: ArchiveStore
        let id: Int64
    }

    /// Seed metadata stored with the archive fixture: target `fr`.
    private func metadata() -> SessionMetadata {
        SessionMetadata(
            startedAt: Date(timeIntervalSince1970: 1_000_000),
            sourceLang: "ja",
            targetLang: "fr",
            model: "test-model",
            chunkMS: 160
        )
    }

    private func sentence(_ index: Int, text: String) -> Sentence {
        Sentence(index: index, startS: Double(index), endS: Double(index) + 1, lang: "ja", text: text)
    }

    /// A model with a finalized two-sentence archive (target `fr`) open in
    /// the pane; the settings target stays `en`, so every stamped `fr`
    /// proves the archive route's target reached the flight.
    private func makeSUT() async -> SUT {
        let store = isolatedArchive()
        let id = store.append(
            sentence: sentence(0, text: "こんにちは"), sessionID: nil, metadata: metadata()
        )
        _ = store.append(
            sentence: sentence(1, text: "さようなら"), sessionID: id, metadata: metadata()
        )
        let finalized = id ?? -1
        store.finalize(session: finalized, durationMS: 60000, saved: false)

        let model = AppModel(
            translationSettings: isolatedTranslationSettings(suite: "test.AppModelRetranslateArchive"),
            asrModelSettings: isolatedASRModelSettings(suite: "test.AppModelRetranslateArchive"),
            favorites: isolatedFavorites(),
            archive: store,
            highFidelityProbe: { _ in false },
            initialModelResolve: { _ in nil }
        )
        await model.initialModelCheck?.value
        model.openArchiveSession(id: finalized)
        return SUT(model: model, store: store, id: finalized)
    }

    private func sentence(_ sut: SUT, at index: Int) -> Sentence {
        sut.model.entries.first { entry in entry.sentence.index == index }!.sentence
    }

    // MARK: - Gate

    @Test("a retry with no live session and no open archive is a no-op")
    func retryWithoutGateIsNoop() async {
        let sut = await makeSUT()
        let target = sentence(sut, at: 0)
        sut.model.closeArchive()

        sut.model.retranslateSentence(target)

        #expect(sut.model.pendingRetranslations.isEmpty)
        #expect(sut.store.load(id: sut.id)?.entries.first?.translations.isEmpty == true)
    }

    @Test("opening an archive retires every pending marker")
    func openRetiresMarkers() async {
        let sut = await makeSUT()
        let other = appendArchive(to: sut.store)
        sut.model.pendingRetranslations = [0, 1]
        sut.model.lanePendingRetranslations = [0]

        sut.model.openArchiveSession(id: other)

        #expect(sut.model.pendingRetranslations.isEmpty)
        #expect(sut.model.lanePendingRetranslations.isEmpty)
    }

    // MARK: - Apple route

    @Test("the .session selection maps to the Apple-fast dedicated session and writes back to the store")
    func sessionSelectionMapsToAppleFast() async {
        let sut = await makeSUT()
        let target = sentence(sut, at: 0)

        sut.model.retranslateSentence(target)
        // Unarmed at click time: the lane armed the fast config and waits;
        // the host hand-over serves the flight.
        #expect(sut.model.retranslateConfig != nil, "the archive route arms its own session")
        sut.model.retranslateSessionArrived(ArchiveEchoEngine())

        #expect(
            await pollUntil(timeout: resultTimeout) {
                sut.model.entries.first?.translations
                    == [SentenceTranslation(lang: "fr", text: "FR:こんにちは", engine: .appleFast)]
            },
            "the fast-model result lands stamped with the archive target"
        )
        #expect(sut.model.pendingRetranslations.isEmpty)
        #expect(sut.model.lanePendingRetranslations.isEmpty)
        #expect(
            !sut.model.toasts.toasts.contains { toast in toast.key == ToastKey.retranslate },
            "the queue path was never consulted"
        )

        // Durable: the store is the home of the result.
        let stored = sut.store.load(id: sut.id)?.entries.first?.translations
        #expect(stored == [SentenceTranslation(lang: "fr", text: "FR:こんにちは", engine: .appleFast)])

        // And a reopen reads it back into the pane.
        sut.model.closeArchive()
        sut.model.openArchiveSession(id: sut.id)
        #expect(
            sut.model.entries.first?.translations
                == [SentenceTranslation(lang: "fr", text: "FR:こんにちは", engine: .appleFast)]
        )
    }

    @Test("a second click while the retry is in flight is a no-op")
    func doubleClickIsIdempotent() async {
        let sut = await makeSUT()
        let target = sentence(sut, at: 0)
        let engine = GatedArchiveEngine()

        sut.model.retranslateSentence(target)
        // The click arms the archive-target config; the hand-over then
        // serves the lane's wait.
        sut.model.retranslateSessionArrived(engine)
        #expect(await pollUntil(timeout: resultTimeout) { engine.callCount == 1 }, "the flight starts")
        sut.model.retranslateSentence(target)

        #expect(sut.model.pendingRetranslations == [0], "the marker holds a second click back")
        engine.open()
        #expect(
            await pollUntil(timeout: resultTimeout) {
                sut.model.entries.first?.translations.first?.engine == .appleFast
            }
        )
        #expect(engine.callCount == 1, "exactly one flight ran")
    }

    @Test("closing the archive mid-flight drops the landing without writing back")
    func closeDuringFlightDropsResult() async {
        let sut = await makeSUT()
        let target = sentence(sut, at: 0)
        let engine = GatedArchiveEngine()

        sut.model.retranslateSentence(target)
        sut.model.retranslateSessionArrived(engine)
        #expect(await pollUntil(timeout: resultTimeout) { engine.callCount == 1 }, "the flight starts")

        sut.model.closeArchive()
        engine.open()

        // The flight resolves and its guards retire it; nothing lands and
        // the store never sees the orphan.
        #expect(await pollUntil(timeout: resultTimeout) { sut.model.pendingRetranslations.isEmpty })
        #expect(sut.store.load(id: sut.id)?.entries.first?.translations.isEmpty == true)
        #expect(sut.model.entries.isEmpty, "the pane emptied with the close")
    }

    // MARK: - External route

    @Test("an external selection flies the injected engine and stamps the archive target")
    func externalSelectionStampsArchiveTarget() async {
        let sut = await makeSUT()
        let engine = ArchiveEchoEngine()
        sut.model.retranslateEngineFactory = { provider, _ in
            provider == .google ? engine : nil
        }
        sut.model.translationSettings.selectRetranslate(.google)
        let target = sentence(sut, at: 1)

        sut.model.retranslateSentence(target)

        #expect(
            await pollUntil(timeout: resultTimeout) {
                sut.model.entries.last?.translations
                    == [SentenceTranslation(lang: "fr", text: "FR:さようなら", engine: .google)]
            },
            "the external result lands stamped with the archive target"
        )
        #expect(engine.recordedBatches == [["さようなら"]])
        #expect(sut.model.retranslateConfig == nil, "no dedicated session is armed for an external")
    }

    @Test("an external selection with no usable engine reports unavailable and keeps the row")
    func externalSelectionWithoutEngineReports() async {
        let sut = await makeSUT()
        sut.model.retranslateEngineFactory = { _, _ in nil }
        sut.model.translationSettings.selectRetranslate(.google)
        let target = sentence(sut, at: 0)

        sut.model.retranslateSentence(target)

        #expect(sut.model.pendingRetranslations.isEmpty)
        #expect(
            sut.model.toasts.toasts.contains { toast in toast.key == ToastKey.retranslate },
            "the key-less provider reports unavailable"
        )
        #expect(sut.store.load(id: sut.id)?.entries.first?.translations.isEmpty == true)
    }

    // MARK: - Identity and arming

    @Test("in archive mode every Apple selection is an alternate")
    func archiveAlternateIdentity() async {
        let sut = await makeSUT()

        // Default selection is `.session`, and there is no live session to
        // serve it — the retry button must still enable.
        #expect(sut.model.translationSettings.retranslateEngine == .session)
        #expect(sut.model.alternateRetranslateEngineActive)

        // A key-less external reports not-an-alternate (the lane would only
        // toast); the settings-target engine builder agrees there is no key.
        sut.model.translationSettings.selectRetranslate(.google)
        #expect(!sut.model.alternateRetranslateEngineActive)
        #expect(sut.model.translationSession.makeExternalEngine(for: .deepl) == nil)

        // The closed pane turns the identity back to live semantics.
        sut.model.closeArchive()
        #expect(!sut.model.alternateRetranslateEngineActive)
    }

    @Test("the high-fidelity selection arms its own dedicated session in archive mode")
    func hifiSelectionArmsHifiSession() async throws {
        guard #available(macOS 26.4, *) else {
            try Test.cancel("the high-fidelity lane requires macOS 26.4")
        }
        let sut = await makeSUT()
        sut.model.translationSettings.selectRetranslate(.appleHighFidelity)

        sut.model.retranslateSentence(sentence(sut, at: 0))

        #expect(sut.model.retranslateHifiConfig != nil, "the hifi lane armed, not the fast one")
        #expect(sut.model.retranslateConfig == nil)
        #expect(sut.model.retranslate.retranslateHifiConfigTarget == "fr")
    }

    @Test("a second archive with a different stored target rebuilds the armed config")
    func targetMismatchRebuildsConfig() async {
        let sut = await makeSUT()
        // First archive (fr) arms the config; the click needs no hand-over
        // for the arming to happen.
        sut.model.retranslateSentence(sentence(sut, at: 0))
        #expect(sut.model.retranslate.retranslateConfigTarget == "fr")

        // A second archive stored German replaces the pane.
        let secondID = sut.store.append(
            sentence: sentence(0, text: "Guten Tag"), sessionID: nil,
            metadata: SessionMetadata(
                startedAt: Date(timeIntervalSince1970: 2_000_000),
                sourceLang: "ja", targetLang: "de", model: "test-model", chunkMS: 160
            )
        )
        sut.store.finalize(session: secondID ?? -1, durationMS: 10000, saved: false)
        sut.model.closeArchive()
        sut.model.openArchiveSession(id: secondID ?? -1)

        sut.model.retranslateSentence(sentence(sut, at: 0))

        #expect(
            sut.model.retranslate.retranslateConfigTarget == "de",
            "the armed config was rebuilt for the new archive's target"
        )
    }

    @Test("an archive row retry degrades high fidelity only for the probed pair")
    func rowRetryDegradesHifiForProbedTarget() async throws {
        guard #available(macOS 26.4, *) else {
            try Test.cancel("the high-fidelity arm requires macOS 26.4")
        }
        let sut = await makeSUT()
        sut.model.translationSettings.selectRetranslate(.appleHighFidelity)
        // The probe landed not-installed for the archive's own pair — the
        // row path degrades with the same target-scoped rule as the bulk run.
        sut.model.appleHighFidelityProbe = (false, "fr")

        sut.model.retranslateSentence(sentence(sut, at: 0))

        #expect(sut.model.retranslateConfig != nil, "the degraded row retry arms the fast session")
        #expect(sut.model.retranslateHifiConfig == nil, "the high-fidelity session is never armed")
        #expect(sut.model.retranslate.retranslateConfigTarget == "fr")
    }

    @Test("a row retry that lands after a viewing-language switch keeps the click-time target")
    func rowRetryKeepsClickTimeTarget() async {
        let sut = await makeSUT()
        let gate = PermitGate()
        let engine = ScriptedArchiveEngine(gate: gate)
        // The archive route arms its own dedicated session; seed it with the
        // gated engine so both chained flights park on the same double.
        sut.model.retranslate.armRetranslateSessionIfNeeded(for: .appleFast, target: "fr")
        sut.model.retranslateSessionArrived(engine)

        let first = sentence(sut, at: 0)
        let second = sentence(sut, at: 1)
        sut.model.retranslateSentence(first)
        #expect(
            await pollUntil(timeout: resultTimeout) { engine.recordedBatches.count == 1 },
            "the first flight parks in the engine"
        )

        sut.model.retranslateSentence(second)
        #expect(sut.model.pendingRetranslations == [0, 1], "the second click chains behind the first")

        // A viewing-language switch during the arm/flight window must not
        // retarget the airborne work: both flights were clicked for `fr`.
        sut.model.selectArchiveViewingLanguage("de")

        gate.release()
        gate.release()
        #expect(
            await pollUntil(timeout: resultTimeout) {
                let entries = sut.store.load(id: sut.id)?.entries ?? []
                return entries.count == 2 && entries.allSatisfy { entry in
                    entry.translation(for: "fr") != nil
                }
            },
            "both flights land under the click-time language"
        )
        #expect(
            sut.store.load(id: sut.id)?.entries.map { entry in entry.translations.first?.lang } == ["fr", "fr"],
            "both stored results name the click-time language, not the switched viewing language"
        )
        #expect(
            sut.model.entries.compactMap { entry in entry.translation(for: "de") }.isEmpty,
            "no result is stored under the switched language"
        )
        #expect(
            sut.model.entries.compactMap { entry in entry.translation(for: "fr")?.engine }
                == [.appleFast, .appleFast],
            "both row markers describe the click-time language's result"
        )
        #expect(
            sut.model.retranslate.retranslateConfigTarget == "fr",
            "the armed config kept the click-time target"
        )
    }
}
