import Foundation
@testable import Mimidasu
import Testing

/// Tests the dictionary preparation wiring on `AppModel`.
///
/// The property under test is that **both artifacts are always handed to the
/// store**, never a resolve probe deciding at this layer whether a build is
/// needed. That gate existed and it was the bug: `resolveJMDict()` answers "does
/// the file exist", not "is the file usable", so a database promoted before the
/// gloss index existed short-circuited every prepare and was adopted forever —
/// silently answering every Latin query with zero rows. Whether a re-stage is
/// needed belongs to `DictionaryStore.run`, which is the only thing that can see
/// the index.
///
/// Both entry points drive the methods with fake closures — no real store
/// touched.
@MainActor
@Suite("AppModel dictionary preparation")
struct AppModelDictionaryTests {

    /// Stubbed launch check: the real locator hashes the dev GGUF and feeds
    /// the engine warm-up — real blocking work tests must never trigger.
    private func makeModel() -> AppModel {
        makeIdleModel(suite: "test.AppModelDictionary")
    }

    private static let ipadic = URL(fileURLWithPath: "/tmp/ipadic.dic")
    private static let jmDict = URL(fileURLWithPath: "/tmp/jmdict.sqlite")

    // MARK: - Launch kick

    @Test("asks the store even when nothing is missing, so adoption is decided in one place")
    func alwaysAsksTheStore() async {
        // The regression this pins: a resolve gate here meant a database that
        // merely *existed* was never offered to `DictionaryStore.run`, so its
        // index-aware adoption check — the whole self-heal for an install that
        // promoted before the gloss index existed — was unreachable, and every
        // Latin gloss query returned zero rows with no error to show for it.
        let model = makeModel()
        var prepareCalls = 0
        var jmDictPrepareCalls = 0

        model.prepareDictionaries(
            prepare: {
                prepareCalls += 1
                return Self.ipadic
            },
            prepareJMDict: {
                jmDictPrepareCalls += 1
                return Self.jmDict
            }
        )

        #expect(await pollUntil { jmDictPrepareCalls == 1 }, "the JMDict store must always be asked")
        #expect(prepareCalls == 1)
    }

    @Test("a failed preparation is log-only and raises no user-visible error")
    func failedPreparationsStayQuiet() async {
        let model = makeModel()
        var prepareCalls = 0
        var jmDictPrepareCalls = 0

        model.prepareDictionaries(
            prepare: {
                prepareCalls += 1
                throw DictionaryStore.DictionaryStoreError.libraryUnavailable
            },
            prepareJMDict: { Self.jmDict }
        )

        #expect(await pollUntil { prepareCalls == 1 }, "the failing tokenizer preparation runs")
        #expect(!model.isPreparingDictionary)

        model.prepareDictionaries(
            prepare: { Self.ipadic },
            prepareJMDict: {
                jmDictPrepareCalls += 1
                throw DictionaryStore.DictionaryStoreError.smokeTestFailed(reason: "smoke")
            }
        )

        #expect(await pollUntil { jmDictPrepareCalls == 1 }, "the failing JMDict preparation runs")
        #expect(!model.isPreparingDictionary)
    }

    // MARK: - Session-start gate (`ensureDictionaryReady`)

    @Test("session-start gate confirms both artifacts and clears the flag")
    func gateConfirmsBothArtifacts() async throws {
        let model = makeModel()
        var prepareCalls = 0
        var jmDictPrepareCalls = 0
        var preparingDuringPreparation = false

        try await model.ensureDictionaryReady(
            prepare: {
                prepareCalls += 1
                preparingDuringPreparation = model.isPreparingDictionary
                return Self.ipadic
            },
            prepareJMDict: {
                jmDictPrepareCalls += 1
                return Self.jmDict
            }
        )

        #expect(prepareCalls == 1)
        #expect(jmDictPrepareCalls == 1)
        #expect(preparingDuringPreparation)
        #expect(!model.isPreparingDictionary)
    }

    @Test("session-start gate rethrows a failed preparation so the start fails visibly")
    func gateRethrowsFailedPreparation() async throws {
        let model = makeModel()
        let failure = DictionaryStore.DictionaryStoreError.prepareFailed(returnCode: 1)

        await #expect(throws: (any Error).self) {
            try await model.ensureDictionaryReady(
                prepare: { throw failure },
                prepareJMDict: { Self.jmDict }
            )
        }

        #expect(!model.isPreparingDictionary)
    }

    @Test("session-start gate rethrows a failed JMDict preparation so the start fails visibly")
    func gateRethrowsFailedJMDictPreparation() async throws {
        let model = makeModel()
        let failure = DictionaryStore.DictionaryStoreError.bundledJMDictMissing

        await #expect(throws: (any Error).self) {
            try await model.ensureDictionaryReady(
                prepare: { Self.ipadic },
                prepareJMDict: { throw failure }
            )
        }

        #expect(!model.isPreparingDictionary)
    }
}
