@testable import Mimidasu
import Testing

/// Value-shape characterization of `LookupAnswer`: equality round-trips per
/// case, and the accessor semantics carried over from the pinned content —
/// found/not-found expose their display and fallbacks, no-hit and failure
/// expose none. Pure unit tests — no engine, no database.
@Suite("LookupAnswer")
struct LookupAnswerTests {

    // MARK: - Fixtures

    private func result(_ matched: String) -> LookupResult {
        LookupResult(matched: matched, entries: [])
    }

    // MARK: - Equality

    @Test("each case round-trips through equality")
    func equatableRoundTrips() {
        #expect(
            LookupAnswer.found(
                result: result("お"), also: [result("お土産")], origin: .join
            ) == .found(result: result("お"), also: [result("お土産")], origin: .join)
        )
        #expect(
            LookupAnswer.notFound(surface: "雨尾", related: [result("雨")])
                == .notFound(surface: "雨尾", related: [result("雨")])
        )
        #expect(LookupAnswer.noHit(surface: "雨尾") == .noHit(surface: "雨尾"))
        #expect(LookupAnswer.failure(.databaseClosed) == .failure(.databaseClosed))
    }

    @Test("answers with different payloads or cases never compare equal")
    func distinguishesPayloads() {
        #expect(LookupAnswer.noHit(surface: "雨") != .noHit(surface: "尾"))
        #expect(LookupAnswer.failure(.databaseClosed) != .failure(.databaseMissing))
        #expect(
            LookupAnswer.found(result: result("お"), also: [], origin: .join)
                != .found(result: result("お"), also: [result("お土産")], origin: .join)
        )
        #expect(LookupAnswer.noHit(surface: "雨") != .failure(.databaseMissing))
    }

    // MARK: - Accessors

    @Test("a found answer exposes its display, its also-fallbacks, and both combined")
    func foundAccessors() {
        let display = result("お")
        let firstFallback = result("お土産")
        let secondFallback = result("土産")
        let answer = LookupAnswer.found(
            result: display, also: [firstFallback, secondFallback], origin: .tappedSurface
        )

        #expect(answer.displayResult == display)
        #expect(answer.fallbackResults == [firstFallback, secondFallback])
        #expect(answer.allResults == [display, firstFallback, secondFallback])
    }

    @Test("a not-found answer exposes no display and demotes its related hits")
    func notFoundAccessors() {
        let related = result("雨")
        let answer = LookupAnswer.notFound(surface: "雨尾", related: [related])

        #expect(answer.displayResult == nil)
        #expect(answer.fallbackResults == [related])
        #expect(answer.allResults == [related])
    }

    @Test("a bare miss exposes no results at all")
    func noHitAccessors() {
        let answer = LookupAnswer.noHit(surface: "雨尾")

        #expect(answer.displayResult == nil)
        #expect(answer.fallbackResults.isEmpty)
        #expect(answer.allResults.isEmpty)
    }

    @Test("a failure exposes no results at all")
    func failureAccessors() {
        let answer = LookupAnswer.failure(.sqliteError(code: 11, message: "boom"))

        #expect(answer.displayResult == nil)
        #expect(answer.fallbackResults.isEmpty)
        #expect(answer.allResults.isEmpty)
    }
}
