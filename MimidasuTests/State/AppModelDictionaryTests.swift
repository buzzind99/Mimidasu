import Foundation
@testable import Mimidasu
import Testing

/// Tests the first-launch dictionary kick-off wiring on `AppModel`: the
/// preparation starts only when no dictionary resolves, the two artifacts
/// (tokenizer dictionary + JMDict database) are covered independently, and a
/// failed preparation stays log-only (no user-visible error state). Both
/// entry points drive the methods with fake closures — no real store touched.
@MainActor
@Suite("AppModel dictionary preparation")
struct AppModelDictionaryTests {

    /// Stubbed launch check: the real locator hashes the dev GGUF and feeds
    /// the engine warm-up — real blocking work tests must never trigger.
    private func makeModel() -> AppModel {
        AppModel(
            translationSettings: isolatedTranslationSettings(suite: "test.AppModelDictionary"),
            asrModelSettings: isolatedASRModelSettings(suite: "test.AppModelDictionary"),
            initialModelResolve: { _ in nil }
        )
    }

    @Test("kicks dictionary preparation when no dictionary resolves")
    func kicksWhenUnresolved() async {
        let model = makeModel()
        var prepareCalls = 0

        model.prepareDictionaryIfNeeded(
            resolve: { nil },
            prepare: {
                prepareCalls += 1
                return URL(fileURLWithPath: "/tmp/ipadic.dic")
            }
        )

        #expect(await pollUntil { prepareCalls == 1 }, "the preparation kicks for the unresolved artifact")
    }

    @Test("skips dictionary preparation when a dictionary already resolves")
    func skipsWhenResolved() {
        let model = makeModel()
        let resolved = URL(fileURLWithPath: "/tmp/ipadic.dic")
        var prepareCalls = 0

        model.prepareDictionaryIfNeeded(
            resolve: { resolved },
            prepare: {
                prepareCalls += 1
                return resolved
            }
        )

        #expect(prepareCalls == 0)
    }

    @Test("a failed preparation is log-only and raises no user-visible error")
    func failedBuildStaysQuiet() async {
        let model = makeModel()
        let failure = DictionaryStore.DictionaryStoreError.libraryUnavailable
        var prepareCalls = 0

        model.prepareDictionaryIfNeeded(
            resolve: { nil },
            prepare: {
                prepareCalls += 1
                throw failure
            }
        )

        #expect(await pollUntil { prepareCalls == 1 }, "the failing preparation runs")
        #expect(!model.isPreparingDictionary)
    }

    @Test("a failed JMDict preparation is log-only and raises no user-visible error")
    func failedJMDBuildStaysQuiet() async {
        let model = makeModel()
        let failure = DictionaryStore.DictionaryStoreError.smokeTestFailed(reason: "smoke")
        var prepareCalls = 0

        model.prepareDictionaryIfNeeded(
            resolve: { URL(fileURLWithPath: "/tmp/ipadic.dic") },
            resolveJMDict: { nil },
            prepareJMDict: {
                prepareCalls += 1
                throw failure
            }
        )

        #expect(await pollUntil { prepareCalls == 1 }, "the failing preparation runs")
        #expect(!model.isPreparingDictionary)
    }

    // MARK: - Two artifacts, covered independently

    @Test("kicks both preparations when neither artifact resolves")
    func kicksBothWhenUnresolved() async {
        let model = makeModel()
        var prepareCalls = 0
        var jmDictPrepareCalls = 0

        model.prepareDictionaryIfNeeded(
            resolve: { nil },
            resolveJMDict: { nil },
            prepare: {
                prepareCalls += 1
                return URL(fileURLWithPath: "/tmp/ipadic.dic")
            },
            prepareJMDict: {
                jmDictPrepareCalls += 1
                return URL(fileURLWithPath: "/tmp/jmdict.sqlite")
            }
        )

        #expect(await pollUntil { prepareCalls == 1 && jmDictPrepareCalls == 1 }, "both preparations kick")
    }

    @Test("a resolved tokenizer dictionary does not excuse a missing JMDict database")
    func resolvedIPADICStillPreparesJMDict() async {
        let model = makeModel()
        var prepareCalls = 0
        var jmDictPrepareCalls = 0

        model.prepareDictionaryIfNeeded(
            resolve: { URL(fileURLWithPath: "/tmp/ipadic.dic") },
            resolveJMDict: { nil },
            prepare: {
                prepareCalls += 1
                return URL(fileURLWithPath: "/tmp/ipadic.dic")
            },
            prepareJMDict: {
                jmDictPrepareCalls += 1
                return URL(fileURLWithPath: "/tmp/jmdict.sqlite")
            }
        )

        #expect(await pollUntil { jmDictPrepareCalls == 1 }, "the missing JMDict preparation kicks")
        #expect(prepareCalls == 0, "the resolved tokenizer dictionary must not prepare")
    }

