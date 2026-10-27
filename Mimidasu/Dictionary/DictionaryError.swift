import Foundation

/// Why a dictionary lookup could not produce an answer. Exhaustive by
/// construction: every lookup throw lands in one of these cases, so each
/// host's error-to-toast routing is compiler-checked. The warning pill
/// stays reserved for genuine no-hits, never for these failures.
enum DictionaryError: Error, Equatable, Sendable, LocalizedError {
    /// The annotator ran without its tokenizer dictionary, so the lookup
    /// resolved to no segments to expand.
    case annotatorUnavailable
    /// The prepared JMDict database is not on disk yet.
    case databaseMissing
    /// The lookup engine was closed before the query ran.
    case databaseClosed
    /// The prepared database references entries that do not exist.
    case databaseCorrupt
    /// SQLite reported a failure.
    case sqliteError(code: Int32, message: String)
    /// A non-database failure (including cancellation) that must still
    /// surface typed — never mislabeled as a SQLite error.
    case internalError(message: String)

    /// The single copy authority: every user-facing failure string is
    /// spelled exactly once here, so all hosts surface identical text.
    var errorDescription: String? {
        switch self {
        case .annotatorUnavailable:
            "Text annotation is unavailable; the tokenizer dictionary may still be preparing."
        case .databaseMissing:
            "JMDict database not found; the dictionary may still be preparing."
        case .databaseClosed:
            "JMDict database has been closed."
        case .databaseCorrupt:
            "JMDict database is corrupt."
        case let .sqliteError(code, message):
            "JMDict database error \(code): \(message)."
        case let .internalError(message):
            "Unexpected dictionary error: \(message)."
        }
    }

    /// The one SQLite translation: a store failure onto the typed error
    /// surface. The open path never routes an unopenable handle through
    /// here: a file that exists but fails to open reports
    /// `.sqliteError(code: -1, ...)` there, never `.databaseMissing` —
    /// missing stays reserved for a nil URL or an absent file. This
    /// mapping stays as-is for the reading and headword-probe paths,
    /// where `.unavailable` still reads as missing.
    init(_ error: SQLiteDatabase.Error) {
        switch error {
        case .unavailable:
            self = .databaseMissing
        case let .sqlite(code, message):
            self = .sqliteError(code: code, message: message)
        }
    }

    /// Maps any lookup-thrown error onto the typed error surface,
    /// preserving the existing toast messages: each database failure
    /// keeps the engine's text. An error that is already typed passes
    /// through untouched; a store failure routes through the one SQLite
    /// mapper above; anything unrecognized maps to an internal error
    /// carrying the underlying message, so no throw can escape untyped
    /// and no generic failure is ever mislabeled as a SQLite error.
    ///
    /// Cancellation maps to `.internalError` here to keep this pure layer
    /// total, but callers must intercept `CancellationError` before
    /// constructing the error: the tap resolver and dictionary search
    /// silent-drop cancellations — never toast, never SQLite.
    init(_ error: Error) {
        if let dictionaryError = error as? DictionaryError {
            self = dictionaryError
            return
        }
        if let sqliteError = error as? SQLiteDatabase.Error {
            self = Self(sqliteError)
            return
        }
        if error is CancellationError {
            // Pure-map truth only: resolve and search silent-drop
            // cancellations upstream and never construct this error for
            // them.
            self = .internalError(message: error.localizedDescription)
            return
        }
        self = .internalError(message: error.localizedDescription)
    }
}
