import Foundation

/// Why a tap could not become pinnable content. Exhaustive by construction:
/// every `resolve` throw lands in one of these cases, so each host's
/// fault-to-toast routing is compiler-checked. The warning pill stays
/// reserved for genuine no-hits (`TapLookupEffect.warnNoHit`), never for
/// these faults.
enum TapLookupFault: Equatable, Sendable, LocalizedError {
    /// The annotator ran without its tokenizer dictionary, so the tap
    /// resolved to no segments to expand.
    case annotatorUnavailable
    /// The prepared JMDict database is not on disk yet.
    case databaseMissing
    /// The lookup engine was closed before the tap ran.
    case databaseClosed
    /// The prepared database references entries that do not exist.
    case databaseCorrupt
    /// SQLite reported a failure.
    case sqliteError(code: Int32, message: String)
    /// A non-database failure (including cancellation) that must still
    /// surface typed — never mislabeled as a SQLite error.
    case internalError(message: String)

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

    /// Maps any lookup-thrown error onto the typed fault surface, preserving
    /// the existing toast messages: each database failure keeps the engine's
    /// text. A fault that is already typed passes through untouched; anything
    /// unrecognized faults as an internal error carrying the underlying
    /// message, so no throw can escape untyped and no generic failure is ever
    /// mislabeled as a SQLite error.
    ///
    /// Cancellation maps to `.internalError` here to keep this pure layer
    /// total, but callers must intercept `CancellationError` before
    /// constructing the fault: `LookupDisplay.resolve` (and dictionary search)
    /// silent-drop cancellations — never toast, never SQLite.
    init(_ error: Error) {
        if let fault = error as? TapLookupFault {
            self = fault
            return
        }
        if let lookupError = error as? JMDictLookupError {
            switch lookupError {
            case .databaseMissing:
                self = .databaseMissing
            case .databaseClosed:
                self = .databaseClosed
            case .databaseCorrupt:
                self = .databaseCorrupt
            case let .sqliteError(code, message):
                self = .sqliteError(code: code, message: message)
            }
            return
        }
        if let sqliteError = error as? SQLiteDatabase.Error {
            switch sqliteError {
            case .unavailable:
                self = .databaseMissing
            case let .sqlite(code, message):
                self = .sqliteError(code: code, message: message)
            }
            return
        }
        if error is CancellationError {
            // Pure-map truth only: resolve and search silent-drop
            // cancellations upstream and never construct this fault for them.
            self = .internalError(message: error.localizedDescription)
            return
        }
        self = .internalError(message: error.localizedDescription)
    }
}