    @Test("a resolved JMDict database does not excuse a missing tokenizer dictionary")
    func resolvedJMDictStillPreparesIPADIC() async {
        let model = makeModel()
        var prepareCalls = 0
        var jmDictPrepareCalls = 0

        model.prepareDictionaryIfNeeded(
            resolve: { nil },
            resolveJMDict: { URL(fileURLWithPath: "/tmp/jmdict.sqlite") },
            prepare: {
                prepareCalls += 1
                return URL(fileURLWithPath: "/tmp/ipadic.dic")
            },
            prepareJMDict: {
                jmDictPrepareCalls += 1
                return URL(fileURLWithPath: "/tmp/jmdict.sqlite")
            }
        )

        #expect(await pollUntil { prepareCalls == 1 }, "the missing tokenizer preparation kicks")
        #expect(jmDictPrepareCalls == 0, "the resolved JMDict database must not prepare")
    }

    @Test("skips both preparations when both artifacts resolve")
    func skipsBothWhenResolved() {
        let model = makeModel()
        var prepareCalls = 0
        var jmDictPrepareCalls = 0

        model.prepareDictionaryIfNeeded(
            resolve: { URL(fileURLWithPath: "/tmp/ipadic.dic") },
            resolveJMDict: { URL(fileURLWithPath: "/tmp/jmdict.sqlite") },
            prepare: {
                prepareCalls += 1
                return URL(fileURLWithPath: "/tmp/ipadic.dic")
            },
            prepareJMDict: {
                jmDictPrepareCalls += 1
                return URL(fileURLWithPath: "/tmp/jmdict.sqlite")
            }
        )

        #expect(prepareCalls == 0)
        #expect(jmDictPrepareCalls == 0)
    }

    // MARK: - Session-start gate (`ensureDictionaryReady`)

    @Test("session-start gate skips preparation when a dictionary already resolves")
    func gateSkipsWhenResolved() async throws {
        let model = makeModel()
        let resolved = URL(fileURLWithPath: "/tmp/ipadic.dic")
        var prepareCalls = 0
        var jmDictPrepareCalls = 0

        try await model.ensureDictionaryReady(
            resolve: { resolved },
            resolveJMDict: { URL(fileURLWithPath: "/tmp/jmdict.sqlite") },
            prepare: {
                prepareCalls += 1
                return URL(fileURLWithPath: "/tmp/ipadic.dic")
            },
            prepareJMDict: {
                jmDictPrepareCalls += 1
                return URL(fileURLWithPath: "/tmp/jmdict.sqlite")
            }
        )

        #expect(prepareCalls == 0)
        #expect(jmDictPrepareCalls == 0)
        #expect(!model.isPreparingDictionary)
    }

    @Test("session-start gate prepares when no dictionary resolves and clears the flag")
    func gatePreparesWhenUnresolved() async throws {
        let model = makeModel()
        var prepareCalls = 0
        var jmDictPrepareCalls = 0
        var preparingDuringPreparation = false

        try await model.ensureDictionaryReady(
            resolve: { nil },
            resolveJMDict: { nil },
            prepare: { () async throws -> URL in
                prepareCalls += 1
                preparingDuringPreparation = model.isPreparingDictionary
                return URL(fileURLWithPath: "/tmp/ipadic.dic")
            },
            prepareJMDict: { () async throws -> URL in
                jmDictPrepareCalls += 1
                return URL(fileURLWithPath: "/tmp/jmdict.sqlite")
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
                resolve: { nil },
                resolveJMDict: { nil },
                prepare: { throw failure },
                prepareJMDict: { URL(fileURLWithPath: "/tmp/jmdict.sqlite") }
            )
        }

        #expect(!model.isPreparingDictionary)
    }

    @Test("session-start gate prepares only the missing JMDict database when IPADIC resolves")
    func gatePreparesOnlyMissingJMDict() async throws {
        let model = makeModel()
        var prepareCalls = 0
        var jmDictPrepareCalls = 0

        try await model.ensureDictionaryReady(
            resolve: { URL(fileURLWithPath: "/tmp/ipadic.dic") },
            resolveJMDict: { nil },
            prepare: {
                prepareCalls += 1
                return URL(fileURLWithPath: "/tmp/ipadic.dic")
            },
            prepareJMDict: {
                jmDictPrepareCalls += 1
                return URL(fileURLWithPath: "/tmp/jmdict.sqlite")
            }
        )

        #expect(prepareCalls == 0)
        #expect(jmDictPrepareCalls == 1)
        #expect(!model.isPreparingDictionary)
    }

    @Test("session-start gate rethrows a failed JMDict preparation so the start fails visibly")
    func gateRethrowsFailedJMDictPreparation() async throws {
        let model = makeModel()
        let failure = DictionaryStore.DictionaryStoreError.bundledJMDictMissing

        await #expect(throws: (any Error).self) {
            try await model.ensureDictionaryReady(
                resolve: { URL(fileURLWithPath: "/tmp/ipadic.dic") },
                resolveJMDict: { nil },
                prepareJMDict: { throw failure }
            )
        }

        #expect(!model.isPreparingDictionary)
    }
}
