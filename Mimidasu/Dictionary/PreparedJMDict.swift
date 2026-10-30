import Foundation

/// One resolved JMDict artifact and the capabilities its connection offers.
///
/// Resolution is fixed here: the debug-only `MIMIDASU_JMDICT` override, the
/// prepared destination, then the debug checkout artifact. Opening is the
/// single readiness path: a missing file is `.databaseMissing`, an unopenable
/// path or a file that is not SQLite is `.sqliteError`, and a valid database
/// without the current gloss index still opens with `hasGlossIndex == false`.
struct PreparedJMDict: Sendable {
    let url: URL

    struct Opened: Sendable {
        let database: SQLiteDatabase
        let hasGlossIndex: Bool
    }

    /// Resolves through the process environment and the real locations.
    static func resolve() -> PreparedJMDict? {
        resolve(
            environment: ProcessInfo.processInfo.environment,
            destination: DictionaryStore.defaultDestinationDirectory,
            fileExists: { url in FileManager.default.fileExists(atPath: url.path) }
        )
    }

    /// Injectable core of `resolve()`.
    static func resolve(
        environment: [String: String],
        destination: URL = DictionaryStore.defaultDestinationDirectory,
        fileExists: (URL) -> Bool
    ) -> PreparedJMDict? {
        var candidates: [URL] = []
        #if DEBUG
            if let override = environment["MIMIDASU_JMDICT"], !override.isEmpty {
                candidates.append(URL(fileURLWithPath: override))
            }
        #endif
        candidates.append(destination.appendingPathComponent(JMDictPin.preparedFileName))
        #if DEBUG
            candidates.append(DictionaryStore.debugRepoURL(JMDictPin.debugCheckoutPath))
        #endif
        guard let url = candidates.first(where: fileExists) else { return nil }
        return PreparedJMDict(url: url)
    }

    /// Whether a file already at `url` can be adopted as-is.
    ///
    /// The gloss index at the current stamp is required unless the platform
    /// cannot build one. The case-headword index is deliberately not required:
    /// its absence changes only the cost of loading the case spellings, and the
    /// versioned filename already retires databases from older pins.
    static func isAdoptable(at url: URL) -> Bool {
        JMDictFTSIndex.isPresent(at: url) || !JMDictFTSIndex.isAvailable
    }

    /// Opens a read-only connection and reads its capabilities.
    ///
    /// A missing file is `.databaseMissing`. A file that exists but cannot be
    /// opened, or is not SQLite, is `.sqliteError` (code -1 when SQLite could
    /// not create a handle at all, SQLite's own code otherwise). A valid
    /// database without the current gloss index still opens, with
    /// `hasGlossIndex == false`; so does one on a host whose SQLite cannot
    /// read FTS5, where the stage would abort on the missing module.
    func open() throws(DictionaryError) -> Opened {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw .databaseMissing
        }
        let database: SQLiteDatabase
        do {
            database = try SQLiteDatabase(path: url.path)
        } catch {
            throw Self.dictionaryError(for: error)
        }
        do {
            let present = try JMDictFTSIndex.isPresent(in: database)
            return Opened(
                database: database,
                hasGlossIndex: present && JMDictFTSIndex.isAvailable
            )
        } catch {
            database.close()
            throw Self.dictionaryError(for: error)
        }
    }

    private static func dictionaryError(for error: SQLiteDatabase.Error) -> DictionaryError {
        switch error {
        case .unavailable:
            .sqliteError(code: -1, message: "failed to open JMDict database")
        case let .sqlite(code, message):
            .sqliteError(code: code, message: message)
        }
    }
}
