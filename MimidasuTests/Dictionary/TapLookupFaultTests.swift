import Foundation
@testable import Mimidasu
import Testing

/// Pins the tap fault map: every lookup throw lands on one typed fault, and
/// each fault carries the toast string the host surfaces. Pure unit tests —
/// no database, no annotator — complementing the resolve-level fault tests
/// in `LookupDisplayTests`, which prove the engine throws reach the same
/// faults end to end.
@Suite("TapLookupFault mapping")
struct TapLookupFaultTests {

    @Test("an already-typed fault passes through untouched")
    func passthrough() {
        let fault = TapLookupFault.sqliteError(code: 11, message: "boom")

        let mapped = TapLookupFault(fault)

        #expect(mapped == fault)
    }

    @Test("a corrupt fault passes through untouched")
    func corruptPassthrough() {
        let mapped = TapLookupFault(TapLookupFault.databaseCorrupt)

        #expect(mapped == .databaseCorrupt)
    }

    @Test("each engine error maps onto its fault", arguments: [
        (JMDictLookupError.databaseMissing, TapLookupFault.databaseMissing),
        (JMDictLookupError.databaseClosed, TapLookupFault.databaseClosed),
        (JMDictLookupError.databaseCorrupt, TapLookupFault.databaseCorrupt),
        (
            JMDictLookupError.sqliteError(code: 11, message: "boom"),
            TapLookupFault.sqliteError(code: 11, message: "boom")
        ),
    ])
    func engineErrorMapping(error: JMDictLookupError, expected: TapLookupFault) {
        let mapped = TapLookupFault(error)

        #expect(mapped == expected)
    }

    @Test("an unavailable store error maps onto database-missing")
    func storeUnavailableMapping() {
        let mapped = TapLookupFault(SQLiteDatabase.Error.unavailable)

        #expect(mapped == .databaseMissing)
    }

    @Test("a store sqlite error maps onto its fault")
    func storeSqliteMapping() {
        let mapped = TapLookupFault(SQLiteDatabase.Error.sqlite(code: 11, message: "boom"))

        #expect(mapped == .sqliteError(code: 11, message: "boom"))
    }

    @Test("an unrecognized error faults as an internal error carrying its message")
    func genericMapping() {
        let underlying = NSError(domain: "mimidasu.test", code: 42, userInfo: [
            NSLocalizedDescriptionKey: "underlying trouble"
        ])

        let mapped = TapLookupFault(underlying)

        #expect(mapped == .internalError(message: "underlying trouble"))
    }

    @Test("a cancellation faults as an internal error at the pure map; resolve silent-drops it upstream")
    func cancellationMapping() {
        let mapped = TapLookupFault(CancellationError())

        #expect(mapped == .internalError(message: CancellationError().localizedDescription))
    }

    @Test("every fault describes its toast string", arguments: [
        (
            TapLookupFault.annotatorUnavailable,
            "Text annotation is unavailable; the tokenizer dictionary may still be preparing."
        ),
        (
            TapLookupFault.databaseMissing,
            "JMDict database not found; the dictionary may still be preparing."
        ),
        (
            TapLookupFault.databaseClosed,
            "JMDict database has been closed."
        ),
        (
            TapLookupFault.sqliteError(code: 11, message: "boom"),
            "JMDict database error 11: boom."
        ),
        (
            TapLookupFault.databaseCorrupt,
            "JMDict database is corrupt."
        ),
        (
            TapLookupFault.internalError(message: "boom"),
            "Unexpected dictionary error: boom."
        ),
    ])
    func descriptions(fault: TapLookupFault, expected: String) {
        #expect(fault.localizedDescription == expected)
    }
}
