import Foundation
@testable import Mimidasu
import Testing

/// Pins the single dictionary-error surface: each case's user-facing copy
/// through both description entry points, the one SQLite mapper, and the
/// total map every thrown error passes through. Pure unit tests — no
/// database, no annotator.
@Suite("DictionaryError")
struct DictionaryErrorTests {

    struct Row: Sendable {
        let summary: String
        let error: DictionaryError
        let expected: String
    }

    @Test("each case surfaces its copy through errorDescription and localizedDescription", arguments: [
        Row(
            summary: "annotatorUnavailable explains the missing tokenizer",
            error: .annotatorUnavailable,
            expected: "Text annotation is unavailable; the tokenizer dictionary may still be preparing."
        ),
        Row(
            summary: "databaseMissing points at the still-preparing database",
            error: .databaseMissing,
            expected: "JMDict database not found; the dictionary may still be preparing."
        ),
        Row(
            summary: "databaseClosed names the closed handle",
            error: .databaseClosed,
            expected: "JMDict database has been closed."
        ),
        Row(
            summary: "databaseCorrupt names the corrupt database",
            error: .databaseCorrupt,
            expected: "JMDict database is corrupt."
        ),
        Row(
            summary: "sqliteError carries the code and message",
            error: .sqliteError(code: 11, message: "boom"),
            expected: "JMDict database error 11: boom."
        ),
        Row(
            summary: "internalError carries the underlying message",
            error: .internalError(message: "boom"),
            expected: "Unexpected dictionary error: boom."
        )
    ])
    func descriptions(row: Row) {
        #expect(row.error.errorDescription == row.expected, "\(row.summary)")
        #expect(row.error.localizedDescription == row.expected, "\(row.summary)")
    }

    @Test("the SQLite mapper translates store failures", arguments: [
        (SQLiteDatabase.Error.unavailable, DictionaryError.databaseMissing),
        (
            SQLiteDatabase.Error.sqlite(code: 11, message: "boom"),
            DictionaryError.sqliteError(code: 11, message: "boom")
        ),
    ])
    func sqliteMapping(storeError: SQLiteDatabase.Error, expected: DictionaryError) {
        #expect(DictionaryError(storeError) == expected)
    }

    @Test("an already-typed error passes through untouched")
    func typedPassthrough() {
        let error = DictionaryError.sqliteError(code: 11, message: "boom")

        let mapped = DictionaryError(error as any Error)

        #expect(mapped == error)
    }

    @Test("each engine error maps onto itself through the total map", arguments: [
        (DictionaryError.databaseMissing, DictionaryError.databaseMissing),
        (DictionaryError.databaseClosed, DictionaryError.databaseClosed),
        (DictionaryError.databaseCorrupt, DictionaryError.databaseCorrupt),
        (
            DictionaryError.sqliteError(code: 11, message: "boom"),
            DictionaryError.sqliteError(code: 11, message: "boom")
        ),
    ])
    func engineErrorMapping(error: DictionaryError, expected: DictionaryError) {
        let mapped = DictionaryError(error)

        #expect(mapped == expected)
    }

    @Test("a store error reaches its typed case through the total map")
    func storeErrorMapping() {
        let storeError: any Error = SQLiteDatabase.Error.unavailable

        #expect(DictionaryError(storeError) == .databaseMissing)
    }

    @Test("a cancellation maps to an internal error carrying its message")
    func cancellationMapping() {
        let mapped = DictionaryError(CancellationError())

        #expect(mapped == .internalError(message: CancellationError().localizedDescription))
    }

    @Test("an unrecognized error maps to an internal error carrying its message")
    func genericMapping() {
        let underlying = NSError(domain: "mimidasu.test", code: 42, userInfo: [
            NSLocalizedDescriptionKey: "underlying trouble"
        ])

        let mapped = DictionaryError(underlying)

        #expect(mapped == .internalError(message: "underlying trouble"))
    }
}
