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

    private let harness = RetranslateHarness(suite: "test.AppModelRetranslateArchive")
    private let resultTimeout: TimeInterval = 5

    // MARK: - Fixtures

    /// Echoes `FR:`-prefixed text and counts flights. The prefix names the
    /// archive fixture's stored target ("fr"), so a landed row proves the
    /// retry ran and stamped through the archive route.
    private final class ArchiveEchoEngine: TranslationEngine, @unchecked Sendable {
        let preferredBatchSize = 16
        var onRetry: (@Sendable (RetryProgress) -> Void)?

        private let state = Mutex((count: 0, batches: [[String]]()))

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

    /// A model with a finalized two-sentence archive (target `fr`) open in
    /// the pane; the settings target stays `en`, so every stamped `fr`
    /// proves the archive route's target reached the flight.
    private func makeSUT() async -> SUT {
        let store = isolatedArchive()
        let id = store.append(
            sentence: archiveSentence(0, text: "こんにちは"), sessionID: nil, metadata: archiveMetadata()
        )
        _ = store.append(
            sentence: archiveSentence(1, text: "さようなら"), sessionID: id, metadata: archiveMetadata()
        )
        let finalized = id ?? -1
        store.finalize(session: finalized, durationMS: 60000, saved: false)

        let model = await harness.makeModel(archive: store)
        model.openArchiveSession(id: finalized)
        return SUT(model: model, store: store, id: finalized)
    }

    /// The archive plan for the open pane's viewing language — the
    /// click-time lane target the retry button and the click path share.
    private func archivePlan(_ model: AppModel) -> RetranslatePlan {
        let target = TargetLanguage(
            code: model.archiveViewingCode ?? model.translationSettings.targetLanguage.code
        )
        return model.retranslatePlan(surface: .archive, target: target)
    }

    /// The plan routes externals by the stored key, so a lane-flight fixture
    /// that injects an engine must also store the key the click checks.
    private func saveTestKey(_ provider: TranslationProvider, on model: AppModel) {
        try? model.translationSettings.saveKey("sk-test-\(provider.rawValue)", for: provider)
    }

    // MARK: - Gate

    @Test("a retry with no live session and no open archive is a no-op")
    func retryWithoutGateIsNoop() async {
        let sut = await makeSUT()
        let target = entrySentence(in: sut.model, at: 0)
        sut.model.closeArchive()

        sut.model.retranslate.retranslateSentence(target)

        #expect(sut.model.retranslate.pendingRetranslations.isEmpty)
        #expect(sut.store.load(id: sut.id)?.entries.first?.translations.isEmpty == true)
    }

    @Test("opening an archive retires every pending marker")
    func openRetiresMarkers() async {
        let sut = await makeSUT()
        let other = appendArchive(to: sut.store)
        let gate = LaneGatedEngine()
        try? sut.model.translationSettings.saveKey("sk-test-google", for: .google)
        sut.model.translationSettings.selectRetranslate(.google)
        sut.model.retranslate.retranslateEngineFactory = { _, _ in gate }

        // Two parked archive retries own both markers; the divide is applied
        // by the boundary, not seeded by hand.
        sut.model.retranslate.retranslateSentence(entrySentence(in: sut.model, at: 0))
        sut.model.retranslate.retranslateSentence(entrySentence(in: sut.model, at: 1))
        #expect(
            await pollUntil(timeout: resultTimeout) {
                sut.model.retranslate.pendingRetranslations == [0, 1]
            },
            "both retries own their marker"
        )
        // A queue-owned cue (the index a live queue retry would own) must be
        // cleared by the same boundary, not just the lane-owned markers.
        sut.model.retranslate.markPending(2, laneOwned: false)

        sut.model.openArchiveSession(id: other)
        gate.openGate()
        _ = await sut.model.retranslate.waitForLaneChainIdle()

        #expect(sut.model.retranslate.pendingRetranslations.isEmpty)
    }

    // MARK: - Apple route

    @Test("the .session selection maps to the Apple-fast dedicated session and writes back to the store")
    func sessionSelectionMapsToAppleFast() async {
        let sut = await makeSUT()
        let target = entrySentence(in: sut.model, at: 0)

        sut.model.retranslate.retranslateSentence(target)
        // Unarmed at click time: the lane armed the fast config and waits;
        // the host hand-over serves the flight.
        #expect(sut.model.retranslate.fastSessionConfig != nil, "the archive route arms its own session")
        sut.model.retranslate.retranslateSessionArrived(.appleFast, engine: ArchiveEchoEngine())

        #expect(
            await pollUntil(timeout: resultTimeout) {
                sut.model.pane.entries.first?.translations
                    == [SentenceTranslation(lang: "fr", text: "FR:こんにちは", engine: .appleFast)]
            },
            "the fast-model result lands stamped with the archive target"
        )
        #expect(sut.model.retranslate.pendingRetranslations.isEmpty)
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
            sut.model.pane.entries.first?.translations
                == [SentenceTranslation(lang: "fr", text: "FR:こんにちは", engine: .appleFast)]
        )
    }

    @Test("a second click while the retry is in flight is a no-op")
    func doubleClickIsIdempotent() async {
        let sut = await makeSUT()
        let target = entrySentence(in: sut.model, at: 0)
        let engine = GatedArchiveEngine()

        sut.model.retranslate.retranslateSentence(target)
        // The click arms the archive-target config; the hand-over then
        // serves the lane's wait.
        sut.model.retranslate.retranslateSessionArrived(.appleFast, engine: engine)
        #expect(await pollUntil(timeout: resultTimeout) { engine.callCount == 1 }, "the flight starts")
        sut.model.retranslate.retranslateSentence(target)

        #expect(sut.model.retranslate.pendingRetranslations == [0], "the marker holds a second click back")
        engine.open()
        #expect(
            await pollUntil(timeout: resultTimeout) {
                sut.model.pane.entries.first?.translations.first?.engine == .appleFast
            }
        )
        #expect(engine.callCount == 1, "exactly one flight ran")
    }

    @Test("closing the archive mid-flight drops the landing without writing back")
    func closeDuringFlightDropsResult() async {
        let sut = await makeSUT()
        let target = entrySentence(in: sut.model, at: 0)
        let engine = GatedArchiveEngine()

        sut.model.retranslate.retranslateSentence(target)
        sut.model.retranslate.retranslateSessionArrived(.appleFast, engine: engine)
        #expect(await pollUntil(timeout: resultTimeout) { engine.callCount == 1 }, "the flight starts")

        sut.model.closeArchive()
        engine.open()

        // The flight resolves and its guards retire it; nothing lands and
        // the store never sees the orphan.
        #expect(await pollUntil(timeout: resultTimeout) { sut.model.retranslate.pendingRetranslations.isEmpty })
        #expect(sut.store.load(id: sut.id)?.entries.first?.translations.isEmpty == true)
        #expect(sut.model.pane.entries.isEmpty, "the pane emptied with the close")
    }

    // MARK: - External route

    @Test("an external selection flies the injected engine and stamps the archive target")
    func externalSelectionStampsArchiveTarget() async {
        let sut = await makeSUT()
        let engine = ArchiveEchoEngine()
        sut.model.retranslate.retranslateEngineFactory = { provider, _ in
            provider == .google ? engine : nil
        }
        sut.model.translationSettings.selectRetranslate(.google)
        saveTestKey(.google, on: sut.model)
        let target = entrySentence(in: sut.model, at: 1)

        sut.model.retranslate.retranslateSentence(target)

        #expect(
            await pollUntil(timeout: resultTimeout) {
                sut.model.pane.entries.last?.translations
                    == [SentenceTranslation(lang: "fr", text: "FR:さようなら", engine: .google)]
            },
            "the external result lands stamped with the archive target"
        )
        #expect(engine.recordedBatches == [["さようなら"]])
        #expect(sut.model.retranslate.fastSessionConfig == nil, "no dedicated session is armed for an external")
    }

    @Test("an external selection with no usable engine reports unavailable and keeps the row")
    func externalSelectionWithoutEngineReports() async {
        let sut = await makeSUT()
        // The stored key admits the route; the factory's nil is the build
        // failure that must leave the row and its backlog untouched.
        try? sut.model.translationSettings.saveKey("sk-test-google", for: .google)
        sut.model.retranslate.retranslateEngineFactory = { _, _ in nil }
        sut.model.translationSettings.selectRetranslate(.google)
        let target = entrySentence(in: sut.model, at: 0)

        sut.model.retranslate.retranslateSentence(target)

        #expect(sut.model.retranslate.pendingRetranslations.isEmpty)
        #expect(
            sut.model.toasts.toasts.contains { toast in toast.key == ToastKey.retranslate },
            "the unbuildable engine reports unavailable"
        )
        #expect(sut.store.load(id: sut.id)?.entries.first?.translations.isEmpty == true)
    }

    // MARK: - Identity and arming

    @Test("in archive mode every Apple selection is an alternate")
    func archiveAlternateIdentity() async {
        let sut = await makeSUT()
        let target = TargetLanguage(
            code: sut.model.archiveViewingCode ?? sut.model.translationSettings.targetLanguage.code
        )

        // Default selection is `.session`, and there is no live session to
        // serve it — the retry button must still enable.
        #expect(sut.model.translationSettings.retranslateEngine == .session)
        #expect(archivePlan(sut.model).isAlternate)
        #expect(
            sut.model.retranslateRowPlan(
                for: sut.model.pane.entries[0], surface: .archive, target: target
            ).isEnabled
        )

        // A key-less external reports not-an-alternate (the lane would only
        // toast); the settings-target engine builder agrees there is no key.
        sut.model.translationSettings.selectRetranslate(.google)
        #expect(!archivePlan(sut.model).isAlternate)
        #expect(
            !sut.model.retranslateRowPlan(
                for: sut.model.pane.entries[0], surface: .archive, target: target
            ).isEnabled,
            "the unavailable route hides the retry button"
        )
        #expect(sut.model.translationSession.makeExternalEngine(for: .deepl) == nil)

        // The closed pane turns the route back to live semantics.
        sut.model.closeArchive()
        #expect(
            !sut.model.retranslatePlan(
                surface: .live, target: sut.model.translationSettings.targetLanguage
            ).isAlternate
        )
    }

    @Test("the high-fidelity selection arms its own dedicated session in archive mode")
    func hifiSelectionArmsHifiSession() async throws {
        guard #available(macOS 26.4, *) else {
            try Test.cancel("the high-fidelity lane requires macOS 26.4")
        }
        let sut = await makeSUT()
        sut.model.translationSettings.selectRetranslate(.appleHighFidelity)

        sut.model.retranslate.retranslateSentence(entrySentence(in: sut.model, at: 0))

        #expect(sut.model.retranslate.hifiSessionConfig != nil, "the hifi lane armed, not the fast one")
        #expect(sut.model.retranslate.fastSessionConfig == nil)
        #expect(sut.model.retranslate.appleSessions.armedTarget(for: .appleHighFidelity) == "fr")
    }

    @Test("a second archive with a different stored target rebuilds the armed config")
    func targetMismatchRebuildsConfig() async {
        let sut = await makeSUT()
        // First archive (fr) arms the config; the click needs no hand-over
        // for the arming to happen.
        sut.model.retranslate.retranslateSentence(entrySentence(in: sut.model, at: 0))
        #expect(sut.model.retranslate.appleSessions.armedTarget(for: .appleFast) == "fr")

        // A second archive stored German replaces the pane.
        let secondID = sut.store.append(
            sentence: archiveSentence(0, text: "Guten Tag"), sessionID: nil,
            metadata: SessionMetadata(
                startedAt: Date(timeIntervalSince1970: 2_000_000),
                sourceLang: "ja", targetLang: "de", model: "test-model", chunkMS: 160
            )
        )
        sut.store.finalize(session: secondID ?? -1, durationMS: 10000, saved: false)
        sut.model.closeArchive()
        sut.model.openArchiveSession(id: secondID ?? -1)

        sut.model.retranslate.retranslateSentence(entrySentence(in: sut.model, at: 0))

        #expect(
            sut.model.retranslate.appleSessions.armedTarget(for: .appleFast) == "de",
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

        sut.model.retranslate.retranslateSentence(entrySentence(in: sut.model, at: 0))

        #expect(sut.model.retranslate.fastSessionConfig != nil, "the degraded row retry arms the fast session")
        #expect(sut.model.retranslate.hifiSessionConfig == nil, "the high-fidelity session is never armed")
        #expect(sut.model.retranslate.appleSessions.armedTarget(for: .appleFast) == "fr")
    }

    @Test("a row retry that lands after a viewing-language switch keeps the click-time target")
    func rowRetryKeepsClickTimeTarget() async {
        let sut = await makeSUT()
        let gate = PermitGate()
        let engine = ScriptedArchiveEngine(gate: gate)
        // The archive route arms its own dedicated session; seed it with the
        // gated engine so both chained flights park on the same double.
        sut.model.retranslate.appleSessions.arm(kind: .appleFast, target: "fr")
        sut.model.retranslate.retranslateSessionArrived(.appleFast, engine: engine)

        let first = entrySentence(in: sut.model, at: 0)
        let second = entrySentence(in: sut.model, at: 1)
        sut.model.retranslate.retranslateSentence(first)
        #expect(
            await pollUntil(timeout: resultTimeout) { engine.recordedBatches.count == 1 },
            "the first flight parks in the engine"
        )

        sut.model.retranslate.retranslateSentence(second)
        #expect(sut.model.retranslate.pendingRetranslations == [0, 1], "the second click chains behind the first")

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
            sut.model.pane.entries.compactMap { entry in entry.translation(for: "de") }.isEmpty,
            "no result is stored under the switched language"
        )
        #expect(
            sut.model.pane.entries.compactMap { entry in entry.translation(for: "fr")?.engine }
                == [.appleFast, .appleFast],
            "both row markers describe the click-time language's result"
        )
        #expect(
            sut.model.retranslate.appleSessions.armedTarget(for: .appleFast) == "fr",
            "the armed config kept the click-time target"
        )
    }
}
