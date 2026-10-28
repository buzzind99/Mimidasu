@testable import Mimidasu
import Testing

/// Tests `TranslationRuntime` as a value: the defaults a fresh snapshot
/// carries, the one latch derivation the sidebar and Settings share
/// (`isAppleFallbackLatched`), and the value semantics that make a whole
/// snapshot comparable.
@Suite("TranslationRuntime")
struct TranslationRuntimeTests {

    @Test("a fresh runtime starts on Apple, idle, and unlatched")
    func freshDefaults() {
        let runtime = TranslationRuntime()

        #expect(runtime.engine == .apple)
        #expect(runtime.externalProvider == nil)
        #expect(!runtime.workerAttached)
        #expect(runtime.status == .idle)
        #expect(!runtime.fallbackLatched)
        #expect(!runtime.isAppleFallbackLatched)
    }

    /// The latch alone must not surface as "using Apple after fallback":
    /// while the live engine is external the latch is inert. Only the pair
    /// (latched + Apple) drives the sidebar pill and the Settings row.
    @Test(
        "the Apple-fallback latch requires both the latch and the Apple engine",
        arguments: [
            (false, ActiveTranslationEngine.apple, false),
            (true, ActiveTranslationEngine.apple, true),
            (false, ActiveTranslationEngine.external, false),
            (true, ActiveTranslationEngine.external, false),
        ]
    )
    func appleFallbackLatchTruthTable(
        fallbackLatched: Bool, engine: ActiveTranslationEngine, expected: Bool
    ) {
        let runtime = makeRuntime(fallbackLatched: fallbackLatched, engine: engine)

        #expect(runtime.isAppleFallbackLatched == expected)
    }

    @Test("equal copies compare equal")
    func equalCopiesCompareEqual() {
        var first = TranslationRuntime()
        first.engine = .external
        first.externalProvider = .google
        first.workerAttached = true
        first.status = .translating
        first.fallbackLatched = true

        let second = first

        #expect(first == second)
    }

    @Test("mutating one field breaks equality")
    func fieldMutationBreaksEquality() {
        var first = TranslationRuntime()
        first.engine = .external
        first.externalProvider = .google
        first.workerAttached = true
        first.status = .translating
        first.fallbackLatched = true

        var second = first
        second.workerAttached = false

        #expect(first != second)
    }

    // MARK: - Helpers

    /// A runtime in the given latch/engine shape; external engines get a
    /// concrete provider stamped so the fixture matches a real attach.
    private func makeRuntime(
        fallbackLatched: Bool, engine: ActiveTranslationEngine
    ) -> TranslationRuntime {
        var runtime = TranslationRuntime()
        runtime.engine = engine
        runtime.fallbackLatched = fallbackLatched
        if engine == .external {
            runtime.externalProvider = .google
        }
        return runtime
    }
}
